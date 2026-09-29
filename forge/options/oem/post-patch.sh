#!/bin/bash
# post-patch.sh -- force the boot animation to be re-copied on every build.
#
# vendor/lineage/bootanimation's gen-bootanimation.zip genrule takes TARGET_BOOTANIMATION as a
# soong_config string and runs a bare `cp` on it; the file is not a declared input, so ninja never
# sees it change. A rescaled bootanimation.zip from the extractor then ships as the previous one,
# with the build reporting success. Dropping the genrule's outputs makes the copy run again --
# it costs one file copy.
set -u
AOSP="${1:-/aosp}"
_n=0
for _d in "$AOSP"/out/soong/.intermediates/vendor/lineage/bootanimation \
          "$AOSP"/out/target/product/*/obj/ETC/bootanimation.zip_intermediates; do
  [ -e "$_d" ] || continue
  rm -rf "$_d" && _n=$((_n + 1))
done
for _f in "$AOSP"/out/target/product/*/system/product/media/bootanimation.zip \
          "$AOSP"/out/target/product/*/product/media/bootanimation.zip; do
  [ -e "$_f" ] || continue
  rm -f "$_f" && _n=$((_n + 1))
done
[ "$_n" = 0 ] || echo "   oem: dropped $_n stale bootanimation output(s) so the genrule re-copies the asset"
exit 0
