#!/usr/bin/env bash
# boot-window-logcat.sh — catch the logcat of a boot that ends in a reboot, through the seconds adbd
# is reachable. For a bringup build (adb without authorisation): each time the device appears, take
# adb root, stream `logcat -b all` and snapshot dmesg + properties until the connection drops, then
# wait for the next appearance. pstore is the other route; this one does not depend on the ramoops
# region surviving the reboot.
#
#   boot-window-logcat.sh <outdir> [-s SERIAL] [--timeout SECONDS]        default timeout 900
#
# Output: <outdir>/N.logcat, N.dmesg, N.props per appearance N. Stops on the timeout or Ctrl-C.
set -u
OUT="${1:?usage: boot-window-logcat.sh <outdir> [-s SERIAL] [--timeout SECONDS]}"; shift
S=(); TMO=900
while [ $# -gt 0 ]; do
  case "$1" in
    -s) S=(-s "$2"); shift 2 ;;
    --timeout) TMO="$2"; shift 2 ;;
    *) echo "!! unknown argument: $1" >&2; exit 1 ;;
  esac
done
mkdir -p "$OUT"
n=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$TMO" ]; do
  # wait-for-device returns only for state "device", i.e. adbd up and authorised.
  timeout 30 adb "${S[@]}" wait-for-device 2>/dev/null || continue
  n=$((n+1)); echo "$(date +%T) appearance $n"
  adb "${S[@]}" root >/dev/null 2>&1
  timeout 10 adb "${S[@]}" wait-for-device 2>/dev/null
  adb "${S[@]}" shell getprop > "$OUT/$n.props" 2>/dev/null &
  adb "${S[@]}" shell dmesg > "$OUT/$n.dmesg" 2>/dev/null &
  adb "${S[@]}" shell logcat -b all -v threadtime > "$OUT/$n.logcat" 2>/dev/null
  wait
  echo "$(date +%T) gone after $(wc -l < "$OUT/$n.logcat") logcat lines"
  # adbd's restart for root reads as a disconnect; give the next loop a fresh transport.
  sleep 1
done
