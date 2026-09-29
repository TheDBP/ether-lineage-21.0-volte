#!/bin/bash
# fetch.sh -- pull the OpenVPN for Android APK into vendor/lineage/prebuilts/openvpn, where this
# option's patch builds it from: the build F-Droid suggests, verified against the pinned signing
# certificate (prebuilt/fetch-openvpn.sh; FDROID_PINS="de.blinkt.openvpn=<versionCode>" pins one).
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and the module is
# guarded on the APK existing, so a missing APK means no VPN client and no error -- which is why
# post-build.sh then checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/openvpn" \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-openvpn.sh" "$AOSP" || exit 1
