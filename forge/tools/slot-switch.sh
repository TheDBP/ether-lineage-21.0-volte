#!/usr/bin/env bash
# slot-switch.sh — switch an A/B device between the ROMs parked on its two slots, wiping the
# shared /data so the older one can boot, and putting the fresh install straight on the launcher.
#
#   slot-switch.sh <a|b> [--keep-data] [--no-provision] [-s SERIAL]
#
# Why the wipe is not optional by default: /data is a single partition shared by both slots. Once
# the newer Android has initialised user 0, the older one stops being able to, and its boot ends at
#   "Can't load Android system ... Reason: init_user0_failed"
# Nothing short of formatting clears that, and formatting takes the other side's setup with it --
# there is no way to keep both. See docs/debugging-a-vendor-blob.md.
#
# metadata is erased along with userdata on purpose: it holds the key for the metadata-encrypted
# /data, so wiping one without the other leaves a filesystem nothing can unlock.
#
# --keep-data is for switching back to the ROM that last owned /data, which does still boot.
set -u

SLOT="${1:?usage: slot-switch.sh <a|b> [--keep-data] [--no-provision] [-s SERIAL]}"
shift
case "$SLOT" in a|b) ;; *) echo "!! slot must be a or b" >&2; exit 1 ;; esac
WIPE=1; PROVISION=1; S=()
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-data)    WIPE=0; shift ;;
    --no-provision) PROVISION=0; shift ;;
    -s)             S=(-s "$2"); shift 2 ;;
    *) echo "!! unknown argument: $1" >&2; exit 1 ;;
  esac
done
ADB=(adb "${S[@]+"${S[@]}"}"); FB=(fastboot "${S[@]+"${S[@]}"}")

# Works from Android or recovery; if it is already in fastboot this is a no-op that fails harmlessly.
"${ADB[@]}" reboot bootloader 2>/dev/null
for _ in $(seq 1 40); do "${FB[@]}" devices 2>/dev/null | grep -q fastboot && break; sleep 3; done
"${FB[@]}" devices 2>/dev/null | grep -q fastboot || { echo "!! never reached the bootloader" >&2; exit 1; }

echo ">> setting slot $SLOT active"
"${FB[@]}" set_active "$SLOT" >/dev/null 2>&1 || { echo "!! set_active failed" >&2; exit 1; }

if [ "$WIPE" -eq 1 ]; then
  for p in userdata metadata; do
    printf '   erase %-9s ' "$p"
    "${FB[@]}" erase "$p" >/dev/null 2>&1 && echo ok || echo "FAILED (continuing)"
  done
fi

echo ">> rebooting (a wiped /data is formatted on first boot, so this one is slow)"
"${FB[@]}" reboot >/dev/null 2>&1

[ "$PROVISION" -eq 1 ] || { echo ">> done (not provisioning)"; exit 0; }

# The images this is used with are bringup builds, which accept adb from any host with no
# on-screen prompt. That is the only reason skipping setup can be automated at all.
echo ">> waiting for the ROM"
for _ in $(seq 1 90); do
  [ "$("${ADB[@]}" get-state 2>/dev/null)" = "device" ] &&
    [ "$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done
[ "$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] || {
  echo "!! never finished booting; check the screen" >&2; exit 1; }

if [ "$WIPE" -eq 1 ]; then
  echo ">> skipping setup wizard"
  "${ADB[@]}" shell settings put global device_provisioned 1 >/dev/null 2>&1
  "${ADB[@]}" shell settings put secure user_setup_complete 1 >/dev/null 2>&1
  # The wizard is already the focused task; sending it home is what actually gets rid of it.
  "${ADB[@]}" shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
fi

echo ">> on slot $("${FB[@]}" getvar current-slot 2>&1 | head -1 | awk '{print $2}' 2>/dev/null || echo "$SLOT"), booted:"
"${ADB[@]}" shell 'echo "   android $(getprop ro.build.version.release) / $(getprop ro.lineage.version)"' 2>/dev/null
