#!/usr/bin/env bash
# fb-capture.sh — screenshot a device that has no screencap: recovery, or a boot that never reaches
# SurfaceFlinger.
#
#   fb-capture.sh [-o out.png] [-s SERIAL] [--fb N]
#
# Recovery has adbd but no screencap, so "what is on the screen" normally means asking someone to
# look. /dev/graphics/fb0 is readable there, and `adb exec-out dd` gets it off the device intact
# (plain `adb shell` mangles binary output, so exec-out is not optional).
#
# THE TRAP, and it will silently produce a plausible-looking wrong image: the line stride is not
# width * bpp/8. It is padded, and the padding is device specific -- 4352 bytes for a 1080-wide
# panel on one msm8992 here, i.e. 1088 pixels per line, not 1080. Reshape by width and every row
# walks sideways; you get a diagonally smeared picture that looks like a corrupt framebuffer rather
# than a decode bug, which is a great way to waste ten minutes. Always take the stride from
# /sys/class/graphics/fb<N>/stride.
#
# Double buffering means virtual_size often reports twice the visible height. Only the first frame
# is captured; if the image looks like the previous frame, grab again.
#
# WHERE THIS WORKS: recovery, and any boot that has adbd but no SurfaceFlinger. NOT a booted
# Android -- there the read fails with ENODEV ("dd: /dev/graphics/fb0: read error: No such device")
# because SurfaceFlinger drives the panel through overlays and nothing backs the fbdev read path.
# That is not a bug to fix: a booted Android has screencap. This is for the case that does not.
#
# Needs python3 with Pillow on the host. Without it the raw buffer is kept and the geometry printed
# so you can decode it elsewhere.
set -uo pipefail

OUT="fb.png"; FB=0; SERIAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o)     OUT="$2"; shift 2 ;;
    -s)     SERIAL=(-s "$2"); shift 2 ;;
    --fb)   FB="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)      echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADB="${ADB:-adb}"
adb_() { "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" "$@"; }

SYS="/sys/class/graphics/fb$FB"
GEOM=$(adb_ shell "cat $SYS/virtual_size $SYS/stride $SYS/bits_per_pixel $SYS/modes 2>/dev/null" 2>/dev/null | tr -d '\r')
VIRT=$(printf '%s\n' "$GEOM" | sed -n 1p)
STRIDE=$(printf '%s\n' "$GEOM" | sed -n 2p)
BPP=$(printf '%s\n' "$GEOM" | sed -n 3p)
MODES=$(printf '%s\n' "$GEOM" | sed -n 4p)
[ -n "$VIRT" ] && [ -n "$STRIDE" ] || {
  echo "!! cannot read $SYS -- no framebuffer, or this domain cannot read it" >&2
  echo "   (adb shell as root helps; in recovery you are root already)" >&2
  exit 1; }

W=${VIRT%,*}; VH=${VIRT#*,}
# The panel height comes from `modes` (e.g. "U:1080x1920p-360"), not from dividing virtual_size by a
# guessed buffer count: on a 1080x1920 panel virtual_size is 1080,3840 and dividing by 3 gives 1280,
# which is >= the width and so looks perfectly reasonable while being wrong.
H=$(printf '%s' "$MODES" | sed -nE 's/.*[:_]?([0-9]+)x([0-9]+)p.*/\2/p' | head -1)
if [ -z "$H" ]; then
  H=$(( VH / 2 ))
  echo "   note: no usable 'modes'; assuming double buffering, panel height $H" >&2
fi

BYTES=$(( STRIDE * H ))
echo ">> fb$FB  ${W}x${H}  stride ${STRIDE}B  ${BPP}bpp  -> ${BYTES} bytes"
echo "   (virtual_size says ${VIRT}; taking the first frame)"

# /dev/graphics/fb* is root:graphics 0660, so the shell user cannot read it. In recovery you are
# already root; on a booted userdebug build `adb root` is needed first and its absence shows up as a
# zero-length read rather than an error.
ID=$(adb_ shell id -u 2>/dev/null | tr -d '\r')
[ "$ID" = "0" ] || echo "   !! not root (uid $ID) -- run 'adb root' first, or the read returns nothing"

RAW="${OUT%.png}.raw"
adb_ exec-out "dd if=/dev/graphics/fb$FB bs=$STRIDE count=$H 2>/dev/null" > "$RAW" || {
  echo "!! dd failed" >&2; exit 1; }
GOT=$(wc -c < "$RAW")
if [ "$GOT" -eq 0 ]; then
  echo "!! read 0 bytes from /dev/graphics/fb$FB" >&2
  echo "   two usual causes:" >&2
  echo "     - not root ('adb root'); the node is root:graphics 0660" >&2
  echo "     - a booted Android, where the read returns ENODEV because SurfaceFlinger owns the" >&2
  echo "       display through overlays. Use screencap there; this tool is for recovery." >&2
  rm -f "$RAW"; exit 1
fi
[ "$GOT" -ge "$BYTES" ] || echo "   !! short read: $GOT of $BYTES bytes; image may be truncated"

python3 - "$RAW" "$OUT" "$W" "$H" "$STRIDE" "$BPP" <<'PY'
import sys
raw, out, w, h, stride, bpp = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:7])
try:
    import numpy as np
    from PIL import Image
except ImportError:
    sys.exit(1)
buf = np.fromfile(raw, dtype=np.uint8)
need = stride * h
if buf.size < need:
    h = buf.size // stride
    need = stride * h
px = bpp // 8
img = buf[:need].reshape(h, stride // px, px)[:, :w, :]
# Measured RGBA on msm8992's mdssfb; fbdev elsewhere is often BGRA. If the colours come out
# swapped, reverse this slice -- it is the only thing that changes.
Image.fromarray(img[:, :, :3] if px >= 3 else img[:, :, 0]).save(out)
print("   wrote %s (%dx%d)" % (out, w, h))
print("   colours look swapped? the slice assumes RGBA; use img[:, :, 2::-1] for BGRA.")
PY
if [ $? -ne 0 ]; then
  echo ">> could not render (missing python3/Pillow, or a decode mismatch); kept the raw buffer at $RAW"
  echo "   decode it as ${W}x${H}, stride ${STRIDE} bytes, ${BPP}bpp, BGRA byte order"
  exit 0
fi
rm -f "$RAW"
exit 0
