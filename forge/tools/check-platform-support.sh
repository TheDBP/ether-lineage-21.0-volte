#!/usr/bin/env bash
# check-platform-support.sh — find the upstream makefile gates that SILENTLY EXCLUDE this device's SoC.
#
#   ./tools/check-platform-support.sh <SRC> <DEVICE_PATH> [TARGET_BOARD_PLATFORM]
#
#   SRC          a synced AOSP/LineageOS tree
#   DEVICE_PATH  e.g. device/nextbit/ether  (TARGET_BOARD_PLATFORM is read from its BoardConfig)
#
# RUN THIS BEFORE PORTING A DEVICE TO A NEW BRANCH. It is the cheapest predictor of how much work the
# port will be, and it needs no build.
#
# Platform support in AOSP/CAF trees is gated by makefile lines shaped like:
#
#   ifneq (,$(filter sdm660 msm8937 msm8953 msm8996 msm8998,$(TARGET_BOARD_PLATFORM)))
#
# When a SoC ages out, upstream quietly drops it from these lists. Nothing errors: the guarded block
# simply stops contributing, and the failures surface later as unrelated-looking breakage. On the
# lineage-19.1 ether port (msm8992) the whole sepolicy saga -- six build cycles, "unknown type
# adsprpcd_file", "unknown type perfd", and a neverallow wall -- was ONE such list in
# device/qcom/sepolicy-legacy/SEPolicy.mk that no longer named msm8992.
#
# Output marks each gate IN (SoC listed) or OUT (excluded). Read every OUT line as: "whatever this
# block sets up, this device no longer gets."
set -uo pipefail
export LC_ALL=C

SRC="${1:?usage: check-platform-support.sh <SRC> <DEVICE_PATH> [PLATFORM]}"
DEV="${2:?need DEVICE_PATH, e.g. device/nextbit/ether}"
PLAT="${3:-}"

if [ -z "$PLAT" ]; then
  PLAT=$(grep -rhE '^[[:space:]]*TARGET_BOARD_PLATFORM[[:space:]]*:?=' "$SRC/$DEV"/BoardConfig*.mk 2>/dev/null \
         | head -1 | sed -E 's/.*:?=[[:space:]]*//' | tr -d ' ')
fi
[ -n "$PLAT" ] || { echo "!! could not determine TARGET_BOARD_PLATFORM; pass it as arg 3" >&2; exit 1; }

echo "=== platform gates for $DEV  (TARGET_BOARD_PLATFORM = $PLAT)"
echo "    [OUT] gates are listed first -- those are the blocks this device no longer gets."
echo

scan_dirs=()
for d in device/qcom device/lineage vendor/lineage hardware/qcom-caf build/make; do
  [ -d "$SRC/$d" ] && scan_dirs+=("$SRC/$d")
done
[ ${#scan_dirs[@]} -gt 0 ] || { echo "!! nothing to scan under $SRC" >&2; exit 1; }

n_out=0; n_in=0
# Every $(filter <list>,$(TARGET_BOARD_PLATFORM)) gate, with the list it tests against.
grep -rhnE '\$\(filter[^,]*,[[:space:]]*\$\(TARGET_BOARD_PLATFORM\)\)' "${scan_dirs[@]}" \
     --include='*.mk' --include='*.bp' -l 2>/dev/null | sort -u | while read -r f; do
  grep -nE '\$\(filter[^,]*,[[:space:]]*\$\(TARGET_BOARD_PLATFORM\)\)' "$f" 2>/dev/null | while IFS=: read -r ln line; do
    list=$(echo "$line" | sed -E 's/.*\$\(filter[[:space:]]*//; s/,[[:space:]]*\$\(TARGET_BOARD_PLATFORM\).*//')
    # "ifeq (,$(filter ...))" is an INVERTED gate: the block runs when the SoC is NOT listed.
    inverted=no
    echo "$line" | grep -qE 'ifeq[[:space:]]*\([[:space:]]*,' && inverted=yes
    # A list that is itself a make variable ($(UM_PLATFORMS), $(B64_FAMILY)...) cannot be expanded
    # statically. Reporting those as excluded would be a guess; flag them for manual expansion.
    case "$list" in
      *'$('*) printf '%s\t%s\t%s\t%s\n' "UNK" "${f#$SRC/}" "$ln" "$list"; continue ;;
    esac
    listed=no
    for p in $list; do [ "$p" = "$PLAT" ] && listed=yes; done
    if [ "$inverted" = yes ]; then
      [ "$listed" = yes ] && verdict="OUT (inverted gate: block SKIPPED for $PLAT)" || verdict="IN  (inverted gate: block applies)"
    else
      [ "$listed" = yes ] && verdict="IN " || verdict="OUT"
    fi
    printf '%s\t%s\t%s\t%s\n' "$verdict" "${f#$SRC/}" "$ln" "$list"
  done
done | sort -r | awk -F'\t' '
  { v=$1; sub(/ +$/,"",v)
    tag = (v ~ /^OUT/ ? "OUT" : (v ~ /^UNK/ ? "?" : "IN"))
    printf "  [%-3s] %s:%s\n", tag, $2, $3
    printf "        gate list: %.100s\n", $4
    if (v ~ /^OUT/) out++; else if (v ~ /^UNK/) unk++; else in_++ }
  END { printf "\n  %d gates exclude this SoC, %d include it, %d use unexpanded make variables.\n", out+0, in_+0, unk+0 }'

cat <<'NOTE'

  Each [OUT] gate is a block this device no longer receives. Before porting, open each one and ask
  what it was contributing -- sepolicy dirs, soong namespaces, M4 type renames, kernel flags. That is
  your port's work list, available before the first build.

  Note the inverted form: `ifeq (,$(filter <list>,$(TARGET_BOARD_PLATFORM)))` runs its block when the
  SoC is NOT listed, so being absent there means the block DOES apply. BOARD_SEPOLICY_M4DEFS is
  gated this way -- newer SoCs get their types renamed to vendor_*, older ones keep the bare names,
  so importing a newer vendor policy into an older device trips AOSP neverallows.
NOTE
