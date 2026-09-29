#!/bin/bash
# fetch.sh -- pull the Syncthing-Fork APK into vendor/lineage/prebuilts/syncthing-fork: the build
# F-Droid suggests, verified against Catfriend1's signing certificate
# (prebuilt/fetch-syncthing-fork.sh; FDROID_PINS="com.github.catfriend1.syncthingfork=<versionCode>"
# pins one). The fetcher also extracts the Syncthing core beside it for product/bin.
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no Syncthing and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/syncthing-fork" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-syncthing-fork.sh" "$AOSP" || exit 1
