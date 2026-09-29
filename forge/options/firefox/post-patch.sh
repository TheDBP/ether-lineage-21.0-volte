#!/bin/bash
# post-patch.sh -- runs AFTER the device's patch series has been applied.
#
# The device-tree module directory this copies into is created by a device patch, so this cannot
# live in fetch.sh: that runs first, the directory does not exist yet, and a guard on it silently
# skips. That is exactly how Firefox came to be missing from every image while the build reported
# success. Copying from vendor/lineage/prebuilts, where fetch.sh actually put the APK.
set -o pipefail
AOSP="${1:-/aosp}"
_dev="$AOSP/device/${DEVICE:-}/firefox"
[ -n "${DEVICE:-}" ] || { echo "!! Firefox: DEVICE unset; cannot place into the device tree" >&2; exit 1; }
[ -d "$_dev" ] || exit 0   # this device has no legacy module; nothing to do

if ! cp -f "$AOSP/vendor/lineage/prebuilts/firefox/Firefox.apk" "$_dev/Firefox.apk"; then
  echo "!! firefox: the device tree has the module but no APK reached it" >&2; exit 1
fi
# The unpacked native libraries travel with it; the module installs them beside the APK.
rm -rf "$_dev/lib"
[ -d "$AOSP/vendor/lineage/prebuilts/firefox/lib" ] && cp -r "$AOSP/vendor/lineage/prebuilts/firefox/lib" "$_dev/lib"
echo "   also placed into device/${DEVICE}/firefox/ (legacy device-tree module)"
