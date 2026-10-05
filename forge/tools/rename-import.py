#!/usr/bin/env python3
"""rename-import.py -- point ONE blob's import of a symbol at a differently-named replacement, by
rewriting the symbol's name in .dynstr in place (same length, undefined symbols only).

  rename-import.py <lib.so> <old-symbol> <new-symbol> [--check]

Why: a 2016 vendor blob calls a platform function with arguments the platform never accepted
(e.g. libimswms passes fmt=NULL to __android_log_print on every error path and segfaults in
vsnprintf), or a function whose semantics changed. Interposing the symbol process-wide
(LD_PRELOAD / a global shim earlier in the lookup order) hits every caller and is fragile in app
namespaces; patchelf cannot rename symbols. Renaming the import string makes exactly this blob
resolve `new-symbol`, which a shim library exports (add it with `patchelf --add-needed`). Only the
.dynstr bytes change, so hash tables/relocations stay valid: the string is referenced by offset
and undefined symbols are not in the GNU hash buckets. New name must be the same length (pad with
a trailing char if needed). ELF32 and ELF64, little-endian. Idempotent: exit 0 if already renamed.
"""
import struct, sys

def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    check = '--check' in sys.argv
    if len(a) != 3:
        print(__doc__); sys.exit(2)
    path, old, new = a
    if len(old) != len(new):
        print(f"!! names must have equal length ({len(old)} vs {len(new)})"); sys.exit(2)
    d = bytearray(open(path, 'rb').read())
    if d[:4] != b'\x7fELF': print("!! not ELF"); sys.exit(1)
    is64 = d[4] == 2
    if is64:
        shoff, shentsize, shnum = struct.unpack_from('<Q', d, 0x28)[0], struct.unpack_from('<H', d, 0x3a)[0], struct.unpack_from('<H', d, 0x3c)[0]
        shfmt = '<IIQQQQIIQQ'
    else:
        shoff, shentsize, shnum = struct.unpack_from('<I', d, 0x20)[0], struct.unpack_from('<H', d, 0x2e)[0], struct.unpack_from('<H', d, 0x30)[0]
        shfmt = '<IIIIIIIIII'
    secs = [struct.unpack_from(shfmt, d, shoff + i * shentsize) for i in range(shnum)]
    dynsym = next((s for s in secs if s[1] == 11), None)   # SHT_DYNSYM
    if not dynsym: print("!! no .dynsym"); sys.exit(1)
    dynstr = secs[dynsym[6]]                                # sh_link -> .dynstr
    stroff, strsize = dynstr[4], dynstr[5]
    symoff, symsize, entsize = dynsym[4], dynsym[5], dynsym[9]
    hits = []
    for i in range(symsize // entsize):
        o = symoff + i * entsize
        if is64:
            st_name, st_info, _, st_shndx = struct.unpack_from('<IBBH', d, o)
        else:
            st_name = struct.unpack_from('<I', d, o)[0]; st_info, _, st_shndx = struct.unpack_from('<BBH', d, o + 12)
        s = stroff + st_name; e = d.index(b'\0', s)
        name = d[s:e].decode()
        if name == new and st_shndx == 0:
            print(f"   {path}: {old} -> {new} already renamed"); sys.exit(0)
        if name == old:
            if st_shndx != 0:
                print(f"!! {old} is DEFINED in {path} (shndx {st_shndx}); only imports can be renamed"); sys.exit(1)
            hits.append(s)
    if not hits:
        print(f"!! {path}: no undefined symbol {old}"); sys.exit(1)
    if check:
        print(f"   {path}: would rename {old} -> {new} ({len(hits)} dynsym entr{'y' if len(hits)==1 else 'ies'})"); sys.exit(1)
    for s in hits:
        d[s:s + len(new)] = new.encode()
    open(path, 'wb').write(d)
    print(f"   {path}: {old} -> {new}")

if __name__ == '__main__':
    main()
