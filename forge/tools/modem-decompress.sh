#!/usr/bin/env bash
# modem-decompress.sh -- decompress a Qualcomm Hexagon modem's q6zip code segment into a flat image
# you can disassemble, so the ~85% of the firmware that `modem-strings.sh` can't see becomes readable.
#
#   modem-decompress.sh <modem.elf|dir|modem.image> <outdir>
#
# Most of a modem image is compressed: one big R segment is q6zip (entropy ~7.9), paged, decompressing
# to a fixed virtual base (the dlpager mapping, typically 0xd0000000); a smaller RW segment is
# deltacomp. `modem-strings.sh` only recovers the plaintext, so any log line, EFS read or branch that
# lives in the compressed code is invisible -- this tool recovers the code itself.
#
#   <outdir>/modem.elf     reassembled ELF (segment headers from modem.b00 + each modem.bNN at its
#                          p_offset), the input q6unzip/objdump both want
#   <outdir>/q6.bin        decompressed q6zip image, one 4096-byte page per entry, so
#                          VA 0xd0000000 + page*0x1000 lands exactly (file is a flat VA image)
#   <outdir>/q6.elf        q6.bin wrapped in an ELF32 (e_machine 164 = Hexagon) based at the q6 VA, so
#                          `llvm-objdump -d` prints real addresses and resolves `call`/`jump` targets
#   <outdir>/q6.dis        llvm-objdump -d of q6.elf (the readable decompressed code)
#
# Then grep q6.dis like any disassembly. To find the code behind a specific QShrink'd log string, read
# its 8-byte msg_const {u32 line<<16|ssid; u32 strptr} in rodata, find the immext that loads strptr,
# and that is the log site (see docs/debugging-volte.md step 6).
#
# Parameters that are not auto-detected (print a note if the page size is wrong):
#   Q6_VA      q6zip segment virtual address (default: the R segment with the highest entropy)
#   Q6_BASE    decompressed virtual base    (default 0xd0000000, from the dlpager table)
#   LOOKBACK   q6zip lookback depth         (default: the value in {7,8} that yields 4096-byte pages)
# A page that does not come out to exactly 4096 bytes means LOOKBACK (try the other of 7/8) or the
# per-page meta-prefix handling is wrong for this q6zip version -- q6unzip.py --debug shows the opcodes.
#
# Needs python3, llvm-objdump (with hexagon), 7z/readelf; clones nlitsme/qualcomm-q6zip into the outdir
# if Q6ZIP is unset and it is not already there. Modem images are OEM-proprietary: outdir stays in
# .scratch, never a repo.
set -uo pipefail
IN="${1:?usage: modem-decompress.sh <modem.elf|dir|modem.image> <outdir>}"
OUT="${2:?usage: modem-decompress.sh <modem.elf|dir|modem.image> <outdir>}"
Q6_BASE="${Q6_BASE:-0xd0000000}"
mkdir -p "$OUT"

# 1. Get a reassembled ELF (b00 holds the program headers; each bNN is a segment at its p_offset).
ELF="$OUT/modem.elf"
if [ -f "$IN" ] && grep -q ELF <<<"$(head -c4 "$IN")" && [ "$(basename "$IN")" != modem.b00 ]; then
  cp "$IN" "$ELF"
else
  SEGDIR="$OUT/segments"; mkdir -p "$SEGDIR"
  if [ -d "$IN" ]; then cp "$IN"/modem.b* "$SEGDIR/" 2>/dev/null
  elif [ -f "$IN" ]; then 7z e -y -o"$SEGDIR" "$IN" 'image/modem.b*' 'modem.b*' >/dev/null 2>&1; fi
  [ -f "$SEGDIR/modem.b00" ] || { echo "!! no modem.b00 in $IN" >&2; exit 1; }
  python3 - "$SEGDIR" "$ELF" <<'EOF'
import struct, sys, os, glob
d, out = sys.argv[1], sys.argv[2]
b = open(os.path.join(d, 'modem.b00'), 'rb').read()
phoff, = struct.unpack_from('<I', b, 28); phes, phn = struct.unpack_from('<HH', b, 42)
size = 0; segs = []
for i in range(phn):
    t, off, va, pa, fsz, msz, fl, al = struct.unpack_from('<IIIIIIII', b, phoff + i*phes)
    f = os.path.join(d, f'modem.b{i:02d}')
    if t == 1 and fsz and os.path.exists(f):
        segs.append((off, open(f, 'rb').read())); size = max(size, off+fsz)
img = bytearray(size)
img[:len(b)] = b
for off, data in segs: img[off:off+len(data)] = data
open(out, 'wb').write(img)
print(f'  reassembled {out}: {len(img)} bytes, {len(segs)} segments')
EOF
fi

