#!/bin/bash
# fetch.sh -- pull the Linphone APK into vendor/lineage/prebuilts/linphone: the build F-Droid
# suggests, verified against Linphone's signing certificate (prebuilt/fetch-linphone.sh;
# FDROID_PINS="org.linphone=<versionCode>" pins one).
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no Linphone and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/linphone" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-linphone.sh" "$AOSP" || exit 1
