#!/usr/bin/env bash
# prop-effect.sh — answer "I set this property and nothing happened" properly, instead of setting
# more properties.
#
#   prop-effect.sh <property> [--image DIR] [-s SERIAL]
#
#   prop-effect.sh persist.cne.feature
#   prop-effect.sh persist.data.iwlan.enable --image out/target/product/<device>
#
# Three questions, in the order that actually resolves this:
#
#   1. Is it set, and what SELinux type does it carry?
#   2. Does anything in the image read it at all?
#   3. Is the domain that reads it allowed to read that type?
#
# (3) is the one people skip, and it is silent. A property whose reader cannot see it behaves
# exactly like a property you never set: no error, no log, the feature just stays off. Seen twice on
# one device --
#
#   bluetooth.core.le.vendor_capabilities.enabled fell through the generic "bluetooth." prefix onto
#   bluetooth_prop, which the stack may not read, so the gate silently defaulted to true.
#
#   persist.cne.feature was set to 1 and cnd was denied default_prop, so the Connectivity Engine
#   never saw its own master switch. Everything downstream behaved correctly given that input, which
#   is what made it take a day to find.
#
# (2) is the one that saves you from cargo-culting a build.prop diff. Stock setting a property is
# not evidence that anything in YOUR image consumes it. `strings` over the blobs answers it in
# seconds and will also hand you the neighbouring property names, which is usually where the real
# switch is hiding.
set -uo pipefail

PROP=""; IMAGE=""; SERIAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    -s)      SERIAL=(-s "$2"); shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       PROP="$1"; shift ;;
  esac
done
[ -n "$PROP" ] || { echo "usage: prop-effect.sh <property> [--image DIR] [-s SERIAL]" >&2; exit 1; }

ADB="${ADB:-adb}"
adb_() { "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" "$@"; }
export LC_ALL=C

echo ">> $PROP"

# ---- 1. value and label ----------------------------------------------------------------------
VALUE=$(adb_ shell "getprop '$PROP'" 2>/dev/null | tr -d '\r')
LABEL=$(adb_ shell "getprop -Z '$PROP'" 2>/dev/null | tr -d '\r')
if [ -z "$VALUE" ]; then
  echo "   value    (unset)"
else
  echo "   value    $VALUE"
fi
if [ -z "$LABEL" ]; then
  echo "   label    (no -Z support on this build; check property_contexts by hand)"
else
  echo "   label    $LABEL"
  case "$LABEL" in
    *default_prop*)
      echo "            ^ default_prop is the fallthrough for anything property_contexts does not"
      echo "              name. Plenty of domains are refused it. If a reader below is denied, that"
      echo "              is your bug -- give the prefix its own type rather than widening this one." ;;
  esac
fi

# ---- 2. who reads it -------------------------------------------------------------------------
echo ">> readers"
if [ -n "$IMAGE" ]; then
  [ -d "$IMAGE" ] || { echo "   !! no such directory: $IMAGE" >&2; exit 1; }
  FOUND=$(grep -rla --binary-files=text -- "$PROP" \
            "$IMAGE"/system/bin "$IMAGE"/system/lib64 "$IMAGE"/system/lib \
            "$IMAGE"/system/vendor/bin "$IMAGE"/system/vendor/lib64 "$IMAGE"/system/vendor/lib \
            "$IMAGE"/vendor/bin "$IMAGE"/vendor/lib64 "$IMAGE"/vendor/lib 2>/dev/null | sort -u)
else
  echo "   (searching on-device; pass --image <product dir> to search a build tree instead)"
  FOUND=$(adb_ shell "grep -rla '$PROP' /vendor/bin /vendor/lib64 /system/bin /system/lib64 2>/dev/null" \
            2>/dev/null | tr -d '\r' | sort -u)
fi
if [ -z "$FOUND" ]; then
  echo "   NOTHING reads this property."
  echo "   Setting it cannot do anything. If you took it from a stock build.prop, stock's consumer"
  echo "   is not in this image -- look for the switch its own blobs read instead (below)."
else
  printf '   %s\n' $FOUND
fi

# ---- 2b. neighbouring property names, which is usually where the real switch is ----------------
PREFIX="${PROP%.*}."
if [ -n "$FOUND" ]; then
  echo ">> other '$PREFIX*' names those binaries reference"
  for f in $FOUND; do
    if [ -n "$IMAGE" ]; then strings -a "$f" 2>/dev/null; else adb_ shell "strings -a '$f' 2>/dev/null" 2>/dev/null; fi
  done | tr -d '\r' | grep -E "^${PREFIX//./\\.}[A-Za-z0-9_.]*$" | sort -u | sed 's/^/   /'
fi

# ---- 3. is any domain being refused this type -------------------------------------------------
echo ">> denials on this type"
if [ -n "$LABEL" ]; then
  TYPE=$(printf '%s' "$LABEL" | awk -F: '{print $3}')
  DEN=$( { adb_ shell 'dmesg 2>/dev/null'; adb_ shell 'logcat -b all -d 2>/dev/null'; } \
         | grep -a 'avc: *denied' | grep -a ":$TYPE:" \
         | grep -oE 'comm="[^"]+".*tcontext=[^ ]+' | sed -E 's/ino=[0-9]+ //; s/dev="[^"]*" //' | sort -u )
  if [ -n "$DEN" ]; then
    printf '   %s\n' "$DEN"
    echo
    echo
    echo "   A reader in a denied domain sees nothing."
    if [ "$TYPE" = "default_prop" ]; then
      echo "   Do NOT fix this with get_prop(<domain>, default_prop): that grants read access to every"
      echo "   unlabelled property on the system. Give this prefix its own type in property_contexts"
      echo "   and grant that instead."
      echo "   Note how many domains appear above -- a long list is a systemic gap in the port, not"
      echo "   one bug, and the other entries are probably breaking features nobody has looked at."
    else
      echo "   Add get_prop(<domain>, $TYPE)."
    fi
    echo "   If you just moved this property onto a new type, check EVERY domain that could read it"
    echo "   before, not only the one you were fixing: relabelling takes access away as well as"
    echo "   granting it."
  else
    echo "   none seen (dmesg may have wrapped -- reproduce, then re-run)"
  fi
else
  echo "   skipped: no label"
fi
exit 0
