#!/usr/bin/env python3
# qmi-services.py — list the QMI services a device's processors publish, by name, and the QMI service
# descriptors (service id, IDL version, message ids) a vendor library carries.
#
#   qmi-services.py live|table|lib <args>
#
#   live [adb-path]            rooted phone: dump the IPC-router service table, name the services
#   table <dump_servers.txt>   same, from a saved /sys/kernel/debug/msm_ipc_router/dump_servers
#   lib <file.so> [...]        service objects embedded in a Qualcomm/OEM QMI client lib
#
# WHY
#
# "Does the modem run IMS / is this OEM hook served" is answered by the service table, not by docs:
# a modem-side IMS stack publishes IMSS 0x12, IMSA 0x21, IMSP 0x1f, IMS_RTP 0x28; an AP-side one (LG V20)
# publishes none, and an OEM's private hook shows up as an unnamed vendor id (0x2bd.. on the V20).
# The `lib` mode ties those unnamed ids back to a library: every qmi_idl service object starts
# `<library_version 5|6> 01 00 00 00 <service id> <max msg len>` in .data.rel.ro, followed by the
# req/resp/ind message-id tables, so the id and the message ids of an undocumented OEM service fall out
# of its client .so with no disassembly. Node 0 is the modem on the MSM IPC router; nodes 5/9 are
# the ADSP/other DSPs; node 1 is the AP itself. QRTR devices: `qrtr-lookup` gives the same table.
import re, struct, subprocess, sys

NAMES = {0x0:'CTL',0x1:'WDS',0x2:'DMS',0x3:'NAS',0x4:'QOS',0x5:'WMS',0x6:'PDS',0x7:'AUTH',0x8:'AT',0x9:'VOICE',
 0xa:'CAT2',0xb:'UIM',0xc:'PBM',0xd:'QCHAT',0xe:'RMTFS',0xf:'TEST',0x10:'LOC',0x11:'SAR',0x12:'IMSS(ims settings)',
 0x13:'ADC',0x14:'CSD',0x15:'MFS',0x16:'TIME',0x17:'TS',0x18:'TMD',0x19:'SAP',0x1a:'WDA',0x1b:'TSYNC',0x1c:'RFSA',
 0x1d:'CSVT',0x1e:'QCMAP',0x1f:'IMSP(ims presence)',0x20:'IMSVT',0x21:'IMSA(ims application)',0x22:'COEX',
 0x24:'PDC',0x26:'STX',0x27:'BIT',0x28:'IMS_RTP',0x29:'RFRPE',0x2a:'DSD',0x2b:'SSCTL',0x2c:'MFSE',0x2f:'DPM',
 0x30:'UIMRMT',0x31:'ATH',0x32:'VS',0x33:'LTE',0x37:'SLIMBUS',0x38:'DFS',0x3c:'HMON',0x40:'SERVREG_LOC',
 0x42:'SERVREG_NOTIF',0x45:'WLFW',0x302:'SFS/IMSDCM?'}
IMS_IDS = (0x12, 0x1f, 0x20, 0x21, 0x28)

def parse_table(text):
    rows = []
    for l in text.splitlines():
        m = re.match(r'\s*0x([0-9a-f]+)\s*\|0x([0-9a-f]+)\s*\|0x([0-9a-f]+)\s*\|0x([0-9a-f]+)', l)
        if m: rows.append(tuple(int(x, 16) for x in m.groups()))
    return rows

def print_table(rows):
    bynode = {}
    for svc, inst, node, _port in rows: bynode.setdefault(node, set()).add((svc, inst))
    for node in sorted(bynode):
        tag = {0: 'modem', 1: 'apps'}.get(node, 'dsp')
        print(f'node {node} ({tag}): {len(bynode[node])} services')
        for svc, inst in sorted(bynode[node]):
            print(f'   0x{svc:04x} inst 0x{inst:04x}  {NAMES.get(svc, "vendor/unknown")}')
    modem = {s for s, _ in bynode.get(0, ())}
    have = [f'0x{i:02x}' for i in IMS_IDS if i in modem]
    print('modem IMS services:', ' '.join(have) if have else 'none (AP-side IMS or no IMS)')

def lib_objects(path):
    b = open(path, 'rb').read()
    for m in re.finditer(rb'[\x05\x06]\x00\x00\x00(\x01|\x02)\x00\x00\x00(....)(....)', b):
        sid, mml = struct.unpack('<I', m.group(2))[0], struct.unpack('<I', m.group(3))[0]
        if sid >= 0x2000 or not 0 < mml < 0x20000: continue
        o = m.start()
        libver = b[o]
        nreq, nresp, nind = struct.unpack('<HHH', b[o+16:o+22])
        if not 0 < nreq + nresp + nind <= 1536 or nreq != nresp: continue   # ELF noise that happens to match
        msgs = {'n': (nreq, nresp, nind)}
        # message tables: 6-byte entries {u16 msg id, u16 table index, u16 max len} -- verified for
        # library_version 5 with IDL v2 (OEM libs); other combinations pack them differently, so ids are
        # printed only when the decoded table is sorted, as a real one is.
        if libver == 5:
            try:
                for name, n, p in zip(('req', 'resp', 'ind'), (nreq, nresp, nind), struct.unpack('<III', b[o+24:o+36])):
                    if 0 < p and p + 6*n <= len(b):
                        ids = [struct.unpack('<H', b[p+6*i:p+6*i+2])[0] for i in range(n)]
                        if ids == sorted(set(ids)): msgs[name] = ids   # tables are sorted for bsearch; else wrong layout
            except struct.error:
                pass
        yield sid, m.group(1)[0], mml, msgs

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('live', 'table', 'lib'):
        sys.exit('usage: qmi-services.py live [adb] | table <dump_servers.txt> | lib <file.so> [...]')
    mode = sys.argv[1]
    if mode == 'live':
        adb = sys.argv[2] if len(sys.argv) > 2 else 'adb'
        out = subprocess.run([adb, 'shell', 'su -c cat /sys/kernel/debug/msm_ipc_router/dump_servers 2>/dev/null || cat /sys/kernel/debug/msm_ipc_router/dump_servers'],
                             capture_output=True, text=True).stdout
        if 'Service' not in out: sys.exit('no IPC-router service table: need root and /sys/kernel/debug mounted (QRTR device? use qrtr-lookup)')
        print_table(parse_table(out))
    elif mode == 'table':
        print_table(parse_table(open(sys.argv[2]).read()))
    else:
        for path in sys.argv[2:]:
            objs = sorted(set((s, v, m, msgs['n'], tuple(msgs.get('req', []))) for s, v, m, msgs in lib_objects(path)))
            print(f'{path}:')
            for sid, idl, mml, n, req in objs:
                ids = '  req msg ids: ' + ' '.join(f'0x{x:04x}' for x in req[:24]) if req else ''
                print(f'   0x{sid:04x} idl v{idl} maxmsg 0x{mml:<5x} req/resp/ind {n[0]}/{n[1]}/{n[2]:<4} {NAMES.get(sid, "vendor/unknown")}{ids}')

if __name__ == '__main__': main()
