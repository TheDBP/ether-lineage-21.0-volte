#!/bin/bash
# fetch.sh -- pull the Nextcloud bundle into vendor/lineage/prebuilts/nextcloud, where this option's
# patch builds it from. Latest F-Droid build of each app at fetch time, signer-pinned (see
# forge/prebuilt/lib-fdroid.sh); FDROID_PINS holds any of them to one versionCode.
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and each module is
# guarded on its APK existing, so a missing APK means a missing app and no error -- which is why
# require.sh checks before the build and post-build.sh checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/nextcloud" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-nextcloud.sh" "$AOSP" || exit 1
