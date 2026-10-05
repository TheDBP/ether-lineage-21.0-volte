#!/usr/bin/env bash
# deodex-jar.sh -- turn an odexed boot jar / app oat into clean, reassemblable smali, resolving the
# quickened opcodes (iget-object-quick, invoke-virtual-quick vtable@N, return-void-no-barrier) that a
# plain `baksmali d --allow-odex-opcodes` leaves in place and that then refuse to reassemble.
#
#   deodex-jar.sh <target.oat|.odex> <bootcp-dir | system.image> <outdir>
#
# The quickening in an ART oat is relative to the boot image it was compiled against, so baksmali
# needs that whole boot classpath to turn it back into portable smali. Give it either a directory of
# the boot oats (e.g. /framework/arm64/*.oat already pulled) or a raw system image to pull them from.
#
#   deodex-jar.sh boot-ims-common.oat system.image out/      # pulls /framework/arm64/* from the image
#   deodex-jar.sh ims.odex ./bootcp out/                      # bootcp already extracted
#
# A clean result has zero quick opcodes; the tool checks and fails loudly if any survive (a partial
# deodex still assembles and installs and only breaks at runtime). Split (O+) boot images keep the
# dex in the .vdex beside each .oat -- the whole /framework/arm64 dir is extracted so baksmali finds
# them. For an app odex, pass the app's oat/odex and the matching boot image.
#
# Note: baksmali `list classes <oat>` prints Lpkg/Name; (not dotted). An oat's string table carries
# references to classes it does not DEFINE, so grep the deodexed smali tree to see what is really there.
#
# Needs baksmali.jar (ROM tree prebuilts/extract-tools/common/smali, or $BAKSMALI) and, for a raw
# image, debugfs (e2fsprogs). Deodexed OEM code is proprietary: keep the output under .scratch.
set -uo pipefail
IN="${1:?usage: deodex-jar.sh <target.oat|.odex> <bootcp-dir|system.image> <outdir>}"
CP="${2:?usage: deodex-jar.sh <target.oat|.odex> <bootcp-dir|system.image> <outdir>}"
OUT="${3:?usage: deodex-jar.sh <target.oat|.odex> <bootcp-dir|system.image> <outdir>}"
[ -f "$IN" ] || { echo "!! no such target: $IN" >&2; exit 1; }
if [ -z "${BAKSMALI:-}" ]; then
  c="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/src/prebuilts/extract-tools/common/smali/baksmali.jar"
  [ -f "$c" ] && BAKSMALI="$c"
fi
[ -f "${BAKSMALI:-}" ] || { echo "!! baksmali.jar not found; set BAKSMALI=" >&2; exit 1; }

# Resolve the boot classpath directory.
if [ -d "$CP" ]; then
  BOOTCP="$CP"
elif [ -f "$CP" ]; then
  BOOTCP="$OUT/.bootcp"; mkdir -p "$BOOTCP"
  if [ -z "$(ls -A "$BOOTCP" 2>/dev/null)" ]; then
    command -v debugfs >/dev/null || { echo "!! debugfs needed to read $CP" >&2; exit 1; }
    echo "  extracting /framework/arm64 boot classpath from $(basename "$CP")"
    for d in /framework/arm64 /system/framework/arm64 /framework/oat/arm64; do
      debugfs -R "rdump $d $BOOTCP" "$CP" >/dev/null 2>&1 && break
    done
    find "$BOOTCP" -mindepth 2 -name '*.oat' -exec sh -c 'mv "$1" "$(dirname "$2")"/' _ {} "$BOOTCP" \; 2>/dev/null
    # flatten one level if rdump nested under arm64/
    for sub in "$BOOTCP"/arm64 "$BOOTCP"/*/arm64; do [ -d "$sub" ] && mv "$sub"/* "$BOOTCP"/ 2>/dev/null; done
  fi
  n=$(ls "$BOOTCP"/*.oat 2>/dev/null | wc -l); [ "$n" -gt 0 ] || { echo "!! no boot oats extracted from $CP" >&2; exit 1; }
  echo "  $n boot oats in $BOOTCP"
else
  echo "!! classpath arg is neither a dir nor a file: $CP" >&2; exit 1
fi

mkdir -p "$OUT"
echo "  deodexing $(basename "$IN") against the boot classpath"
java -jar "$BAKSMALI" x -d "$BOOTCP" "$IN" -o "$OUT" 2>/dev/null || { echo "!! baksmali deodex failed" >&2; exit 1; }
nfiles=$(find "$OUT" -name '*.smali' | wc -l)
q=$(grep -rhoE '\b(invoke-virtual-quick|invoke-super-quick|iget[-a-z]*-quick|iput[-a-z]*-quick|return-void-no-barrier|execute-inline)\b' "$OUT" 2>/dev/null | wc -l)
echo "  $nfiles smali files, leftover quick opcodes: $q"
[ "$q" = 0 ] || { echo "!! deodex incomplete ($q quick opcodes) -- wrong/partial boot classpath; do not reassemble this" >&2; exit 1; }
echo "  clean -> $OUT"
