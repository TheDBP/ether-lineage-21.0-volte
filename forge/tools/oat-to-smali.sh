#!/usr/bin/env bash
# oat-to-smali.sh — turn a stock boot oat, app odex, vdex or apk into readable smali, so an OEM
# framework or app can be traced (Binder TRANSACTION_ ids, RIL request numbers, OEM hook calls).
#
#   oat-to-smali.sh <file.oat|.odex|.vdex|.apk|.dex> <outdir>
#
# Dex-preopted stock code ships with the dex embedded in an oat/odex (N, O) or vdex (O, P) rather
# than in the apk; `baksmali d` on the apk sees nothing. This carves every embedded dex out by its
# magic (`dex\n03x`) and the file_size field at +0x20, fixes the adler32 so dexdump accepts it, and
# disassembles each with `--allow-odex-opcodes` (quickened opcodes stay as `invoke-virtual-quick`
# etc; for reading a method, the surrounding `const`/`iget`/`invoke-static` lines are what matter).
# Q+ compact dex (`cdex001`) is not handled -- those devices still have classes.dex in the apk.
#
# Pull the stock file from a raw system image without flashing it:
#   debugfs -R 'dump /framework/arm64/boot-telephony-common.oat out.oat' system.image
# (the image root has no `system/` prefix). `strings` on the oat tells you which one holds a class.
#
# baksmali.jar comes from the Android tree (prebuilts/extract-tools/common/smali); set BAKSMALI to
# override.
set -uo pipefail
IN="${1:?usage: oat-to-smali.sh <file.oat|.odex|.vdex|.apk|.dex> <outdir>}"
OUT="${2:?usage: oat-to-smali.sh <file> <outdir>}"
[ -f "$IN" ] || { echo "!! no such file: $IN" >&2; exit 1; }
if [ -z "${BAKSMALI:-}" ]; then
  c="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/src/prebuilts/extract-tools/common/smali/baksmali.jar"
  [ -f "$c" ] && BAKSMALI="$c"
fi
[ -f "${BAKSMALI:-}" ] || { echo "!! baksmali.jar not found; set BAKSMALI=" >&2; exit 1; }
mkdir -p "$OUT"
# Scratch goes under the outdir, never /tmp.
W="$OUT/.dex"; mkdir -p "$W"

case "$IN" in
  *.apk|*.jar) unzip -o -q "$IN" 'classes*.dex' -d "$W" || { echo "!! no classes.dex in $IN (dex-stripped; feed the odex/vdex beside it)" >&2; exit 1; } ;;
  *.dex) cp "$IN" "$W/" ;;
  *) python3 - "$IN" "$W" <<'EOF'
import re, struct, sys, zlib, os
b = open(sys.argv[1], 'rb').read(); n = 0
for m in re.finditer(rb'dex\n03[5-9]\x00', b):
    off = m.start(); size = struct.unpack_from('<I', b, off + 0x20)[0]
    if size < 0x70 or off + size > len(b): continue
    d = bytearray(b[off:off + size])
    struct.pack_into('<I', d, 8, zlib.adler32(bytes(d[12:])) & 0xffffffff)
    p = os.path.join(sys.argv[2], f'{os.path.basename(sys.argv[1])}.{n}.dex'); open(p, 'wb').write(d)
    print(f'  dex {n} at 0x{off:x}, {size} bytes'); n += 1
if n == 0: sys.exit('!! no embedded dex (compact dex or no dex at all)')
EOF
  [ $? = 0 ] || exit 1 ;;
esac

for d in "$W"/*.dex; do
  java -jar "$BAKSMALI" d --allow-odex-opcodes "$d" -o "$OUT" 2>&1 | grep -v '^$' | tail -2
done
echo "  $(find "$OUT" -name '*.smali' | wc -l) smali files in $OUT"
