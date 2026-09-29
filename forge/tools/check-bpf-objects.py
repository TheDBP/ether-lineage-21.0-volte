#!/usr/bin/env python3
"""check-bpf-objects.py — which BPF programs and maps of a built Android tree this kernel cannot load.

    check-bpf-objects.py --kernel <kernel-src>/include/uapi/linux/bpf.h --kver 4.9.337 \
        [--api 3700] [--modern <bionic or newer kernel bpf.h>] <out>/system/etc/bpf/**/*.o

Reads each object's .android_maps / .android_progs sections (the mainline bpf_map_def / bpf_prog_def
layout) and every `call` in each program, and compares map types, program types, attach types and
helper ids against the enums in the OLD kernel's uapi bpf.h. --modern names the missing ones (any
recent bpf.h, e.g. bionic/libc/kernel/uapi/linux/bpf.h). Definitions gated out of this kernel by
their own min/max kver are shown as skipped, not as failures. --api is the platform SDK level the
loader filters on (Android 17 = 3700). Static: run it while the build is still going, on the
previous build's out/ if need be; then check-bpf-readiness.sh --log on the phone.
"""
import struct, sys, re, os, glob, argparse

def enum_from_header(path, name):
    src = open(path, errors='replace').read()
    m = re.search(r'enum\s+%s\s*\{(.*?)\};' % name, src, re.S)
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    body = re.sub(r'//.*', '', body)
    vals = {}; n = 0
    for tok in body.split(','):
        tok = tok.strip()
        if not tok: continue
        if '=' in tok:
            k, v = [x.strip() for x in tok.split('=')]
            n = int(v, 0) if re.match(r'^[0-9xa-fA-F]+$', v) else vals[v]
        else:
            k = tok
        vals[k] = n; n += 1
    return vals

def helpers_from_header(path):
    src = open(path, errors='replace').read()
    # new style: FN(name) list inside __BPF_FUNC_MAPPER, or old-style enum bpf_func_id
    m = re.search(r'#define\s+___BPF_FUNC_MAPPER\(FN,ctx\.\.\.\)(.*)', src)
    if m:
        return {int(i): 'bpf_' + n for n, i in re.findall(r'FN\((\w+),\s*(\d+)', m.group(1))}
    e = enum_from_header(path, 'bpf_func_id')
    return {v: k.replace('BPF_FUNC_', 'bpf_') for k, v in e.items() if k != '__BPF_FUNC_MAX_ID'}

