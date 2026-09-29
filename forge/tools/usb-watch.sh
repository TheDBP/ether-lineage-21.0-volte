#!/usr/bin/env bash
# usb-watch.sh — one line per USB/adb/fastboot state change, timestamped. For boot attempts you
# cannot see: "how long until it fell back to the bootloader", "did adbd ever come up".
#
#   usb-watch.sh [seconds] [logfile]        default 300 s; Ctrl-C to stop early
#
# Google 18d1: 4ee0 bootloader, 4ee7/d001 adb (recovery/fastbootd/bringup), 4ee1 MTP-only,
# 4ee2 MTP+adb. USB_VID overrides the vendor filter (18d1).
set -u
T="${1:-300}"; LOG="${2:-}"; VID="${USB_VID:-18d1}"
end=$((SECONDS + T)); last=""
while [ $SECONDS -lt $end ]; do
  u="$(lsusb 2>/dev/null | grep -o "$VID:[0-9a-f]*" | tr '\n' ' ')"
  a="$(adb devices 2>/dev/null | awk 'NR>1 && NF {print $2}' | tr '\n' ' ')"
  f="$(fastboot devices 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  cur="usb=[$u] adb=[$a] fb=[$f]"
  if [ "$cur" != "$last" ]; then
    line="$(date +%T) $cur"; echo "$line"; [ -n "$LOG" ] && echo "$line" >> "$LOG"; last="$cur"
  fi
  sleep 2
done
