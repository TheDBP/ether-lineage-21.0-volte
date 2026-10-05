#!/usr/bin/env python3
# modem-xrefs.py -- cross-reference a Qualcomm Hexagon modem: map a VA to data, find pointers and
# Hexagon immext code references to an address, and resolve QShrink's compressed log strings. The other
# half of modem-decompress.sh: once you have q6.dis, this tells you which address a log line lives at and
# who references a global.
#
#   modem-xrefs.py <modem.elf> str   "<substring>"      strings matching, their pointers and immext refs
#   modem-xrefs.py <modem.elf> msg   <rodata VA> ...     QShrink msg_const {line<<16|ssid; strptr} -> text
#   modem-xrefs.py <modem.elf> ptr   <VA>                every 4-byte little-endian pointer to VA
#   modem-xrefs.py <modem.elf> xref  <VA>                Hexagon immext words that extend to VA (code refs)
#   modem-xrefs.py <modem.elf> read  <VA> [n]            hex+ascii dump of n bytes at VA
#
# QShrink/QDSS replaces a log format string with an 8-byte const in rodata: {u32 (line<<16)|ssid; u32}
# where the second word is a pointer to the (surviving) string or a hash (if the string was dropped).
# The diag macro loads that second word with a Hexagon `immext` + `r=##const`, so `xref <strptr>` on the
# pointer, or on the msg_const address itself, finds the exact log site in the decompressed code -- then
# read the surrounding function in q6.dis to see the branch that logs it.
#
# Hexagon immext: a word with bits 31:28 == 0 is an extender carrying imm[25:0] = ((w>>16)&0xfff)<<14 |
# (w&0x3fff); it sets the high bits of the next instruction's constant to imm<<6. `xref` reports the
# extender whose imm<<6 equals VA with its low 6 bits cleared (the common aligned-base case).
#
# Modem images are OEM-proprietary: run this under .scratch, never commit its output.
import struct, sys, re

def load(path):
    b = open(path, 'rb').read()
    phoff, = struct.unpack_from('<I', b, 28); phes, phn = struct.unpack_from('<HH', b, 42)
    segs = []
    for i in range(phn):
        t, off, va, pa, fsz, msz, fl, al = struct.unpack_from('<IIIIIIII', b, phoff + i*phes)
        if t == 1 and fsz: segs.append((va, fl & 7, b[off:off+fsz]))
    return segs

def seg_of(segs, va):
    for s, fl, d in segs:
        if s <= va < s + len(d): return s, fl, d
    return None

def read(segs, va, n):
    r = seg_of(segs, va)
    return r[2][va - r[0]: va - r[0] + n] if r else None

def find_u32(segs, v):
    pat = struct.pack('<I', v); out = []
    for s, fl, d in segs:
        out += [s + m.start() for m in re.finditer(re.escape(pat), d)]
    return out

def xref(segs, target):
    hi = target >> 6; out = []
    for s, fl, d in segs:
        if not fl & 1: continue      # executable only
        for off in range(0, len(d) - 4, 4):
            w, = struct.unpack_from('<I', d, off)
            if w >> 28: continue
            if (((w >> 16) & 0xfff) << 14 | (w & 0x3fff)) == hi: out.append(s + off)
    return out

def cstr(segs, va, n=300):
    b = read(segs, va, n)
    return b.split(b'\0')[0].decode('latin1') if b else None

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    segs = load(sys.argv[1]); cmd = sys.argv[2]
    if cmd == 'str':
        needle = sys.argv[3].encode()
        for s, fl, d in segs:
            for m in re.finditer(re.escape(needle), d):
                va = s + m.start()
                st = va - (d[:m.start()][::-1].find(b'\0'))      # back to prev NUL
                print(f'string @{st:08x}: "{cstr(segs, st)}"')
                for p in find_u32(segs, st): print(f'  ptr @{p:08x} (seg {seg_of(segs, p)[0]:08x})')
                for c in xref(segs, st): print(f'  immext @{c:08x}')
    elif cmd == 'msg':
        for a in sys.argv[3:]:
            va = int(a, 16); b = read(segs, va, 8)
            if not b: print(f'{va:08x}: unmapped'); continue
            hdr, p = struct.unpack('<II', b); s = cstr(segs, p)
            print(f'{va:08x}: line {hdr>>16} ssid {hdr&0xffff} -> {p:08x} ' +
                  (f'"{s}"' if s else '(hash/dropped)'))
    elif cmd == 'ptr':
        for p in find_u32(segs, int(sys.argv[3], 16)): print(f'{p:08x} (seg {seg_of(segs, p)[0]:08x})')
    elif cmd == 'xref':
        for c in xref(segs, int(sys.argv[3], 16)): print(f'{c:08x}')
    elif cmd == 'read':
        va = int(sys.argv[3], 16); n = int(sys.argv[4]) if len(sys.argv) > 4 else 64
        b = read(segs, va, n) or b''
        for i in range(0, len(b), 16):
            row = b[i:i+16]
            print(f'{va+i:08x}  {row.hex(" "):<48}  ' + ''.join(chr(c) if 32 <= c < 127 else '.' for c in row))
    else:
        sys.exit(__doc__)

if __name__ == '__main__':
    main()
