#!/bin/bash
# fetch.sh -- pull the ConnectBot APK into vendor/lineage/prebuilts/connectbot: the build F-Droid
# suggests, verified against ConnectBot's signing certificate (prebuilt/fetch-connectbot.sh;
# FDROID_PINS="org.connectbot=<versionCode>" pins one).
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no ConnectBot and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/connectbot" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-connectbot.sh" "$AOSP" || exit 1
