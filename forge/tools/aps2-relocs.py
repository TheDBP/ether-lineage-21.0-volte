#!/usr/bin/env python3
# aps2-relocs.py — decode the Android-packed (APS2) dynamic relocations of a prebuilt ELF .so and print
# each one with its target symbol, because llvm-readelf/readelf cannot symbolise SHT_ANDROID_REL
# ("unable to read an entry ... from SHT_NULL") and that is exactly what you need when a vendor blob
# jumps to 0 through a vtable slot or GOT entry and you must know which symbol was meant to be there.
#
#   aps2-relocs.py <lib.so> [HEXOFFSET ...]      # all relocs, or only those at the given file offsets
#   aps2-relocs.py libims.so 0xb355cc             # e.g. the vtable slot a crash dereferenced
#
# Prints: offset type sym#N name val=... binding shndx (shndx=0 == UND: resolved at load time from
# another lib). ELF32 and ELF64. Handles DT_ANDROID_REL(A) emitted with --pack-dyn-relocs=android
# (SLEB128 groups: GROUPED_BY_INFO=1 / OFFSET_DELTA=2 / ADDEND=4 / HAS_ADDEND=8). RELR (the other
# packing) is relative-only and carries no symbols, so it is not what you are debugging.
import struct, sys

def main():
    if len(sys.argv) < 2: sys.exit(__doc__ or 'usage: aps2-relocs.py <lib.so> [HEXOFFSET ...]')
    f = open(sys.argv[1], 'rb').read()
    is64 = f[4] == 2
    if is64:
        shoff, shentsize, shnum, shstrndx = struct.unpack_from('<Q', f, 0x28)[0], *struct.unpack_from('<HHH', f, 0x3a)
        shfmt, symfmt, symsz = '<IIQQQQIIQQ', '<IBBHQQ', 24
    else:
        shoff, shentsize, shnum, shstrndx = struct.unpack_from('<I', f, 0x20)[0], *struct.unpack_from('<HHH', f, 0x2e)
        shfmt, symfmt, symsz = '<10I', '<IIIBBH', 16
    secs = []
    for i in range(shnum):
        t = struct.unpack_from(shfmt, f, shoff + i * shentsize)
        secs.append(dict(name=t[0], type=t[1], off=t[4], size=t[5]))
    shstr = secs[shstrndx]
    def cstr(o): return f[o:f.index(b'\0', o)].decode(errors='replace')
    def sname(s): return cstr(shstr['off'] + s['name'])
    dynsym = next(s for s in secs if sname(s) == '.dynsym'); dynstr = next(s for s in secs if sname(s) == '.dynstr')
    def sym(idx):
        t = struct.unpack_from(symfmt, f, dynsym['off'] + idx * symsz)
        if is64: st_name, st_info, _, st_shndx, st_value, _ = t
        else: st_name, st_value, _, st_info, _, st_shndx = t
        return cstr(dynstr['off'] + st_name), st_value, {0: 'LOCAL', 1: 'GLOBAL', 2: 'WEAK'}.get(st_info >> 4, str(st_info >> 4)), st_shndx
    rel = next((s for s in secs if s['type'] in (0x60000001, 0x60000002)), None)  # SHT_ANDROID_REL / RELA
    if not rel: sys.exit('!! no SHT_ANDROID_REL(A) section -- not APS2-packed; plain readelf -r works here')
    d = f[rel['off']:rel['off'] + rel['size']]
    if d[:4] != b'APS2': sys.exit(f'!! unexpected packing magic {d[:4]!r}')
    pos = [4]
    def sleb():
        r = sh = 0
        while True:
            b = d[pos[0]]; pos[0] += 1; r |= (b & 0x7f) << sh; sh += 7
            if not b & 0x80:
                return r - (1 << sh) if b & 0x40 else r
    BY_INFO, BY_OFFD, BY_ADDEND, HAS_ADDEND = 1, 2, 4, 8
    n, offset, out = sleb(), sleb(), []
    while len(out) < n:
        gsize, gflags = sleb(), sleb()
        goffd = sleb() if gflags & BY_OFFD else None
        ginfo = sleb() if gflags & BY_INFO else None
        if gflags & HAS_ADDEND and gflags & BY_ADDEND: sleb()
        for _ in range(gsize):
            offset += goffd if goffd is not None else sleb()
            info = ginfo if ginfo is not None else sleb()
            if gflags & HAS_ADDEND and not gflags & BY_ADDEND: sleb()
            out.append((offset, info))
    filt = {int(x, 16) for x in sys.argv[2:]}
    tn32 = {2: 'ABS32', 21: 'GLOB_DAT', 22: 'JUMP_SLOT', 23: 'RELATIVE'}
    tn64 = {257: 'ABS64', 1025: 'GLOB_DAT', 1026: 'JUMP_SLOT', 1027: 'RELATIVE'}
    for off, info in out:
        if filt and off not in filt: continue
        if is64: t, si = info & 0xffffffff, info >> 32
        else: t, si = info & 0xff, info >> 8
        tn = (tn64 if is64 else tn32).get(t, str(t))
        if si:
            nm, val, bind, shndx = sym(si)
            print(f'{off:08x} {tn:9} sym#{si} {nm} val={val:08x} {bind} shndx={shndx}')
        else:
            print(f'{off:08x} {tn:9} (no sym)')
    print(f'# {len(out)} relocs total', file=sys.stderr)

if __name__ == '__main__':
    main()
