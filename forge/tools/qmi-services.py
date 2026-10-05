#!/usr/bin/env python3
# qmi-services.py — list the QMI services a device's processors publish, by name, and the QMI service
# descriptors (service id, IDL version, message ids) a vendor library carries.
#
#   qmi-services.py live|table|lib|idl <args>
#
#   live [adb-path]            rooted phone: dump the IPC-router service table, name the services
#   table <dump_servers.txt>   same, from a saved /sys/kernel/debug/msm_ipc_router/dump_servers
#   lib <file.so> [...]        service objects embedded in a Qualcomm/OEM QMI client lib
#   idl <file.so> [svc-hex]    decode the qmi_idl bytecode of those objects: every message's TLVs,
#                              C-struct offsets, array sizes and nested types (the wire format)
#
# WHY
#
# "Does the modem run IMS / is this OEM hook served" is answered by the service table, not by docs:
# a modem-side IMS stack publishes IMSS 0x12, IMSA 0x21, IMSP 0x1f, IMS_RTP 0x28; an AP-side one (LG V20)
# publishes none, and an OEM's private hook shows up as an unnamed vendor id (0x2bd.. on the V20).
# The `lib` mode ties those unnamed ids back to a library: every qmi_idl service object starts
# `<library_version 5|6> 01 00 00 00 <service id> <max msg len>` in .data.rel.ro, followed by the
# req/resp/ind message-id tables, so the id and the message ids of an undocumented OEM service fall out
# of its client .so with no disassembly, and `idl` walks the message/type tables (the bytecode the
# qmi_idl_lib encoder reads: flags byte, offset, array size, size offset, aggregate type ref) so an
# undocumented OEM message's TLV layout is read off the client lib (validated against WDS/NAS/IMSS
# generated headers; handles lib versions 1-6 and APS2-packed Android relocations). Node 0 is the
# modem on the MSM IPC router; nodes 5/9 are the ADSP/other DSPs; node 1 is the AP itself. QRTR
# devices: `qrtr-lookup` gives the same table.
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
        msgs = {'n': (nreq, nresp, nind), 'off': o}
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

TYPES = ['u8', 'u16', 'u32', 'u64', 'enum8', 'enum16', 'string', 'struct']

