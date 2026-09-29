#!/bin/bash
# fetch.sh -- pull the Firefox (Fennec F-Droid) APK into vendor/lineage/prebuilts/firefox and
# unpack its native libraries beside it: the build F-Droid suggests, verified against Fennec's
# signing certificate (prebuilt/fetch-firefox.sh; FDROID_PINS="org.mozilla.fennec_fdroid=<versionCode>"
# pins one). ether 20.0 builds it from a device-tree module instead; post-patch.sh copies it there.
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no Firefox and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/firefox" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-firefox.sh" "$AOSP" || exit 1