class Elf:
    def __init__(self, path):
        d = open(path, 'rb').read(); self.d = d
        assert d[:4] == b'\x7fELF' and d[4] == 2 and d[5] == 1
        (e_shoff,) = struct.unpack_from('<Q', d, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', d, 0x3a)
        secs = []
        for i in range(e_shnum):
            o = e_shoff + i * e_shentsize
            name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', d, o)
            secs.append(dict(name=name, type=typ, off=off, size=size, link=link, info=info, entsize=entsize, idx=i))
        strtab = secs[e_shstrndx]
        for s in secs:
            s['name'] = self.cstr(strtab['off'] + s['name'])
        self.secs = secs
        self.byname = {s['name']: s for s in secs}
        sym = [s for s in secs if s['type'] == 2][0]
        symstr = secs[sym['link']]
        self.syms = []
        for i in range(sym['size'] // 24):
            o = sym['off'] + i * 24
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', d, o)
            self.syms.append(dict(name=self.cstr(symstr['off'] + st_name), shndx=st_shndx, value=st_value, size=st_size, info=st_info))
    def cstr(self, o):
        e = self.d.index(b'\0', o); return self.d[o:e].decode(errors='replace')
    def data(self, s): return self.d[s['off']:s['off'] + s['size']]

def kv(v): return '%d.%d.%d' % (v >> 24, (v >> 16) & 0xff, v & 0xffff)

API = 3700
def main(kernel_uapi, files, kver=(4, 9, 337), modern=None):
    K = (kver[0] << 24) + (kver[1] << 16) + kver[2]
    helpers = helpers_from_header(kernel_uapi)
    map_types = {v: k for k, v in enum_from_header(kernel_uapi, 'bpf_map_type').items()}
    prog_types = {v: k for k, v in enum_from_header(kernel_uapi, 'bpf_prog_type').items()}
    attach_types = {v: k for k, v in enum_from_header(kernel_uapi, 'bpf_attach_type').items() if k != '__MAX_BPF_ATTACH_TYPE'}
    # names for the new side, from the loader's own idea (take from a modern header if given)
    mhelpers = helpers_from_header(modern) if modern else {}
    mmap = {v: k for k, v in enum_from_header(modern, 'bpf_map_type').items()} if modern else {}
    mprog = {v: k for k, v in enum_from_header(modern, 'bpf_prog_type').items()} if modern else {}
    matt = {v: k for k, v in enum_from_header(modern, 'bpf_attach_type').items()} if modern else {}
    print('kernel uapi: %d helpers, %d map types, %d prog types, %d attach types; kernel %s' % (len(helpers), len(map_types), len(prog_types), len(attach_types), kv(K)))
    for f in files:
        e = Elf(f)
        print('\n== %s' % f)
        # maps
        if '.android_maps' in e.byname:
            ms = e.byname['.android_maps']; md = e.data(ms)
            MAPSZ = 8 * 4 + 8 + 8 + 70 + 70 + 4
            for s in sorted([s for s in e.syms if s['shndx'] == ms['idx']], key=lambda s: s['value']):
                o = s['value']
                typ, ksz, vsz, maxe, flags, uid, gid, mode, minapi, maxapi, minkv, maxkv = struct.unpack_from('<8I2i2I', md, o)
                if not (API >= minapi and API < maxapi): continue
                gate = '' if (K >= minkv and K < maxkv) else '  [skipped: kver %s..%s]' % (kv(minkv), kv(maxkv))
                tname = mmap.get(typ, str(typ))
                ok = 'ok' if typ in map_types else 'MISSING-IN-KERNEL'
                print('  map  %-40s type=%-32s %s%s' % (s['name'][:-4], tname, ok, gate))
        # progs
        ps = e.byname.get('.android_progs')
        pdefs = {}
        if ps:
            pd = e.data(ps)
            for s in [s for s in e.syms if s['shndx'] == ps['idx']]:
                o = s['value']
                typ, att, uid, gid, minkv, maxkv, opt = struct.unpack_from('<6I?', pd, o)
                minapi, maxapi = struct.unpack_from('<2i', pd, o+28)
                pdefs[s['name']] = (typ, att, minkv, maxkv, opt, minapi, maxapi)
        for s in e.secs:
            if s['type'] != 1 or s['name'] in ('maps', 'progs', 'license', 'critical', 'bpfloader_min_ver', 'bpfloader_max_ver', 'netbpfload_min_ver', 'netbpfload_max_ver', 'size_of_bpf_map_def', 'size_of_bpf_prog_def', '.text', '.strtab', '.symtab') or s['name'].startswith('.'):
                continue
            code = e.data(s)
            if len(code) % 8 or not code: continue
            funcs = [y for y in e.syms if y['shndx'] == s['idx'] and (y['info'] & 0xf) == 2]
            fname = funcs[0]['name'] if funcs else '?'
            d = pdefs.get(fname + '_def')
            if d is None: 
                continue
            typ, att, minkv, maxkv, opt, minapi, maxapi = d
            if not (API >= minapi and API < maxapi): continue
            gate = '' if (K >= minkv and K < maxkv) else '  [skipped on this kernel: kver %s..%s]' % (kv(minkv), kv(maxkv))
            calls = set()
            for i in range(0, len(code), 8):
                op, regs, off, imm = struct.unpack_from('<BBhi', code, i)
                if op == 0x85 and (regs & 0xf0) == 0:  # call helper (src_reg 0)
                    calls.add(imm)
                if op in (0x18,) :  # lddw takes 2 slots
                    pass
            missing = sorted(c for c in calls if c not in helpers)
            pt = mprog.get(typ, str(typ)); at = matt.get(att, str(att))
            pok = 'ok' if typ in prog_types else 'PROG-TYPE-MISSING'
            aok = 'ok' if (att in attach_types or att == 0) else 'ATTACH-TYPE-MISSING'
            print('  prog %-48s %s(%s) %s/%s%s%s' % (s['name'], pt, at, pok, aok, ' optional' if opt else '', gate))
            if missing:
                print('         helpers missing in kernel: %s' % ', '.join('%s(%d)' % (mhelpers.get(c, '?'), c) for c in missing))
if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--kernel', required=True, help='old kernel include/uapi/linux/bpf.h')
    ap.add_argument('--kver', required=True, help='kernel version the loader will see, e.g. 4.9.337')
    ap.add_argument('--api', type=int, default=3700, help='platform SDK level (default 3700)')
    ap.add_argument('--modern', help='a recent bpf.h, to name what is missing')
    ap.add_argument('objects', nargs='+')
    a = ap.parse_args()
    API = a.api
    kv_ = tuple(int(x) for x in a.kver.split('.')[:3])
    while len(kv_) < 3: kv_ += (0,)
    main(a.kernel, a.objects, kv_, a.modern)
