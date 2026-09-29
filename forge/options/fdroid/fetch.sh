#!/bin/bash
# fetch.sh -- pull the F-Droid client and Privileged Extension APKs into vendor/lineage/prebuilts/fdroid:
# the builds F-Droid suggests, verified against F-Droid's signing certificate
# (prebuilt/fetch-fdroid.sh; FDROID_PINS="org.fdroid.fdroid=<versionCode> org.fdroid.fdroid.privileged=<versionCode>"
# pins them). ether 20.0 builds them from device-tree modules instead; post-patch.sh copies them there.
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and each module is
# guarded on its APK existing, so a missing APK means no app store and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/fdroid" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-fdroid.sh" "$AOSP" || exit 1
