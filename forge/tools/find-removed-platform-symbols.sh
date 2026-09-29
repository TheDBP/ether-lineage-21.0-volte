#!/usr/bin/env bash
# find-removed-platform-symbols.sh — C/C++ constants a device tree uses that the new branch deleted.
#
#   ./tools/find-removed-platform-symbols.sh <OLD_SRC> <NEW_SRC> <DEVICE_PATH>
#
# The C-header counterpart of find-orphaned-sepolicy-types.sh, and the same failure shape: a device
# tree that carries its own HALs compiles against platform headers, and when those headers drop
# symbols on a branch bump the device tree does not follow. On the lineage-19.1 ether port, AOSP 12
# deleted the vendor section of system/core/include/system/camera.h -- CAMERA_CMD_VENDOR_START and
# everything derived from it -- and the bundled QCamera2 HAL stopped compiling with
# "use of undeclared identifier 'CAMERA_CMD_LONGSHOT_ON'".
#
# Run it BEFORE the port. Each hit is either a symbol to restore in a device-local compat header, or
# a HAL that needs rewriting against the new API.
#
# Compares macro and enum-constant definitions under the platform include trees of both checkouts,
# then intersects "removed" with "referenced by this device".
set -uo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C

OLD_SRC="${1:?usage: find-removed-platform-symbols.sh <OLD_SRC> <NEW_SRC> <DEVICE_PATH>}"
NEW_SRC="${2:?need NEW_SRC}"
DEV="${3:?need DEVICE_PATH, e.g. device/nextbit/ether}"

[ -d "$NEW_SRC/$DEV" ] || { echo "!! no device tree at $NEW_SRC/$DEV" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Platform header trees worth comparing. Keep this list tight: scanning whole checkouts is slow and
# adds noise from code no device tree includes.
SUBDIRS="system/core system/media hardware/libhardware hardware/libhardware_legacy frameworks/native/include frameworks/av/include"

collect() { # $1=tree  $2=outfile
  local t="$1" o="$2" d
  : > "$o"
  for d in $SUBDIRS; do
    [ -d "$t/$d" ] || continue
    find "$t/$d" -name '*.h' -print0 2>/dev/null \
      | xargs -0 -r grep -hoE '^[[:space:]]*#define[[:space:]]+[A-Z][A-Z0-9_]{3,}|^[[:space:]]*[A-Z][A-Z0-9_]{3,}[[:space:]]*=' 2>/dev/null \
      | sed -E 's/^[[:space:]]*#define[[:space:]]+//; s/[[:space:]]*=$//; s/^[[:space:]]*//' >> "$o"
  done
  sort -u -o "$o" "$o"
}

echo "=== symbols removed between trees and still referenced by $DEV"
collect "$OLD_SRC" "$TMP/old.txt"
collect "$NEW_SRC" "$TMP/new.txt"
comm -23 "$TMP/old.txt" "$TMP/new.txt" > "$TMP/removed.txt"

# Identifiers this device's own C/C++ actually mentions.
find "$NEW_SRC/$DEV" \( -name '*.c' -o -name '*.cpp' -o -name '*.cc' -o -name '*.h' \) -print0 2>/dev/null \
  | xargs -0 -r grep -hoE '\b[A-Z][A-Z0-9_]{3,}\b' 2>/dev/null | sort -u > "$TMP/refs.txt"

comm -12 "$TMP/removed.txt" "$TMP/refs.txt" > "$TMP/hits.txt"

echo "    old-tree symbols: $(wc -l < "$TMP/old.txt")   new-tree: $(wc -l < "$TMP/new.txt")   removed: $(wc -l < "$TMP/removed.txt")"
echo "    device references: $(wc -l < "$TMP/refs.txt")"
echo
n=0
while read -r sym; do
  # Skip anything the device tree defines for itself -- those are not platform symbols.
  grep -rqE "^[[:space:]]*#define[[:space:]]+$sym\b" "$NEW_SRC/$DEV" 2>/dev/null && continue
  # A symbol absent from the SUBDIRS above may have MOVED rather than been removed (ALOGE_IF went
  # system/core -> system/logging; PROT_READ lives in bionic). Those still compile, so verify against
  # a wider sweep of the new tree before reporting. This runs only for the few surviving candidates.
  if grep -rqE "^[[:space:]]*(#define[[:space:]]+$sym\b|$sym[[:space:]]*=)" \
       "$NEW_SRC/system" "$NEW_SRC/hardware" "$NEW_SRC/frameworks" "$NEW_SRC/bionic" \
       --include='*.h' 2>/dev/null; then
    continue
  fi
  where=$(grep -rlE "\b$sym\b" "$NEW_SRC/$DEV" --include='*.c' --include='*.cpp' --include='*.cc' 2>/dev/null | head -2 \
          | sed "s#$NEW_SRC/$DEV/##" | tr '\n' ' ')
  [ -n "$where" ] || continue
  old_def=$(grep -rhE "^[[:space:]]*(#define[[:space:]]+)?$sym[[:space:]]*(=|[[:space:]])" "$OLD_SRC"/system/core/include "$OLD_SRC"/hardware/libhardware/include 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')
  printf "  %s\n" "$sym"
  printf "      used by : %s\n" "$where"
  [ -n "$old_def" ] && printf "      was     : %s\n" "$(echo "$old_def" | cut -c1-96)"
  n=$((n+1))
done < "$TMP/hits.txt"
[ "$n" -eq 0 ] && echo "  (none — no removed platform symbols are referenced by this device)"
echo
echo "  $n symbol(s). Restore them in a device-local compat header force-included from the module's"
echo "  Android.mk (LOCAL_CFLAGS += -include <header>), keeping the ORIGINAL values: prebuilt blobs and"
echo "  the framework already agree on those numbers, so renumbering silently breaks the ABI."
