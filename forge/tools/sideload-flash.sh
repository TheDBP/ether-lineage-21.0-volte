#!/usr/bin/env bash
# sideload-flash.sh — unattended recovery flash of a ROM zip: sideload, optional data wipe, boot
# watch with a result line you can read the next morning.
#
#   sideload-flash.sh <rom.zip> [--wipe] [--recovery <img>] [-s SERIAL] [--check '<shell cmds>'] [--timeout S]
#
# For recovery-flashed (non-A/B) devices. The phone may be in any adb state: booted, recovery or
# already in sideload. Sequence:
#   1. --recovery: dd the given recovery image onto the recovery partition from the running
#      system (needs adb root) and verify it by sha256 before relying on it.
#   2. `adb reboot sideload`, wait for the sideload state, `adb sideload <zip>`.
#   3. --wipe: back in recovery, write `--wipe_data` to /cache/recovery/command and
#      `adb reboot recovery`; recovery wipes and reboots on its own. This is the only unattended
#      wipe that works everywhere -- `fastboot erase userdata` leaves no filesystem.
#   4. Poll until sys.boot_completed=1 (default 900 s), then print the --check commands (default:
#      getenforce, uptime, lineage version) and exit 0. Exit 1 with `logcat -b crash` otherwise.
#
# Run it detached (`setsid nohup ... > flash.out &`) and read the file: the summary line is
# "BOOT COMPLETED" or "no boot_completed in Ns". `adb root` is a developer setting that a wipe
# resets, which is why step 1 is done before the wipe and step 3 goes through recovery.
set -uo pipefail
ZIP="${1:?usage: sideload-flash.sh <rom.zip> [--wipe] [--recovery <img>] [-s SERIAL] [--check '<cmds>'] [--timeout S]}"; shift
WIPE=0; REC=""; SER=""; TO=900
CHECK='getenforce; uptime; getprop ro.lineage.version'
while [ $# -gt 0 ]; do
  case "$1" in
    --wipe) WIPE=1 ;;
    --recovery) REC="$2"; shift ;;
    -s) SER="$2"; shift ;;
    --check) CHECK="$2"; shift ;;
    --timeout) TO="$2"; shift ;;
    *) echo "!! unknown arg $1" >&2; exit 2 ;;
  esac; shift
done
[ -f "$ZIP" ] || { echo "!! no such zip: $ZIP" >&2; exit 1; }
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")
log(){ echo "$(date +%T) $*"; }
state(){ "${ADB[@]}" devices 2>/dev/null | awk 'NR==2{print $2}'; }
# wait_state <state> <seconds> -- measures real elapsed time, not iterations. Counting `sleep`s
# assumes each one actually sleeps and that `adb devices` is instant; when neither holds the loop
# gives up early while still reporting the full timeout, which reads as a device that never
# appeared. $SECONDS cannot drift like that. Exports WAITED so callers can report the truth.
wait_state(){ local t0=$SECONDS; until [ "$(state)" = "$1" ]; do sleep 5
    WAITED=$((SECONDS-t0)); [ "$WAITED" -ge "$2" ] && return 1; done; WAITED=$((SECONDS-t0)); }

log "zip $ZIP"
st=$(state)
if [ -n "$REC" ]; then
  [ "$st" = device ] || { log "--recovery needs the system booted (state=[${st:-none}])"; exit 1; }
  "${ADB[@]}" root >/dev/null 2>&1; sleep 2
  "${ADB[@]}" push "$REC" /data/local/tmp/recovery.img >/dev/null || { log "push failed"; exit 1; }
  "${ADB[@]}" shell 'blockdev --setrw /dev/block/bootdevice/by-name/recovery; dd if=/data/local/tmp/recovery.img of=/dev/block/bootdevice/by-name/recovery bs=1m 2>&1 | tail -1; sync'
  want=$(sha256sum "$REC" | cut -c1-64); sz=$(stat -c %s "$REC")
  got=$("${ADB[@]}" shell "dd if=/dev/block/bootdevice/by-name/recovery bs=$sz count=1 2>/dev/null | sha256sum" | cut -c1-64)
  [ "$want" = "$got" ] && log "recovery written and verified" || { log "recovery VERIFY FAILED"; exit 1; }
fi

if [ "$st" != sideload ]; then
  "${ADB[@]}" reboot sideload
  wait_state sideload 300 || { log "no sideload after ${WAITED}s (state=[$(state)]); on some bootloaders a reboot to recovery stops at a factory-reset prompt that shows no USB and needs physical keys"; exit 1; }
fi
log "in sideload"
"${ADB[@]}" sideload "$ZIP" 2>&1 | tr '\r' '\n' | tail -1
rc=${PIPESTATUS[0]}; log "sideload done rc=$rc"

if [ $WIPE = 1 ]; then
  wait_state recovery 180 || { log "no recovery adb after ${WAITED}s (state=[$(state)])"; exit 1; }
  log "requesting wipe_data via /cache/recovery/command"
  "${ADB[@]}" shell 'mount /cache 2>/dev/null; mkdir -p /cache/recovery; echo --wipe_data > /cache/recovery/command; sync'
  "${ADB[@]}" reboot recovery
else
  wait_state recovery 180 && "${ADB[@]}" reboot
fi

t0=$(date +%s)
while :; do
  s=$(state); el=$(( $(date +%s)-t0 ))
  if [ "$s" = device ]; then
    bc=$("${ADB[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    log "+${el}s adb=device boot_completed=[$bc]"
    if [ "$bc" = 1 ]; then log "BOOT COMPLETED"; "${ADB[@]}" shell "$CHECK" 2>&1; exit 0; fi
  elif [ "$s" = recovery ]; then
    log "+${el}s adb=recovery: $("${ADB[@]}" shell 'grep -iE "wip|format|erase" /tmp/recovery.log 2>/dev/null | tail -2' 2>/dev/null | tr '\n' '|')"
    # A wipe that finished without rebooting (some recoveries wait for a key) -- kick it.
    [ $el -gt 180 ] && { log "still in recovery, rebooting"; "${ADB[@]}" reboot; }
  else
    log "+${el}s adb=[${s:-none}]"
  fi
  [ $el -gt "$TO" ] && { log "no boot_completed in ${TO}s"; "${ADB[@]}" shell 'uptime; logcat -b crash -d | tail -40' 2>&1; exit 1; }
  sleep 30
done
