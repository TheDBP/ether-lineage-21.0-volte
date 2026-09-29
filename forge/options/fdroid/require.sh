#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_FDROID=true: APK(s) present (each module is guarded
# on its APK, so without one the build succeeds and quietly ships without it), module file naming
# them, and on 20.0 the build/make presigned-warn patch. Checks live in forge/prebuilt/lib-app-checks.sh.
#
# Where to look depends on the branch. With a vendor/lineage patch the module is in
# vendor/lineage/prebuilts/fdroid. Without one (ether 20.0) the module is a device-tree module the
# device's own patch series creates, and post-patch.sh has already copied the APK into it -- so
# check there, or this fails on a tree that is in fact correct.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
_dir="$AOSP/vendor/lineage/prebuilts/fdroid"
_dev="$AOSP/device/${DEVICE:-}/fdroid"
[ -f "$_dev/Android.mk" ] && _dir="$_dev"
app_require fdroid "$_dir" FDroid FDroidPrivilegedExtension
