#!/bin/bash
# post-build.sh -- prove the Linphone APK in the image is byte-identical to the fetched one (a
# rewrite breaks the v2 signature and PackageManager drops the app silently at boot scan) and that
# any native libraries the fetcher unpacked were installed beside it. The checks are in
# forge/prebuilt/lib-app-checks.sh.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
app_post_build linphone "$AOSP/vendor/lineage/prebuilts/linphone" Linphone
