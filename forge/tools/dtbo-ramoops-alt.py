#!/usr/bin/env python3
"""dtbo-ramoops-alt.py — make the live ramoops console survive a clean reboot.

    dtbo-ramoops-alt.py <dtbo.img> <out.img> [--index N]

On Pixel-class Qualcomm devices the bootloader rewrites the primary ramoops region on every boot
(its own UEFI log lands there), so pstore is empty after a normal-boot failure that ends in a clean
`reboot` — init's reboot_on_failure, InitFatalReboot without the panic flag. The alt region
(`alt-memory-region`) is only written on a kernel panic and is left alone otherwise.

This swaps the `memory-region` and `alt-memory-region` phandles of every `compatible = "ramoops"`
node in the dtbo (or one entry with --index), byte-exact, nothing else touched. Flash the result to
the inactive slot's dtbo, normal-boot, then boot recovery and read
/sys/fs/pstore/console-ramoops-0: the whole failed boot, including init's last lines.

Debug image only. With the regions swapped a real panic overwrites the live ring. Restore the built
dtbo.img afterwards.
"""
import struct, sys

DT_MAGIC = 0xd7b7ab1e
FDT_MAGIC = 0xd00dfeed
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def fdt_props(blob, base):
    """Yield (node_path, prop_name, abs_value_offset, value_len) for every property."""
    magic, totalsize, off_struct, off_strings = struct.unpack_from('>IIII', blob, base)
    size_struct, = struct.unpack_from('>I', blob, base + 36)
    assert magic == FDT_MAGIC, 'entry at 0x%x is not an FDT' % base
    p = base + off_struct
    end = p + size_struct
    align = lambda q: base + ((q - base + 3) & ~3)   # entries in a dtbo are not 4-byte aligned
    path = []
    while p < end:
        tok, = struct.unpack_from('>I', blob, p); p += 4
        if tok == FDT_BEGIN_NODE:
            e = blob.index(b'\0', p)
            path.append(blob[p:e].decode(errors='replace'))
            p = align(e + 1)
        elif tok == FDT_END_NODE:
            path.pop()
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack_from('>II', blob, p); p += 8
            ne = blob.index(b'\0', base + off_strings + nameoff)
            name = blob[base + off_strings + nameoff:ne].decode()
            yield '/'.join(path), name, p, length
            p = align(p + length)
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            return
        else:
            raise SystemExit('bad FDT token 0x%x at 0x%x' % (tok, p - 4))


def swap_in_entry(blob, base):
    """Swap the two phandles of every ramoops node in the FDT at `base`. Returns node paths done."""
    nodes = {}
    for path, name, off, length in fdt_props(blob, base):
        n = nodes.setdefault(path, {})
        if name == 'compatible':
            n['ramoops'] = b'ramoops' in blob[off:off + length].split(b'\0')
        elif name in ('memory-region', 'alt-memory-region') and length == 4:
            n[name] = off
    done = []
    for path, n in nodes.items():
        if not n.get('ramoops'):
            continue
        if 'memory-region' not in n or 'alt-memory-region' not in n:
            print('  %s: ramoops node without both regions, skipped' % path)
            continue
        a, b = n['memory-region'], n['alt-memory-region']
        blob[a:a + 4], blob[b:b + 4] = blob[b:b + 4], blob[a:a + 4]
        done.append(path)
    return done


def main():
    args = sys.argv[1:]
    only = None
    if '--index' in args:
        i = args.index('--index'); only = int(args[i + 1]); del args[i:i + 2]
    if len(args) != 2:
        raise SystemExit(__doc__)
    src, dst = args
    blob = bytearray(open(src, 'rb').read())
    magic, total, hsize, esize, count, eoff, page, ver = struct.unpack_from('>8I', blob, 0)
    if magic != DT_MAGIC:
        raise SystemExit('%s: not a dtbo table (magic 0x%08x)' % (src, magic))
    patched = 0
    for i in range(count):
        dt_size, dt_offset, dt_id = struct.unpack_from('>III', blob, eoff + i * esize)
        if only is not None and i != only:
            continue
        done = swap_in_entry(blob, dt_offset)
        print('entry %d (id 0x%x, %d bytes): %s' % (i, dt_id, dt_size,
              ', '.join(done) if done else 'no ramoops node'))
        patched += len(done)
    if not patched:
        raise SystemExit('nothing patched')
    open(dst, 'wb').write(blob)
    print('%s written: %d ramoops node(s) swapped in %d entries' % (dst, patched, count))


if __name__ == '__main__':
    main()