class Idl:
    """qmi_idl type/message tables of one service object (library_version 1-6, qmi_idl_lib_internal.h)."""
    def __init__(self, path, svc_off):
        self.b = b = open(path, 'rb').read()
        seg = subprocess.check_output(['readelf', '-lW', path]).decode()
        self.loads = [(int(p[1], 16), int(p[2], 16), int(p[5], 16)) for p in (l.split() for l in seg.splitlines()) if p and p[0] == 'LOAD']
        self.elf32 = b[4] == 1
        self.ps = 4 if self.elf32 else 8        # pointer size; the tables are C structs of the target ABI
        self.tables = {}
        # symbol-relocated slots (zero in the file): file offset -> symbol, e.g. common_qmi_idl_type_table_object_v01.
        # Android blobs use packed SHT_ANDROID_REL relocations, which readelf cannot list, so decode them here.
        self.rel = {}
        syms = {}
        for l in subprocess.check_output(['readelf', '-W', '--dyn-syms', path]).decode().splitlines():
            f = l.split()
            if len(f) >= 8 and f[0][:-1].isdigit(): syms[int(f[0][:-1])] = (f[7].split('@')[0], int(f[1], 16))
        for off, info in self.relocs(path):
            sym = info >> 8 if self.elf32 else info >> 32
            if sym:
                try: self.rel[self.v2o(off)] = syms.get(sym, ('?', 0))
                except ValueError: pass
        o = svc_off
        self.libver, self.idlver, self.sid, self.mml = struct.unpack('<IIII', b[o:o+16])
        self.n = struct.unpack('<HHH', b[o+16:o+22]); self.ptrs = [self.ptr(o+24+i*self.ps) for i in range(3)]; self.p_tt = self.ptr(o+24+3*self.ps)
    def relocs(self, path):
        """(r_offset, r_info) of every dynamic relocation: plain REL/RELA sections plus APS2-packed ANDROID_REL(A)."""
        out = []
        for l in subprocess.check_output(['readelf', '-SW', path]).decode().splitlines():
            m = re.search(r'\]\s+(\S+)\s+(REL|RELA|ANDROID_REL|ANDROID_RELA)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)', l)
            if not m: continue
            kind, off, size = m.group(2), int(m.group(4), 16), int(m.group(5), 16)
            d = self.b[off:off+size]
            if kind in ('REL', 'RELA'):
                ent = (8 if kind == 'REL' else 12) if self.elf32 else (16 if kind == 'REL' else 24)
                fmt = ('<II' if kind == 'REL' else '<IIi') if self.elf32 else ('<QQ' if kind == 'REL' else '<QQq')
                out += [(r[0], r[1]) for r in struct.iter_unpack(fmt, d[:len(d)//ent*ent])]
                continue
            if d[:4] != b'APS2': continue
            pos = [4]
            def sleb():
                r = sh = 0
                while True:
                    byte = d[pos[0]]; pos[0] += 1; r |= (byte & 0x7f) << sh; sh += 7
                    if not byte & 0x80:
                        if byte & 0x40: r -= 1 << sh
                        return r
            n = sleb(); r_off = sleb(); r_info = 0; done = 0
            while done < n:
                gsz, gfl = sleb(), sleb()
                gdelta = sleb() if gfl & 2 else 0          # 1 grouped-by-info, 2 grouped-by-offset-delta, 4/8 addend
                if gfl & 1: r_info = sleb()
                if gfl & 8 and gfl & 4: sleb()
                for _ in range(gsz):
                    r_off += gdelta if gfl & 2 else sleb()
                    if not gfl & 1: r_info = sleb()
                    if gfl & 8 and not gfl & 4: sleb()
                    out.append((r_off, r_info))
                done += gsz
        return out
    def v2o(self, va):
        for o, v, sz in self.loads:
            if v <= va < v+sz: return va-v+o
        raise ValueError(f'va 0x{va:x} not in a LOAD segment')
    def u8(self, o): return self.b[o]
    def u16(self, o): return struct.unpack('<H', self.b[o:o+2])[0]
    def u32(self, o): return struct.unpack('<I', self.b[o:o+4])[0]
    def ptr(self, o): return self.u32(o) if self.elf32 else struct.unpack('<Q', self.b[o:o+8])[0]
    def table(self, va):            # qmi_idl_type_table_object
        if va not in self.tables:
            o = self.v2o(va)
            ps = self.ps
            self.tables[va] = dict(n_types=self.u16(o), n_msgs=self.u16(o+2), p_types=self.ptr(o+8), p_msgs=self.ptr(o+8+ps), p_ref=self.ptr(o+8+2*ps))
        return self.tables[va]
    def ref(self, top, i):
        """referenced table i of `top`: ('va', addr) or ('ext', symbol) when it lives in another lib (n_referenced_tables
        does not count the imported common table, so index past it)."""
        o = self.v2o(top['p_ref']) + self.ps*i; va = self.ptr(o)
        if va: return ('va', va)
        name, val = self.rel.get(o, ('?', 0))     # symbol-relocated: defined here (val) or imported
        return ('va', val) if val else ('ext', name)
    COMMON_MSGS = {0: 'get_supported_msgs_req (empty)', 1: 'get_supported_msgs_resp', 2: 'get_supported_fields_req', 3: 'get_supported_fields_resp'}
    COMMON_TYPES = {0: 'qmi_response_type_v01 {u16 result; u16 error}'}
    def element(self, o, ind):      # one type element; (next offset, (text, aggregate ref) | None at END)
        flags = self.u8(o); o += 1
        if flags & 0x08: flags |= self.u8(o) << 8; o += 1
        if flags & 0x8000: flags |= self.u8(o) << 16; o += 1
        if flags == 0x20: return o, None
        off = self.u8(o); o += 1
        if flags & 0x80: off |= self.u8(o) << 8; o += 1
        elif flags & 0x0200: off |= self.u8(o) << 8 | self.u8(o+1) << 16; o += 2
        t = flags & 7; txt = f'{"  "*ind}@{off:<4} {TYPES[t]}'; ref = None
        if flags & 0x40:
            n = self.u8(o); o += 1
            if flags & 0x20 or flags & 0x4000: n |= self.u8(o) << 8; o += 1
            if flags & 0x4000: o += 2
            txt += f'[{n}]' + (' var-len' if flags & 0x10 else '')
            if flags & 0x10 and t != 6 and not flags & 0x0100: o += 1
        if t == 7:
            lo, hi = self.u8(o), self.u8(o+1); o += 2
            ref = (hi & 0xf, ((hi >> 4) << 8) | lo); txt += f' type[{ref[0]}][{ref[1]}]'
        if flags & 0x400000: o += 4
        return o, (txt, ref)
    def dump_type(self, top, ref, ind, seen):
        tbl, idx = ref
        k, v = self.ref(top, tbl)
        if k == 'ext':
            print('  '*ind + f'(type {idx} of {v}, imported' + (f': {self.COMMON_TYPES.get(idx, "")}' if 'common_qmi' in v else '') + ')'); return
        tt = self.table(v); ent = self.v2o(tt['p_types']) + 2*self.ps*idx     # {u32 c_struct_sz; ptr encoded}
        print('  '*ind + f'struct type[{tbl}][{idx}] (sizeof {self.u32(ent)}):')
        o = self.v2o(self.ptr(ent+self.ps))
        while True:
            o, r = self.element(o, ind+1)
            if r is None: break
            print(r[0])
            if r[1] and r[1] not in seen: self.dump_type(top, r[1], ind+2, seen | {r[1]})
    def dump(self):
        print(f'service 0x{self.sid:x} ({NAMES.get(self.sid, "vendor/unknown")}) idl v{self.idlver} lib v{self.libver} maxmsg 0x{self.mml:x}')
        top = self.table(self.p_tt)
        for kind, cnt, p in zip(('REQ', 'RESP', 'IND'), self.n, self.ptrs):
            for i in range(cnt):
                e = self.v2o(p) + 6*i
                msg_id, tmid, maxlen = self.u16(e), self.u16(e+2), self.u16(e+4)
                k, v = self.ref(top, tmid >> 12)
                if k == 'ext':
                    print(f'\n== {kind} 0x{msg_id:04x}  wire max {maxlen}: message {tmid & 0xfff} of {v}' + (f' = {self.COMMON_MSGS.get(tmid & 0xfff, "")}' if 'common' in v else '')); continue
                mt = self.table(v); ment = self.v2o(mt['p_msgs']) + 2*self.ps*(tmid & 0xfff)
                csz, pt = self.u32(ment), self.ptr(ment+self.ps)
                print(f'\n== {kind} 0x{msg_id:04x}  wire max {maxlen}, C struct {csz} bytes')
                if pt == 0 or csz == 0: print('   (empty)'); continue
                o = self.v2o(pt)
                while True:
                    tf = self.u8(o); o += 1
                    if tf & 0x40: tlv = self.u8(o); o += 1; opt = f'optional (valid flag @-{tf & 0xf})'
                    else: tlv = tf & 0xf; opt = 'mandatory'
                    o, r = self.element(o, 1)
                    print(f'  TLV 0x{tlv:02x} {opt}: {r[0].strip()}')
                    if r[1]: self.dump_type(top, r[1], 3, {r[1]})
                    if tf & 0x80: break

def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ('live', 'table', 'lib', 'idl'):
        sys.exit('usage: qmi-services.py live [adb] | table <dump_servers.txt> | lib <file.so> [...] | idl <file.so> [svc-hex]')
    mode = sys.argv[1]
    if mode == 'live':
        adb = sys.argv[2] if len(sys.argv) > 2 else 'adb'
        out = subprocess.run([adb, 'shell', 'su -c cat /sys/kernel/debug/msm_ipc_router/dump_servers 2>/dev/null || cat /sys/kernel/debug/msm_ipc_router/dump_servers'],
                             capture_output=True, text=True).stdout
        if 'Service' not in out: sys.exit('no IPC-router service table: need root and /sys/kernel/debug mounted (QRTR device? use qrtr-lookup)')
        print_table(parse_table(out))
    elif mode == 'table':
        print_table(parse_table(open(sys.argv[2]).read()))
    elif mode == 'idl':
        path = sys.argv[2]; want = int(sys.argv[3], 16) if len(sys.argv) > 3 else None
        for sid, _v, _m, msgs in lib_objects(path):
            if want is None or sid == want: Idl(path, msgs['off']).dump()
    else:
        for path in sys.argv[2:]:
            objs = sorted(set((s, v, m, msgs['n'], tuple(msgs.get('req', []))) for s, v, m, msgs in lib_objects(path)))
            print(f'{path}:')
            for sid, idl, mml, n, req in objs:
                ids = '  req msg ids: ' + ' '.join(f'0x{x:04x}' for x in req[:24]) if req else ''
                print(f'   0x{sid:04x} idl v{idl} maxmsg 0x{mml:<5x} req/resp/ind {n[0]}/{n[1]}/{n[2]:<4} {NAMES.get(sid, "vendor/unknown")}{ids}')

if __name__ == '__main__': main()
