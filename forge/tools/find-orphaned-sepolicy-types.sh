#!/usr/bin/env bash
# find-orphaned-sepolicy-types.sh — list SELinux types a device tree still references but that no
# longer exist, after an upstream branch bump deleted the policy that defined them.
#
#   ./tools/find-orphaned-sepolicy-types.sh <OLD_SRC> <NEW_SRC> <DEVICE_PATH>
#
#   OLD_SRC      an AOSP tree on a branch where the device BUILT (e.g. a lineage-18.1 checkout)
#   NEW_SRC      the tree that now fails to compile policy
#   DEVICE_PATH  device dir relative to the tree, e.g. device/nextbit/ether
#
# Why this exists: when a SoC ages out of CAF support, upstream deletes the qcom vendor policy that
# defined its types, but the device tree keeps referencing them. checkpolicy reports only the FIRST
# unknown type per run, so discovering them from build output costs one full build per type. This
# collects the whole set in one pass.
#
# It works by intersection: every type OLD_SRC defined, AND every identifier the device's own policy
# mentions, MINUS everything NEW_SRC still defines. What is left is the regression set.
#
# THREE traps this handles, each of which produced a wrong answer when done by hand:
#   * hyphens — SELinux type names may contain them (thermal-engine, mm-pp-daemon, mm-qcamerad). An
#     identifier pattern of [a-z][a-zA-Z0-9_]+ splits those into fragments, so the types are never
#     considered and the tool reports clean while the build still fails on them.
#   * sort collation — the intersection uses comm, which silently drops entries when its inputs were
#     sorted under different locales. Everything here runs under LC_ALL=C.
#   * macro declarations — AOSP declares many types through macros, e.g.
#     vendor_restricted_prop(vendor_mpctl_prop), not a literal "type ...;" line. Grepping only for
#     "^type X" reports such a type as missing and tempts you into declaring a DUPLICATE, which
#     fails the build differently. Macro forms are checked too.
#
# A common source of these on qcom devices: device/lineage/sepolicy/qcom/sepolicy.mk applies
# BOARD_SEPOLICY_M4DEFS renames (persist_block_device -> vendor_persist_block_device, ...) only for
# NEWER SoCs. Older ones keep the bare names, so the shared policy still references types whose
# legacy definitions are no longer wired up. Check that M4DEFS list when hits look like renames.
#
# Output is a candidate list, not a verdict. Confirm each hit against the failing build before
# declaring it: a macro argument can look like a type when it is not.
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C

OLD_SRC="${1:?usage: find-orphaned-sepolicy-types.sh <OLD_SRC> <NEW_SRC> <DEVICE_PATH>}"
NEW_SRC="${2:?need NEW_SRC}"
DEV="${3:?need DEVICE_PATH, e.g. device/nextbit/ether}"

