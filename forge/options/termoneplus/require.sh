#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_TERMONEPLUS=true: APK present (the module is guarded on
# it, so without it the build succeeds and ships no terminal), module file naming it, and on
# 20.0 the build/make presigned-warn patch. The checks are in forge/prebuilt/lib-app-checks.sh.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
app_require termoneplus "$AOSP/vendor/lineage/prebuilts/termoneplus" TermOnePlus
