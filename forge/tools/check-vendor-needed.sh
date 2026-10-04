#!/usr/bin/env bash
# check-vendor-needed.sh — find vendor ELFs whose DT_NEEDED the vendor linker namespace cannot
# satisfy, from the built out/ tree, before flashing.
#
#   check-vendor-needed.sh <aosp-root> <product-out>      e.g. /aosp out/target/product/vs995
#   check-vendor-needed.sh --import-check ...             also print the symbols imported from each hit
#
# The [vendor] namespace searches /vendor/lib{,64}{,/hw,/egl} and /odm, and reaches system only for
# the LLNDK (system/etc/llndk.libraries.txt). Anything else a vendor binary names -- libandroid.so,
# libandroid_runtime.so, libjnigraphics.so, libnativehelper.so -- fails at exec or dlopen:
#   CANNOT LINK EXECUTABLE "/vendor/bin/x": library "libandroid.so" not found
# which on the vs995 was the camera provider ("camera provider init failed", restart every 5 s),
# mm-qcamera-daemon and fpc_early_loader, all from DT_NEEDED entries the OEM blobs carried for libs
# they import nothing from. Dead entries go in overlay/blob-fixups as `remove-needed` (see
# blob-fixups.sh); an entry the blob actually uses needs a shim or the lib in vendor instead.
# --import-check runs nm -D --undefined-only against the named lib's exported symbols so the two
# cases can be told apart here instead of on the phone.
#
# Walks vendor/{bin,lib,lib64} under <product-out>/system/vendor (vendor-in-system) or
# <product-out>/vendor, 32- and 64-bit separately. Needs the tree's patchelf (prebuilts/extract-tools)
# or one on PATH; nm from PATH for --import-check. Exit 1 when anything is unresolved.
set -uo pipefail
export LC_ALL=C
IMPORTS=0
[ "${1:-}" = "--import-check" ] && { IMPORTS=1; shift; }
AOSP="${1:-}"; OUT="${2:-}"
[ -d "$AOSP" ] && [ -d "$OUT" ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
case "$OUT" in /*) ;; *) OUT="$AOSP/$OUT" ;; esac

PE=""
for c in "$AOSP"/prebuilts/extract-tools/linux-x86/bin/patchelf-0_18 "$AOSP"/prebuilts/extract-tools/linux-x86/bin/patchelf "$(command -v patchelf || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { PE="$c"; break; }
done
[ -n "$PE" ] || { echo "!! no patchelf (prebuilts/extract-tools or PATH)" >&2; exit 2; }

VEND="$OUT/system/vendor"; [ -d "$OUT/vendor/lib" ] && VEND="$OUT/vendor"
LLNDK=$(ls "$OUT"/system/etc/llndk.libraries*.txt 2>/dev/null | sed -n 1p)
[ -n "$LLNDK" ] || { echo "!! no system/etc/llndk.libraries*.txt under $OUT (image not built yet?)" >&2; exit 2; }
echo ">> vendor: $VEND"; echo ">> llndk:  $LLNDK ($(tr ':' '\n' < "$LLNDK" | grep -c .) libs)"

TMP="${TMPDIR:-$(cd "$(dirname "$0")/../.." && pwd)/build_output/tmp}"; mkdir -p "$TMP"
avail32="$TMP/vendor-avail32.$$"; avail64="$TMP/vendor-avail64.$$"
trap 'rm -f "$avail32" "$avail64"' EXIT
# What each bitness can resolve: every .so under the vendor search dirs (hw/ and egl/ are search
# paths; deeper subdirs are not) plus the LLNDK by name.
{ find "$VEND/lib" "$VEND/lib/hw" "$VEND/lib/egl" "$OUT/system/vendor/odm/lib" -maxdepth 1 -name '*.so' -printf '%f\n' 2>/dev/null; tr ':' '\n' < "$LLNDK"; } | sort -u > "$avail32"
{ find "$VEND/lib64" "$VEND/lib64/hw" "$VEND/lib64/egl" "$OUT/system/vendor/odm/lib64" -maxdepth 1 -name '*.so' -printf '%f\n' 2>/dev/null; tr ':' '\n' < "$LLNDK"; } | sort -u > "$avail64"

bad=0; n=0
while IFS= read -r f; do
  [ "$(head -c4 "$f" | tr -d '\0')" = $'\x7fELF' ] || continue
  n=$((n+1))
  cls=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' '); avail="$avail32"; [ "$cls" = 2 ] && avail="$avail64"
  for lib in $("$PE" --print-needed "$f" 2>/dev/null); do
    grep -qxF "$lib" "$avail" && continue
    rel="${f#$OUT/}"; rel="${rel#system/}"
    echo "   /$rel: $lib"; bad=$((bad+1))
    if [ "$IMPORTS" = 1 ]; then
      # The library is not in vendor, so look for a copy anywhere in the product out to diff against.
      src=$(find "$OUT/system" -name "$lib" -path "*lib$([ "$cls" = 2 ] && echo 64)/*" 2>/dev/null | sed -n 1p)
      if [ -n "$src" ] && command -v nm >/dev/null; then
        used=$(comm -12 <(nm -D --undefined-only "$f" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u) \
                        <(nm -D --defined-only "$src" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u) | tr '\n' ' ')
        [ -n "$used" ] && echo "      imports: $used" || echo "      imports nothing from it (dead DT_NEEDED -> remove-needed)"
      else
        echo "      (no $lib in $OUT to compare symbols against)"
      fi
    fi
  done
done < <(find "$VEND/bin" "$VEND/lib" "$VEND/lib64" -type f 2>/dev/null | sort)
echo ">> check-vendor-needed: $n ELFs, $bad unresolved DT_NEEDED"
[ "$bad" = 0 ]
