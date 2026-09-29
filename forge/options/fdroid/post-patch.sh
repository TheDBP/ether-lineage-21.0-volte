#!/bin/bash
# post-patch.sh -- runs AFTER the device's patch series has been applied.
#
# The device-tree module directory this copies into is created by a device patch, so this cannot
# live in fetch.sh: that runs first, the directory does not exist yet, and a guard on it silently
# skips. That is exactly how F-Droid came to be missing from every image while the build reported
# success. Copying from vendor/lineage/prebuilts, where fetch.sh actually put the APKs (flat:
# FDroid.apk, FDroidPrivilegedExtension.apk, libraries under <Mod>/lib/); the device-tree modules
# read <Mod>/<Mod>.apk and <Mod>/lib/.
set -o pipefail
AOSP="${1:-/aosp}"
_dev="$AOSP/device/${DEVICE:-}/fdroid"
[ -n "${DEVICE:-}" ] || { echo "!! F-Droid: DEVICE unset; cannot place into the device tree" >&2; exit 1; }
[ -d "$_dev" ] || exit 0   # this device has no legacy module; nothing to do

_src="$AOSP/vendor/lineage/prebuilts/fdroid"
_bad=0
for _mod in FDroid FDroidPrivilegedExtension; do
  mkdir -p "$_dev/$_mod"
  if ! cp -f "$_src/$_mod.apk" "$_dev/$_mod/$_mod.apk"; then
    echo "!! fdroid: could not copy $_src/$_mod.apk" >&2; _bad=1
  fi
  # The unpacked native libraries travel with it; the module installs them beside the APK.
  rm -rf "$_dev/$_mod/lib"
  [ -d "$_src/$_mod/lib" ] && cp -r "$_src/$_mod/lib" "$_dev/$_mod/lib"
done
[ "$_bad" = 0 ] || { echo "!! fdroid: the device tree has the module but no APK reached it" >&2; exit 1; }
echo "   also placed into device/${DEVICE}/fdroid/ (legacy device-tree module)"
