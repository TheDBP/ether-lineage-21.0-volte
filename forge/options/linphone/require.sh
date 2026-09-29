#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_LINPHONE=true: APK present (the module is guarded
# on it, so without it the build succeeds and quietly ships no SIP client), the module file naming
# it, and on 20.0 the build/make presigned-warn patch. Checks live in forge/prebuilt/lib-app-checks.sh.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
app_require linphone "$AOSP/vendor/lineage/prebuilts/linphone" Linphone
