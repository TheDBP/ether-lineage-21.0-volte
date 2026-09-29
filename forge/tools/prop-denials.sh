#!/usr/bin/env bash
# prop-denials.sh — turn "N domains are denied a property type" into "these domains want these
# specific properties", so you can label the prefixes instead of widening the type.
#
#   prop-denials.sh [--image DIR] [-s SERIAL] [--type TYPE]
#
#   prop-denials.sh --image out/target/product/<device>
#   prop-denials.sh --type default_prop --image out/target/product/<device>
#
# WHY THIS IS NOT JUST "ADD THE ALLOW RULE"
#
# An avc denial on a property read tells you the domain and the TYPE, never the property. The
# tempting fix is get_prop(<domain>, default_prop). Do not: default_prop is the fallthrough for
# every name property_contexts does not match, so granting it hands that domain read access to
# everything unlabelled on the system, forever, including whatever a future branch adds.
#
# What you actually want is the intersection: of all the properties this domain's binaries
# reference, which ones currently carry the type it is being refused? That set is usually small and
# shares a prefix or two, and labelling those is a fix you can defend.
#
# HOW IT FINDS THE BINARIES
#
# From the live process, not from a guess: comm -> pid -> /proc/pid/maps, which picks up the vendor
# libraries as well as the executable. That matters -- cnd references exactly two property names
# itself and seventeen more from libcne.so, and looking only at the executable finds neither the
# master switch nor the feature switch next to it.
#
# A denial whose process is no longer running cannot be resolved this way; it is reported as such.
set -uo pipefail

IMAGE=""; SERIAL=(); WANT_TYPE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --type)  WANT_TYPE="$2"; shift 2 ;;
    -s)      SERIAL=(-s "$2"); shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADB="${ADB:-adb}"
adb_() { "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" "$@"; }
export LC_ALL=C
W=$(mktemp -d "${TMPDIR:-.}/prop-denials.XXXXXX"); trap 'rm -rf "$W"' EXIT

[ "$(adb_ shell id -u 2>/dev/null | tr -d '\r')" = "0" ] || \
  echo "!! not root; /proc/<pid>/maps will be unreadable for most domains. Run 'adb root'." >&2

echo ">> collecting property-read denials"
{ adb_ shell 'dmesg 2>/dev/null'; adb_ shell 'logcat -b all -d 2>/dev/null'; } \
  | grep -a 'avc: *denied' | grep -a 'tclass=file' | grep -a '_prop:' \
  | grep -oE 'comm="[^"]+".*' > "$W/raw" || true

# comm | denied type
awk '{
  c=""; t="";
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^comm=/)     { c = $i; sub(/^comm="/, "", c); sub(/"$/, "", c) }
    if ($i ~ /^tcontext=/) { t = $i; split(t, a, ":"); t = a[3] }
  }
  if (c != "" && t != "") print c "|" t
}' "$W/raw" | sort -u > "$W/pairs"

[ -n "$WANT_TYPE" ] && { grep "|$WANT_TYPE\$" "$W/pairs" > "$W/pairs.f" || true; mv "$W/pairs.f" "$W/pairs"; }
N=$(wc -l < "$W/pairs")
echo "   $N (domain, type) pairs"
[ "$N" -gt 0 ] || { echo "   nothing to do"; exit 0; }

# One pass over the whole property space, so each candidate can be typed without another adb round
# trip per name. getprop -Z on its own prints every property with its context on modern builds.
adb_ shell 'getprop -Z 2>/dev/null' 2>/dev/null | tr -d '\r' \
  | sed -nE 's/^\[([^]]+)\]: \[u:object_r:([^:]+):s0\]$/\1 \2/p' > "$W/proptypes"
PT=$(wc -l < "$W/proptypes")
echo "   $PT properties typed on the device"

# Read the pair list on fd 3: adb consumes stdin, so a plain `while read` loop would run exactly
# one iteration and look like it had finished.
while IFS='|' read -r COMM TYPE <&3; do
  echo
  echo ">> $COMM  denied  $TYPE"
  PID=$(adb_ shell "ps -A -o PID,CMD 2>/dev/null | awk -v c=\"$COMM\" 'index(\$2,c)==1{print \$1; exit}'" 2>/dev/null | tr -d '\r')
  if [ -z "$PID" ]; then
    # comm is truncated to 15 chars, so also try a substring match on the full command
    PID=$(adb_ shell "ps -A -o PID,CMD 2>/dev/null | grep -m1 -F \"$COMM\" | awk '{print \$1}'" 2>/dev/null | tr -d '\r')
  fi
  if [ -z "$PID" ]; then
    echo "   process not running now; cannot map it to binaries (reproduce while it is up)"
    continue
  fi
  FILES=$(adb_ shell "cat /proc/$PID/maps 2>/dev/null" 2>/dev/null | tr -d '\r' \
          | awk '{print $NF}' | grep -E '^/' | grep -vE '^/(dev|memfd|apex/[^/]+/lib[^/]*/bionic)' | sort -u)
  [ -n "$FILES" ] || { echo "   /proc/$PID/maps unreadable (need root)"; continue; }

  : > "$W/names"
  for f in $FILES; do
    LOCAL=""
    if [ -n "$IMAGE" ]; then
      for cand in "$IMAGE$f" "$IMAGE/system$f" "$IMAGE${f#/system}"; do
        [ -f "$cand" ] && { LOCAL="$cand"; break; }
      done
    fi
    if [ -n "$LOCAL" ]; then strings -a "$LOCAL" 2>/dev/null
    else adb_ shell "strings -a '$f' 2>/dev/null" 2>/dev/null | tr -d '\r'
    fi
  done | grep -E '^(persist|ro|vendor|sys|wifi|net|service|dalvik)\.[A-Za-z0-9_.-]+$' | sort -u > "$W/names"

  # the intersection: names this domain references that carry the type it is refused
  awk -v t="$TYPE" 'NR==FNR{ if ($2==t) want[$1]=1; next } ($0 in want){ print "   " $0 }' \
      "$W/proptypes" "$W/names" > "$W/hit" || true
  if [ -s "$W/hit" ]; then
    sort -u "$W/hit"
    echo "   -> label these prefixes in property_contexts and grant that type, not $TYPE"
  else
    echo "   none of the $(wc -l < "$W/names") property names it references currently carry $TYPE"
    echo "   (so this denial is probably a probe for something unset -- consider dontaudit, not allow)"
  fi
done 3< "$W/pairs"
echo
echo ">> done. Group the hits by prefix; one new type usually covers a whole daemon."
exit 0
