#!/bin/bash
# post-build.sh -- prove the shipped APK(s) are byte-identical to the fetched ones (a rewrite breaks
# the v2 signature and PackageManager drops the app silently at boot scan) and that any native
# libraries the fetcher unpacked were installed beside them. Checks live in
# forge/prebuilt/lib-app-checks.sh. Same branch-dependent location as require.sh.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
_dir="$AOSP/vendor/lineage/prebuilts/fdroid"
_dev="$AOSP/device/${DEVICE:-}/fdroid"
[ -f "$_dev/Android.mk" ] && _dir="$_dev"
app_post_build fdroid "$_dir" FDroid FDroidPrivilegedExtension
