#!/usr/bin/env python3
"""check-dt-needed.py — every ELF in a built image whose DT_NEEDED libraries are not in the image.

    check-dt-needed.py <out>/target/product/<device> [--partition system|vendor|all] [--quiet]

Walks system/, system_ext/, product/ (and with --partition vendor|all, vendor/ and odm/) plus the
flattened APEX payloads under apex/, reads each ELF's DT_NEEDED list straight from the dynamic
section (no readelf needed), and reports every library name that no searched directory provides
for that bitness. Exit 1 if anything is missing.

What it catches that a build does not: a prebuilt copied in with PRODUCT_COPY_FILES. Soong checks
the libraries it builds; a .so dropped in by path is never linked against anything, so a NEEDED
on a library the branch has since deleted (a VNDK-era HIDL client, say) only surfaces when the
first daemon that links it fails to start. The bionic linker reports that on stderr and _exit(1)s,
so init shows "exited with status 1" and nothing else -- and when that daemon is vold, the
device reboot-loops before adbd exists. Found this way on the LG V20 24.0 port: libhardware_legacy
from prebuilts/vndk/v32 wanting android.system.suspend@1.0.so, taking vold, audioserver,
dumpstate and libandroid_runtime down with it. Static, so run it on the out tree before flashing,
or on the previous build's out/ while the next one is still going.

Resolution is by name and bitness only. Linker namespaces are not modelled -- a system binary
whose library exists only under vendor/ is reported as found -- so this is a lower bound on what
will fail, with no false positives from namespace rules it does not understand. Libraries that
live in an APEX are resolved against apex/*/lib*/; a name found nowhere at all is the finding.
"""
import os, struct, sys

def elf_needed(path):
    """Return (bitness, [DT_NEEDED names]) or None if not a dynamic ELF."""
    try:
        with open(path, 'rb') as f:
            d = f.read()
    except OSError:
        return None
    if len(d) < 64 or d[:4] != b'\x7fELF':
        return None
    cls = d[4]
    le = d[5] == 1
    E = '<' if le else '>'
    if cls == 2:
        phoff, = struct.unpack_from(E + 'Q', d, 0x20)
        phentsize, phnum = struct.unpack_from(E + 'HH', d, 0x36)
        pfmt = E + 'IIQQQQQQ'  # type flags offset vaddr paddr filesz memsz align
    elif cls == 1:
        phoff, = struct.unpack_from(E + 'I', d, 0x1c)
        phentsize, phnum = struct.unpack_from(E + 'HH', d, 0x2a)
        pfmt = E + 'IIIIIIII'  # type offset vaddr paddr filesz memsz flags align
    else:
        return None
    loads, dyn = [], None
    for i in range(phnum):
        ph = struct.unpack_from(pfmt, d, phoff + i * phentsize)
        if cls == 2:
            ptype, _, off, vaddr, _, filesz, _, _ = ph
        else:
            ptype, off, vaddr, _, filesz, _, _, _ = ph
        if ptype == 1:
            loads.append((vaddr, off, filesz))
        elif ptype == 2:
            dyn = (off, filesz)
    if dyn is None:
        return None

    def v2o(vaddr):
        for lv, lo, lsz in loads:
            if lv <= vaddr < lv + lsz:
                return lo + (vaddr - lv)
        return None

    dfmt = E + ('qQ' if cls == 2 else 'iI')
    dsz = struct.calcsize(dfmt)
    off, size = dyn
    needed, strtab = [], None
    ents = []
    for i in range(size // dsz):
        tag, val = struct.unpack_from(dfmt, d, off + i * dsz)
        if tag == 0:
            break
        ents.append((tag, val))
        if tag == 5:
            strtab = val
    if strtab is None:
        return None
    so = v2o(strtab)
    if so is None:
        return None
    for tag, val in ents:
        if tag == 1:
            end = d.find(b'\0', so + val)
            needed.append(d[so + val:end].decode('ascii', 'replace'))
    return (64 if cls == 2 else 32), needed

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    quiet = '--quiet' in sys.argv
    part = 'system'
    for i, a in enumerate(sys.argv):
        if a == '--partition' and i + 1 < len(sys.argv):
            part = sys.argv[i + 1]
            args = [x for x in args if x != part]
    if len(args) != 1:
        print(__doc__); sys.exit(2)
    root = args[0].rstrip('/')

    sys_parts = ['system', 'system/system_ext', 'system_ext', 'system/product', 'product']
    ven_parts = ['vendor', 'system/vendor', 'odm', 'system/odm']
    scan = sys_parts[:] if part == 'system' else ven_parts[:] if part == 'vendor' else sys_parts + ven_parts
    # providers: everything a library could be found in, regardless of what is being scanned
    provider_dirs = sys_parts + ven_parts
    provided = {32: set(), 64: set()}
    for p in provider_dirs:
        for libdir, bits in (('lib', 32), ('lib64', 64)):
            dd = os.path.join(root, p, libdir)
            if os.path.isdir(dd):
                for r, _, fs in os.walk(dd):
                    provided[bits].update(fs)
    apex = os.path.join(root, 'apex')
    if os.path.isdir(apex):
        for a in os.listdir(apex):
            for libdir, bits in (('lib', 32), ('lib64', 64)):
                dd = os.path.join(apex, a, libdir)
                if os.path.isdir(dd):
                    for r, _, fs in os.walk(dd):
                        provided[bits].update(fs)

    missing = {}   # lib -> set(users)
    nelf = 0
    seen = set()
    for p in scan:
        base = os.path.join(root, p)
        if not os.path.isdir(base):
            continue
        for r, dirs, fs in os.walk(base):
            # a nested partition dir under system/ is scanned by its own entry (or not at all)
            dirs[:] = [x for x in dirs if os.path.join(r, x) not in
                       (os.path.join(root, q) for q in provider_dirs if q != p)]
            for f in fs:
                fp = os.path.join(r, f)
                if os.path.islink(fp):
                    continue
                rp = os.path.realpath(fp)
                if rp in seen:
                    continue
                seen.add(rp)
                res = elf_needed(fp)
                if not res:
                    continue
                bits, needed = res
                nelf += 1
                for n in needed:
                    if n not in provided[bits]:
                        missing.setdefault((n, bits), set()).add(os.path.relpath(fp, root))

    if not missing:
        if not quiet:
            print(">> dt-needed: %d ELF files under %s, every DT_NEEDED resolves" % (nelf, part))
        return 0
    print(">> dt-needed: %d library name(s) that nothing in the image provides (%d ELF files scanned)"
          % (len(missing), nelf))
    for (n, bits), users in sorted(missing.items()):
        print("   %s (%d-bit) needed by %d file(s):" % (n, bits, len(users)))
        for u in sorted(users)[:8]:
            print("      %s" % u)
        if len(users) > 8:
            print("      ... %d more" % (len(users) - 8))
    print()
    print("   Each is a link failure at exec time: the linker prints CANNOT LINK EXECUTABLE to stderr")
    print("   and _exit(1)s, so init only shows 'exited with status 1'. A prebuilt copied in by path")
    print("   (PRODUCT_COPY_FILES) is the usual source; confirm with llvm-readelf -d on the user.")
    return 1

if __name__ == '__main__':
    sys.exit(main())
