#!/usr/bin/env bash
# unpack-block-ota.sh — turn a block-based OTA zip into a mountable image you can read.
#
#   ./tools/unpack-block-ota.sh <ota.zip> <outdir> [partition]
#
#   partition   defaults to "system"; use "vendor"/"product" for zips that ship those separately
#
# Why: the fastest way to answer "what does a WORKING build for this device actually contain?" is to
# read one. A third-party build for the same device on your target branch is ground truth for the
# SELinux policy, the prop set, and the blob list -- worth far more than guessing from source. This
# unpacks the old-style block OTA (system.new.dat[.br] + system.transfer.list) that A-only devices
# still ship; for A/B payload.bin OTAs use ota-extract.sh instead.
#
# Needs: brotli (AOSP builds one at out/host/linux-x86/bin/brotli), python3, and debugfs (e2fsprogs)
# if you want to list or extract files afterwards.
set -euo pipefail

ZIP="${1:?usage: unpack-block-ota.sh <ota.zip> <outdir> [partition]}"
OUT="${2:?need an output directory}"
PART="${3:-system}"

mkdir -p "$OUT"
cd "$OUT"

DAT="$PART.new.dat"
LIST="$PART.transfer.list"

echo ">> extracting $PART from $(basename "$ZIP")"
unzip -o -q "$ZIP" "$DAT.br" "$LIST" 2>/dev/null || unzip -o -q "$ZIP" "$DAT" "$LIST"

if [ -f "$DAT.br" ]; then
  BROTLI="${BROTLI:-$(command -v brotli || true)}"
  if [ -z "$BROTLI" ]; then
    BROTLI=$(ls /*/*/*/build_output/src/out/host/linux-x86/bin/brotli 2>/dev/null | sed -n 1p || true)
  fi
  [ -n "$BROTLI" ] || { echo "!! need brotli; set BROTLI=/path/to/brotli" >&2; exit 1; }
  echo ">> brotli -d $DAT.br"
  "$BROTLI" -d -f -o "$DAT" "$DAT.br"
fi

echo ">> sdat2img -> $PART.img"
python3 - "$LIST" "$DAT" "$PART.img" <<'PY'
import sys
list_f, dat_f, img_f = sys.argv[1], sys.argv[2], sys.argv[3]
BLK = 4096
with open(list_f) as f:
    lines = f.read().splitlines()
version = int(lines[0]); total = int(lines[1])
# v2+ carries two extra header lines (stash entries) before the commands.
cmds = lines[4:] if version >= 2 else lines[2:]

def ranges(s):
    t = [int(x) for x in s.split(',')]
    return list(zip(t[1::2], t[2::2]))

with open(dat_f, 'rb') as dat, open(img_f, 'wb') as img:
    maxb = 0
    for line in cmds:
        if not line.strip():
            continue
        parts = line.split(' ', 1)
        op = parts[0]
        if op != 'new':          # zero/erase/stash contribute no data to a full OTA
            continue
        for begin, end in ranges(parts[1]):
            img.seek(begin * BLK)
            n = end - begin
            img.write(dat.read(n * BLK))
            maxb = max(maxb, end)
    img.truncate(maxb * BLK)
print(f"   transfer list v{version}, {total} blocks -> {maxb*BLK/(1024**3):.2f} GiB")
PY

ls -lh "$PART.img" | awk '{print "   "$NF"  "$5}'
cat <<NOTE

  Read it without mounting (no root needed):
    debugfs -R "ls -l /etc/selinux" $OUT/$PART.img
    debugfs -R "dump /build.prop $OUT/build.prop" $OUT/$PART.img
NOTE
