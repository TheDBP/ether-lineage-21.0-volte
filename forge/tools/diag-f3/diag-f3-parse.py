#!/usr/bin/env python3
"""Parse a raw DIAG HDLC stream (as written by diag-f3-capture) and print F3 EXT_MSG (0x79) text lines.

Layout per entry: cmd@0 ts_type@1 nargs@2 drop@3 ts u64@4 line u16@12 ssid u16@14 mask u32@16,
args u32 x nargs @20, then fmt\0 file\0. The args start at 20, not 16: with 16 every format string
reads as empty and the whole log looks hashed."""
import sys, struct, collections
data = open(sys.argv[1], 'rb').read()
frames = []; cur = bytearray(); esc = False
for b in data:
    if esc: cur.append(b ^ 0x20); esc = False
    elif b == 0x7d: esc = True
    elif b == 0x7e:
        if len(cur) > 2: frames.append(bytes(cur[:-2]))
        cur = bytearray()
    else: cur.append(b)
cmds = collections.Counter(f[0] for f in frames)
print("frames:", len(frames), "top cmds:", cmds.most_common(8), file=sys.stderr)
out = []
for f in frames:
    if f[0] != 0x79 or len(f) < 20: continue
    ts_type, nargs, drop = f[1], f[2], f[3]
    ts = struct.unpack_from('<Q', f, 4)[0]
    line, ssid, mask = struct.unpack_from('<HHI', f, 12)
    p = 20 + 4 * nargs
    if p > len(f): continue
    rest = f[p:].split(b'\0')
    fmt = rest[0].decode('latin1'); fn = rest[1].decode('latin1') if len(rest) > 1 else ''
    args = struct.unpack_from("<%dI" % nargs, f, 20) if nargs else ()
    try: txt = fmt % args if nargs else fmt
    except Exception: txt = fmt + ' ' + ' '.join('0x%x' % a for a in args)
    # ts: 1.25 ms units of 1/1024 s... DIAG timestamps: upper 48 bits = 1.25ms ticks
    out.append((ts, "%08x ssid=%d %s:%d %s" % ((ts >> 16) & 0xffffffff, ssid, fn, line, txt)))
for ts, l in out: print(l)
