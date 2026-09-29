#!/usr/bin/env bash
# bench-launch.sh — cold app-launch times over adb, for A/B-ing a runtime tuning on one phone.
#
#   ./tools/bench-launch.sh [-n N] [-s SERIAL] [pkg...]
#
# For each package: force-stop, settle, `am start -W` the launcher activity, take TotalTime. N runs
# (default 5), reports min / median / max in ms. Default package set is what a daily driver opens
# cold; pass your own to change it. Root is not needed for the timing itself.
#
# It measures one thing -- cold launch -- because that is what a governor retune is felt as. It is
# only meaningful as a same-phone, same-build comparison: run it, change the knobs (device repo
# tools/tuning-ab.sh), run it again. Absolute numbers across devices or ROMs mean nothing.
set -o pipefail

N=5; SER=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2;;
    -s) SER="$2"; shift 2;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) break;;
  esac
done
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")

PKGS=("$@")
[ ${#PKGS[@]} -gt 0 ] || PKGS=(com.android.settings org.mozilla.fennec_fdroid com.android.messaging
                                org.lineageos.aperture com.fsck.k9 org.fdroid.fdroid com.termoneplus)

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "!! no device on adb" >&2; exit 1; }

# Launcher activity of a package, via the package manager, so we launch what the icon launches.
_activity() {
  "${ADB[@]}" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$1" 2>/dev/null \
    | tr -d '\r' | tail -n1
}

_median() { sort -n | awk '{a[NR]=$1} END{ if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }'; }

printf '%-28s %5s %6s %5s  (%d cold launches each, ms)\n' package min median max "$N"
for pkg in "${PKGS[@]}"; do
  act="$(_activity "$pkg")"
  case "$act" in */*) ;; *) printf '%-28s  not installed / no launcher activity\n' "$pkg"; continue;; esac
  times=()
  for _ in $(seq "$N"); do
    "${ADB[@]}" shell am force-stop "$pkg" >/dev/null 2>&1
    sleep 2
    t="$("${ADB[@]}" shell am start -W -n "$act" 2>/dev/null | tr -d '\r' | awk '/^TotalTime:/ {print $2}')"
    [ -n "$t" ] && times+=("$t")
    "${ADB[@]}" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
    sleep 1
  done
  [ ${#times[@]} -gt 0 ] || { printf '%-28s  no TotalTime from am start\n' "$pkg"; continue; }
  printf '%-28s %5s %6s %5s\n' "$pkg" \
    "$(printf '%s\n' "${times[@]}" | sort -n | head -n1)" \
    "$(printf '%s\n' "${times[@]}" | _median)" \
    "$(printf '%s\n' "${times[@]}" | sort -n | tail -n1)"
done
