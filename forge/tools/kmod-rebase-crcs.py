#!/usr/bin/env python3
"""kmod-rebase-crcs.py — make a .ko built against one kernel build load on another build of the same source.
Rewrites its __versions CRCs to the ones the target kernel exports.

  kmod-rebase-crcs.py <module.ko> <target-Image> <kallsyms.txt> [out.ko]

<target-Image> is the uncompressed arm64 Image of the kernel that will load the module (unpack the
boot.img, gunzip the kernel). <kallsyms.txt> is `/proc/kallsyms` from that kernel running as root
with kptr_restrict=0; it supplies _text and the __start/__stop___ksymtab[_gpl] / __start___kcrctab[_gpl]
addresses, which the Image has no header for. CRC symbols themselves (__crc_*) are absolute and
kallsyms does not list them, so the table has to come from the Image.

WHY: with CONFIG_MODVERSIONS the loader compares a CRC per imported symbol. genksyms computes them
from the preprocessed source, and some (module_layout, param_ops_*) differ between toolchains even
with identical source and config, so a module from the ROM tree will not load on the official
nightly's kernel: "disagrees about version of symbol module_layout". Rewriting the CRC is a promise
that the struct layouts are the same; keep it by diffing /proc/config.gz against KERNEL_OBJ/.config.
Needs no CONFIG_MODULE_FORCE_LOAD, which Android kernels never set.

4.4-era layout only: struct kernel_symbol = {u64 value; char *name}, kcrctab entries u64,
__versions entries 64 bytes {u64 crc; char name[56]}. Kernels built with
CONFIG_HAVE_ARCH_PREL32_RELOCATIONS (4.19+) use 32-bit relative entries and are not handled."""
import struct, sys

def sections(d):
    shoff = struct.unpack_from('<Q', d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQ', d, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    name = lambda n: d[stro + n:d.index(b'\0', stro + n)].decode()
    return {name(s[0]): (s[4], s[5]) for s in secs}

def module_versions(d):
    off, size = sections(d)['__versions']
    for i in range(size // 64):
        e = off + i * 64
        yield e, struct.unpack_from('<Q', d, e)[0], d[e + 8:e + 64].split(b'\0')[0].decode()

def kernel_crcs(image, kallsyms):
    syms = {}
    for line in open(kallsyms):
        parts = line.split()
        if len(parts) >= 3 and parts[2].startswith(('_text', '__start___k', '__stop___k')):
            syms[parts[2]] = int(parts[0], 16)
    base = syms['_text']
    off = lambda a: a - base
    cstr = lambda a: image[off(a):image.index(b'\0', off(a))].decode(errors='replace')
    out = {}
    for tab, crc in (('__start___ksymtab', '__start___kcrctab'), ('__start___ksymtab_gpl', '__start___kcrctab_gpl')):
        stop = syms.get(tab.replace('start', 'stop'))
        if tab not in syms or crc not in syms or stop is None:
            continue
        n = (stop - syms[tab]) // 16
        for i in range(n):
            value, namep = struct.unpack_from('<QQ', image, off(syms[tab]) + i * 16)
            out[cstr(namep)] = struct.unpack_from('<Q', image, off(syms[crc]) + i * 8)[0] & 0xffffffff
    return out

def main():
    if len(sys.argv) not in (4, 5):
        print(__doc__); sys.exit(2)
    ko = bytearray(open(sys.argv[1], 'rb').read())
    image = open(sys.argv[2], 'rb').read()
    if image[56:60] != b'ARM\x64':
        sys.exit('!! %s is not an uncompressed arm64 Image (no ARM64 magic at offset 56)' % sys.argv[2])
    kcrc = kernel_crcs(image, sys.argv[3])
    changed = 0
    for e, crc, name in module_versions(ko):
        if name not in kcrc:
            print('?? %-28s not exported by the target kernel; it will not load' % name); continue
        if kcrc[name] != crc:
            print('%-28s 0x%08x -> 0x%08x' % (name, crc, kcrc[name])); struct.pack_into('<Q', ko, e, kcrc[name]); changed += 1
    out = sys.argv[4] if len(sys.argv) == 5 else sys.argv[1]
    open(out, 'wb').write(ko)
    print('%d CRCs rewritten -> %s' % (changed, out))

if __name__ == '__main__':
    main()