# 2. Find the q6zip segment unless told: the R-only PT_LOAD whose bytes parse as a q6zip header
# (a known version word and a page count consistent with the segment size). Several segments are
# high-entropy (another compressor, e.g. zlib, scores even higher), so entropy alone is not enough --
# the header parse is the discriminator.
Q6ZIP="${Q6ZIP:-$OUT/qualcomm-q6zip}"
[ -d "$Q6ZIP" ] || git clone -q https://github.com/nlitsme/qualcomm-q6zip "$Q6ZIP" || { echo "!! clone qualcomm-q6zip failed; set Q6ZIP=" >&2; exit 1; }
if [ -z "${Q6_VA:-}" ]; then
  Q6_VA=$(python3 - "$ELF" "$Q6ZIP" <<'EOF'
import struct, sys
b = open(sys.argv[1], 'rb').read(); sys.path.insert(0, sys.argv[2])
import q6unzip as Q
class A: pass
args = A(); args.dictsize = 0x4400; args.skipheader = None; args.verbose = 0; args.debug = False
phoff, = struct.unpack_from('<I', b, 28); phes, phn = struct.unpack_from('<HH', b, 42)
best = (0, 0)
for i in range(phn):
    t, off, va, pa, fsz, msz, fl, al = struct.unpack_from('<IIIIIIII', b, phoff + i*phes)
    if t != 1 or (fl & 7) != 4 or fsz < 0x100000: continue   # R-only, sizeable
    try:
        fh = Q.ElfReader(open(sys.argv[1], 'rb')); fh.seek(va)
        q6 = Q.Q6zipSegment(fh, args)
        n = len(q6.ptrs)
        if q6.version in (0x0500, 0x0600) and 0 < n*4096 <= fsz*64 and n > best[0]:
            best = (n, va)
    except Exception:
        pass
print(hex(best[1]))
EOF
)
fi
[ "$Q6_VA" != 0x0 ] || { echo "!! could not find a q6zip segment; set Q6_VA=" >&2; exit 1; }
echo "  q6zip segment @ $Q6_VA -> decompressed base $Q6_BASE"

# 3. q6unzip, one fixed 4096-byte page per entry.
LB="${LOOKBACK:-}"
python3 - "$ELF" "$Q6_VA" "$OUT/q6.bin" "$Q6ZIP" "$LB" <<'EOF'
import sys, os
elf, va, outp, q6zip, lb = sys.argv[1], int(sys.argv[2], 16), sys.argv[3], sys.argv[4], sys.argv[5]
sys.path.insert(0, q6zip)
import q6unzip as Q
class A: pass
args = A(); args.dictsize = 0x4400; args.skipheader = None; args.verbose = 0; args.debug = False
def run(lookback):
    fh = Q.ElfReader(open(elf, 'rb')); fh.seek(va)
    q6 = Q.Q6zipSegment(fh, args); C = Q.Q6Unzipper(q6.dict1, q6.dict2, lookback)
    pages = []; bad = 0
    for i in range(len(q6.ptrs)):
        try: u = Q.words2bytes(C.decompress(Q.bytes2words(q6.readchunk(i)), 0x400))
        except Exception: u = b''
        if len(u) != 4096: bad += 1
        pages.append((u + b'\0'*4096)[:4096])
    return pages, bad
cands = [int(lb)] if lb else [7, 8]
best = None
for cand in cands:
    pages, bad = run(cand)
    if best is None or bad < best[2]: best = (cand, pages, bad)
    if bad == 0: break
lookback, pages, bad = best
open(outp, 'wb').write(b''.join(pages))
print(f'  q6unzip lookback {lookback}: {len(pages)} pages, {bad} not 4096 bytes ({outp})')
if bad: print(f'  !! {bad} pages wrong size -- set LOOKBACK= (try the other of 7/8) or check q6zip version', file=sys.stderr)
EOF
[ -s "$OUT/q6.bin" ] || { echo "!! q6unzip produced nothing" >&2; exit 1; }

# 4. Wrap the flat image in a Hexagon ELF32 and disassemble.
python3 - "$OUT/q6.bin" "$Q6_BASE" "$OUT/q6.elf" <<'EOF'
import struct, sys
raw = open(sys.argv[1], 'rb').read(); base = int(sys.argv[2], 16); out = sys.argv[3]
shstr = b'\0.text\0.shstrtab\0'; ehsz = 52
text_off = ehsz; shstr_off = text_off + len(raw); shoff = (shstr_off + len(shstr) + 3) & ~3
eh = struct.pack('<16sHHIIIIIHHHHHH', b'\x7fELF\x01\x01\x01' + b'\0'*9, 2, 164, 1, base, 0, shoff, 0, ehsz, 32, 0, 40, 3, 2)
sh0 = b'\0'*40
sh1 = struct.pack('<IIIIIIIIII', 1, 1, 6, base, text_off, len(raw), 0, 0, 4, 0)
sh2 = struct.pack('<IIIIIIIIII', 7, 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0)
b = bytearray(eh + raw + shstr); b += b'\0'*(shoff - len(b)); b += sh0 + sh1 + sh2
open(out, 'wb').write(b)
EOF
llvm-objdump -d --no-show-raw-insn "$OUT/q6.elf" > "$OUT/q6.dis" 2>/dev/null
echo "  $(wc -l < "$OUT/q6.dis") lines -> $OUT/q6.dis (base $Q6_BASE)"