SEPOL="$NEW_SRC/$DEV/sepolicy"
[ -d "$SEPOL" ] || { echo "!! no sepolicy dir at $SEPOL" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 1. every type the OLD tree defined (the pool that may have been deleted upstream)
grep -rhoE '^[[:space:]]*type[[:space:]]+[a-zA-Z0-9_-]+' "$OLD_SRC/device" 2>/dev/null \
  | awk '{print $2}' | sort -u > "$TMP/old.txt"

# 2. every identifier mentioned by the policy COMPILED FOR THIS DEVICE. That is the device's own
# sepolicy dir PLUS the shared qcom dirs device/lineage/sepolicy/qcom/sepolicy.mk adds -- scanning
# only the device dir misses orphans that the shared policy references on this device's behalf.
# On ether that gap hid five types (persist_block_device, display_vendor_data_file,
# sysfs_battery_supply, sysfs_usb_supply, hal_perf_default), each costing another build cycle.
REF_DIRS=("$SEPOL")
for d in dynamic vendor legacy-vendor; do
  [ -d "$NEW_SRC/device/lineage/sepolicy/qcom/$d" ] && REF_DIRS+=("$NEW_SRC/device/lineage/sepolicy/qcom/$d")
done
: > "$TMP/refs_raw.txt"
for d in "${REF_DIRS[@]}"; do
  cat "$d"/*.te >> "$TMP/refs_raw.txt" 2>/dev/null || true
done
grep -oE '[a-z][a-zA-Z0-9_-]{2,}' "$TMP/refs_raw.txt" 2>/dev/null | sort -u > "$TMP/refs_te.txt"

# Types are also referenced from the *_contexts files, not just .te rules. A label such as
#   /(odm|vendor/odm)/bin/keymaster  u:object_r:hal_keymaster_qti_exec:s0
# in a shared file_contexts that this device compiles will fail the build with
#   "type hal_keymaster_qti_exec is not defined"
# even though no .te ever names it. Scanning only .te files misses that entire class.
: > "$TMP/refs_ctx.txt"
for d in "${REF_DIRS[@]}"; do
  for c in file_contexts genfs_contexts property_contexts service_contexts hwservice_contexts vndservice_contexts seapp_contexts; do
    # NOTE: an if-block, not "[ -f x ] && grep ...". A trailing AND-list that evaluates false
    # returns 1, and under `set -e` that aborts the script with no output at all.
    if [ -f "$d/$c" ]; then
      grep -ohE 'u:object_r:[a-zA-Z0-9_-]+:' "$d/$c" 2>/dev/null \
        | sed 's/u:object_r://; s/://' >> "$TMP/refs_ctx.txt" || true
    fi
  done
done
cat "$TMP/refs_te.txt" "$TMP/refs_ctx.txt" 2>/dev/null | sort -u > "$TMP/refs.txt"

comm -12 "$TMP/old.txt" "$TMP/refs.txt" > "$TMP/cand.txt"

# 3. drop anything the NEW tree still defines, by literal declaration OR by macro.
#
# CRITICAL: check only the dirs COMPILED for this device, not everything present in the tree. A type
# can sit in device/qcom/sepolicy-legacy/legacy/vendor/ and still be undefined at build time, because
# SEPolicy.mk wires that subtree up only for the SoCs it lists. Scanning device/qcom wholesale
# reported pps_socket (and 15 others) as defined when the build had never seen them -- the tool said
# "clean" while checkpolicy was still failing, one type per run.
#
# Override with SEPOLICY_DIRS="dir1 dir2 ..." (paths relative to NEW_SRC) if your device wires up a
# different set; grep BOARD_SEPOLICY_DIRS / BOARD_VENDOR_SEPOLICY_DIRS in its BoardConfig to confirm.
DEFAULT_DIRS="system/sepolicy device/lineage/sepolicy device/qcom/sepolicy-legacy-um/generic device/qcom/sepolicy-legacy-um/qva $DEV/sepolicy"
DIRS=()
for d in ${SEPOLICY_DIRS:-$DEFAULT_DIRS}; do
  [ -e "$NEW_SRC/$d" ] && DIRS+=("$NEW_SRC/$d")
done
[ ${#DIRS[@]} -gt 0 ] || { echo "!! none of the policy dirs exist under $NEW_SRC" >&2; exit 1; }
echo "#   checking against compiled dirs: ${DIRS[*]#$NEW_SRC/}" >&2

echo "# orphaned type candidates for $DEV"
echo "#   old-tree types: $(wc -l < "$TMP/old.txt")   device refs: $(wc -l < "$TMP/refs.txt")   candidates: $(wc -l < "$TMP/cand.txt")"
n=0
while read -r t; do
  grep -rqE "^[[:space:]]*(type|attribute)[[:space:]]+$t[[:space:]]*[,;]" "${DIRS[@]}" 2>/dev/null && continue
  grep -rqE "[a-z_]+prop\($t\)|^[[:space:]]*attribute[[:space:]]+$t" "${DIRS[@]}" 2>/dev/null && continue
  echo "$t"; n=$((n+1))
done < "$TMP/cand.txt"
echo "#   $n undefined at $NEW_SRC" >&2


# ---------------------------------------------------------------------------------------------
# Macros. Porting whole policy files from an older tree drags in te_macros that may not exist any
# more -- device/qcom/sepolicy-legacy/common/te_macros is gone at 19.1, taking hal_server_domain_bypass()
# and qmux_socket() with it. checkpolicy reports these as a bare "syntax error" naming the macro,
# which does not look like a missing-macro problem at all, and again only one per run.
echo
echo "# macros used by $DEV that the new tree does not define"
# if-blocks, not "[ -f x ] && grep ...": an unmatched glob makes the AND-list return 1 and set -e
# kills the script mid-output. Recurs across scripts here.
AVAIL="$(
  for m in "$NEW_SRC"/system/sepolicy/public/te_macros "$NEW_SRC"/device/lineage/sepolicy/*/te_macros; do
    if [ -f "$m" ]; then
      grep -ohE "define\(\`[a-z_0-9]+'" "$m" 2>/dev/null | sed "s/define(\`//; s/'//" || true
    fi
  done | sort -u
)"
nm=0
for f in "$SEPOL"/*.te; do
  [ -f "$f" ] || continue
    # Strip comments, then match UNANCHORED: macro calls are frequently indented, e.g.
    #   userdebug_or_eng(`
    #     diag_use(mm-pp-daemon)
    # A '^'-anchored pattern silently misses those -- it reports a clean run while the build fails.
    for m in $(sed 's/#.*//' "$f" 2>/dev/null | grep -ohE '\b[a-z_][a-z_0-9]*\(' | tr -d '(' | sort -u); do
    if ! printf '%s\n' "$AVAIL" | grep -qx "$m"; then
      echo "  $m  (used in $(basename "$f"))"
      nm=$((nm+1))
    fi
  done
done
if [ "$nm" -eq 0 ]; then echo "  (none)"; fi
echo "#   $nm missing macro(s). Expand them inline from the old tree's te_macros, dropping only the"
echo "#   parts whose attributes are unavailable -- check each with 'attribute <name>' before keeping it."

# For each name printed, recover the original declaration and its context entry with:
#   grep -rn "type <name>" $OLD_SRC/device
#   grep -rn "u:object_r:<name>:" $OLD_SRC/device
# and copy BOTH — a type without its file_contexts/genfs_contexts/property_contexts entry parses
# but never labels anything, so the domain silently does nothing at runtime.
