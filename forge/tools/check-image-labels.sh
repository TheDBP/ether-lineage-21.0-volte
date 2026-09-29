#!/usr/bin/env bash
# check-image-labels.sh — find paths in the image that no file_contexts entry labels.
#
#   ./tools/check-image-labels.sh <SRC> <CODENAME> [DEVICE_PATH] [REFERENCE_OUT]
#
#   REFERENCE_OUT   out/target/product/<codename> of a device that BUILDS. Paths unlabeled there too
#                   are filtered out as benign -- see the note on false positives below.
#
# Run after a build reaches the staging stage but BEFORE you wait on packaging. e2fsdroid refuses to
# build system.img unless every path present in it has a label:
#
#   set_selinux_xattr: No such file or directory searching for label "/firmware"
#   e2fsdroid: No such file or directory while configuring the file system
#
# It reports ONE path per run, and it fails at ~99% of the build, so discovering these serially costs
# a full packaging cycle each. On the ether lineage-19.1 port that was /firmware and then /persist --
# both mount points whose labels vanished with the qcom legacy policy when the SoC aged out.
#
# Checks the ROOT-LEVEL entries of the staging tree, which is where mount points live and where this
# failure actually comes from. Matching is approximate: file_contexts entries are regexes, and this
# only asks whether any entry begins with the path.
#
# FALSE POSITIVES ARE EXPECTED. Not every directory under out/.../root ends up inside system.img --
# /odm_dlkm and /vendor_dlkm are unlabeled on a bonito tree that builds perfectly well. Only paths
# the image actually contains matter, and which those are depends on the partition scheme. Pass a
# REFERENCE_OUT from a device that builds and anything unlabeled there too is filtered out, which
# turns the guesswork into a diff. Without it, treat the output as candidates and confirm against the
# build error before adding labels -- an unnecessary label can fail a different check
# ("must be associated with the system_file_type attribute").
set -uo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C

SRC="${1:?usage: check-image-labels.sh <SRC> <CODENAME> [DEVICE_PATH]}"
CODE="${2:?need the device codename, e.g. ether}"
DEV="${3:-}"
REF_OUT="${4:-}"

OUT="$SRC/out/target/product/$CODE"
[ -d "$OUT" ] || { echo "!! no build output at $OUT (build far enough to stage the image first)" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Every file_contexts the build will concatenate: the generated plat one, the device's own, and the
# shared qcom dirs. A label present anywhere in that set counts.
: > "$TMP/ctx.txt"
for f in "$OUT/system/etc/selinux/plat_file_contexts" \
         "$OUT/vendor/etc/selinux/vendor_file_contexts" \
         "$OUT/system/vendor/etc/selinux/vendor_file_contexts"; do
  [ -f "$f" ] && cat "$f" >> "$TMP/ctx.txt"
done
[ -n "$DEV" ] && [ -f "$SRC/$DEV/sepolicy/file_contexts" ] && cat "$SRC/$DEV/sepolicy/file_contexts" >> "$TMP/ctx.txt"
for d in device/lineage/sepolicy device/qcom; do
  [ -d "$SRC/$d" ] || continue
  find "$SRC/$d" -name 'file_contexts' -exec cat {} \; >> "$TMP/ctx.txt" 2>/dev/null
done
grep -vE '^[[:space:]]*(#|$)' "$TMP/ctx.txt" | sort -u > "$TMP/ctx_clean.txt"
echo "=== label coverage for $CODE  ($(wc -l < "$TMP/ctx_clean.txt") context entries)"

ROOT="$OUT/root"; [ -d "$ROOT" ] || ROOT="$OUT/system"
n=0
for p in "$ROOT"/*/; do
  [ -d "$p" ] || continue
  m="$(basename "$p")"
  if ! grep -qE "^/$m([( \\\\/]|\$)" "$TMP/ctx_clean.txt"; then
    # benign if a known-good tree leaves the same path unlabeled
    if [ -n "$REF_OUT" ] && [ -d "$REF_OUT/root/$m" ]; then
      : > "$TMP/refctx.txt"
      for rf in "$REF_OUT/system/etc/selinux/plat_file_contexts" "$REF_OUT/system/vendor/etc/selinux/vendor_file_contexts"; do
        [ -f "$rf" ] && cat "$rf" >> "$TMP/refctx.txt"
      done
      if ! grep -qE "^/$m([( \\\\/]|\$)" "$TMP/refctx.txt" 2>/dev/null; then
        printf "  (benign)   /%-16s unlabeled in the reference build too\n" "$m"
        continue
      fi
    fi
    cnt=$(find "$p" -mindepth 1 2>/dev/null | wc -l)
    printf "  UNLABELED  /%-16s (%s entries in the image)\n" "$m" "$cnt"
    n=$((n+1))
  fi
done
echo
if [ "$n" -eq 0 ]; then
  echo "  every root-level path has a label."
else
  echo "  $n unlabeled path(s). Each will fail add_img_to_target_files at ~99% of the build, one per run."
  echo "  Recover the label AND its type from a tree where the device built:"
  echo "    grep -rhE '^/<path>' <OLD_SRC>/device/qcom/*/file_contexts"
  echo "    grep -rhE '^[[:space:]]*type <the_type>[[:space:]]*[,;]' <OLD_SRC>/device/qcom/"
  echo "  A mount point that is EMPTY in the image needs only the top-level catch-all; do not declare"
  echo "  the per-subdirectory types unless a runtime denial actually calls for them."
fi
exit "$n"
