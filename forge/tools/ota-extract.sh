#!/usr/bin/env bash
# ota-extract.sh — pull the partition images out of a signed A/B OTA zip, and optionally flash
# them to one slot. Lets you park a second ROM on the inactive slot and switch between them with
# `fastboot set_active`, which is how you get a known-good reference to compare a broken build
# against on the same hardware.
#
#   ota-extract.sh <ota.zip> <outdir> [--flash a|b] [--os-only] [-s SERIAL]
#
# --flash    flash the extracted images to that slot. Logical partitions (system, system_ext,
#            product, vendor) need fastbootd, so the phone is sent there first.
# --os-only  flash only the OS partitions, leaving firmware (modem, abl, xbl, tz...) alone. This
#            is the safe default position: firmware is shared-ish, rarely the thing you are
#            testing, and xbl/abl are the two partitions that can actually brick a phone.
#
# This is the A/B payload.bin counterpart to unpack-block-ota.sh, which handles the older
# block-based OTAs (system.new.dat + transfer.list) that A-only devices ship.
#
# Needs ota_extractor from a built tree: out/host/linux-x86/bin/ota_extractor. Point OTA_EXTRACTOR
# at it, or run from a device repo with build_output/src/out/host/linux-x86/bin/ota_extractor.
set -u

ZIP="${1:?usage: ota-extract.sh <ota.zip> <outdir> [--flash a|b] [--os-only] [-s SERIAL]}"
OUT="${2:?usage: ota-extract.sh <ota.zip> <outdir> [--flash a|b] [--os-only] [-s SERIAL]}"
shift 2
SLOT=""; OS_ONLY=0; S=()
while [ $# -gt 0 ]; do
  case "$1" in
    --flash)   SLOT="$2"; shift 2 ;;
    --os-only) OS_ONLY=1; shift ;;
    -s)        S=(-s "$2"); shift 2 ;;
    *) echo "!! unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -f "$ZIP" ] || { echo "!! no such zip: $ZIP" >&2; exit 1; }
case "${SLOT:-a}" in a|b) ;; *) echo "!! --flash takes a or b" >&2; exit 1 ;; esac

EX="${OTA_EXTRACTOR:-}"
if [ -z "$EX" ]; then
  for c in out/host/linux-x86/bin/ota_extractor build_output/src/out/host/linux-x86/bin/ota_extractor; do
    [ -x "$c" ] && EX="$c" && break
  done
fi
[ -n "$EX" ] && [ -x "$EX" ] || { echo "!! ota_extractor not found; set OTA_EXTRACTOR" >&2; exit 1; }

mkdir -p "$OUT/imgs" || exit 1
echo ">> unpacking payload from $(basename "$ZIP")"
unzip -o -q "$ZIP" payload.bin payload_properties.txt -d "$OUT" || exit 1

echo ">> extracting partitions"
"$EX" -payload "$OUT/payload.bin" -output_dir "$OUT/imgs" || exit 1
ls -1 "$OUT/imgs" | sed 's/^/   /'

[ -z "$SLOT" ] && { echo ">> extracted to $OUT/imgs (not flashing)"; exit 0; }

# Logical partitions live in super and can only be written from fastbootd; the rest are real
# partitions the bootloader itself can write.
LOGICAL="system system_ext product vendor"
PHYSICAL="boot dtbo vbmeta"
[ "$OS_ONLY" -eq 1 ] || PHYSICAL="$PHYSICAL modem abl aop cmnlib cmnlib64 devcfg hyp keymaster qupfw tz xbl xbl_config"

echo ">> rebooting to fastbootd"
adb "${S[@]+"${S[@]}"}" reboot fastboot 2>/dev/null
for _ in $(seq 1 40); do fastboot "${S[@]+"${S[@]}"}" devices 2>/dev/null | grep -q fastboot && break; sleep 3; done
[ "$(fastboot "${S[@]+"${S[@]}"}" getvar is-userspace 2>&1 | head -1)" = "is-userspace: yes" ] || {
  echo "!! not in fastbootd; logical partitions cannot be written from the bootloader" >&2; exit 1; }

rc=0
for p in $LOGICAL $PHYSICAL; do
  [ -f "$OUT/imgs/$p.img" ] || continue
  printf '   %-12s ' "${p}_${SLOT}"
  # A flash can fail transiently on the first try; one retry costs nothing and saves a whole run.
  if ! fastboot "${S[@]+"${S[@]}"}" flash "${p}_${SLOT}" "$OUT/imgs/$p.img" >/dev/null 2>&1; then
    sleep 2
    fastboot "${S[@]+"${S[@]}"}" flash "${p}_${SLOT}" "$OUT/imgs/$p.img" >/dev/null 2>&1 || { echo "FAILED"; rc=1; continue; }
  fi
  echo "ok"
done

echo ">> setting slot $SLOT active"
fastboot "${S[@]+"${S[@]}"}" set_active "$SLOT" >/dev/null 2>&1
echo ">> done (rc=$rc). 'fastboot reboot' to boot it; 'fastboot set_active <other>' to go back."
exit $rc
