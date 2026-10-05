#!/usr/bin/env bash
# modem-strings.sh — pull the readable strings out of a modem firmware (the `modem.b*` segments)
# and sort them into the three lists that answer porting questions: which QMI request handlers the
# modem implements, which EFS/NV items it reads, and which source files the log lines come from.
#
#   modem-strings.sh <modem.image|dir with modem.b*|/firmware/image via adb:> <outdir>
#
#   <outdir>/all.txt       every string (>= 8 chars), one pass, keep it -- grep this later
#   <outdir>/qmi-req.txt   `qmi_*_req` handler names: the modem side of each QMI message a vendor
#                          RIL sends (`qmi_vss_set_ims_status_req` <-> lge_vss msg 0x0703)
#   <outdir>/efs.txt       `/nv/item_files/...` paths: the modem's configuration surface, readable
#                          and writable with diag-efs.sh
#   <outdir>/sources.txt   `file.c:` prefixes with counts: the subsystems that log (cmsds.c = Call
#                          Manager domain selection, qmi_nas_ims_extn.c, ...)
#
# Input is a raw ext4 modem partition image (KDZ/OTA extract; 7z reads ext4), a directory already
# holding modem.b00..bNN + modem.mdt, or `adb:` to pull /firmware/image/modem.b* from a device.
#
# Most of a Hexagon modem image is compressed (q6zip), so only a fraction of the strings survive:
# a 60 MB image yields ~50k strings. Presence proves a feature exists; absence proves nothing.
# Modem images are OEM-proprietary: keep the output under .scratch, never in a repo.
set -uo pipefail
IN="${1:?usage: modem-strings.sh <modem.image|dir|adb:> <outdir>}"
OUT="${2:?usage: modem-strings.sh <modem.image|dir|adb:> <outdir>}"
mkdir -p "$OUT/segments"
if [ "$IN" = adb: ]; then
  adb shell 'ls /firmware/image/modem.b* /vendor/firmware_mnt/image/modem.b* 2>/dev/null' | tr -d '\r' | while read -r f; do adb pull "$f" "$OUT/segments/" >/dev/null; done
elif [ -d "$IN" ]; then
  cp "$IN"/modem.b* "$OUT/segments/" 2>/dev/null
elif [ -f "$IN" ]; then
  7z e -y -o"$OUT/segments" "$IN" 'image/modem.b*' 'modem.b*' >/dev/null 2>&1
fi
n=$(ls "$OUT"/segments/modem.b* 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "!! no modem.b* segments found in $IN" >&2; exit 1; }
echo "  $n segments, $(du -sh "$OUT/segments" | cut -f1)"
cat "$OUT"/segments/modem.b* | strings -n 8 > "$OUT/all.txt"
echo "  $(wc -l < "$OUT/all.txt") strings -> $OUT/all.txt"
grep -oE 'qmi_[a-z0-9_]+_req' "$OUT/all.txt" | sort -u > "$OUT/qmi-req.txt"
grep -oE '/nv/item_files/[A-Za-z0-9_./-]+' "$OUT/all.txt" | sort -u > "$OUT/efs.txt"
grep -oE '^[a-z0-9_]+\.c:' "$OUT/all.txt" | sort | uniq -c | sort -rn > "$OUT/sources.txt"
echo "  $(wc -l < "$OUT/qmi-req.txt") QMI request handlers, $(wc -l < "$OUT/efs.txt") EFS items, $(wc -l < "$OUT/sources.txt") source files"
