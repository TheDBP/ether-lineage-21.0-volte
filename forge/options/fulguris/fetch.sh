#!/bin/bash
# fetch.sh -- pull the Fulguris APK into vendor/lineage/prebuilts/fulguris: the build F-Droid
# suggests, verified against Fulguris's signing certificate (prebuilt/fetch-fulguris.sh;
# FDROID_PINS="net.slions.fulguris.full.fdroid=<versionCode>" pins one).
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no Fulguris and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/fulguris" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-fulguris.sh" "$AOSP" || exit 1
