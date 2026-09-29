#!/bin/bash
# fetch.sh -- pull Files, Talk, NextPush and DAVx5 into vendor/lineage/prebuilts/nextcloud, the same
# place and patch as the nextcloud option; the fetcher takes the subset and removes the other four, so
# the per-APK guard in config/common.mk ships exactly these four. Latest F-Droid build of each,
# signer-pinned (see forge/prebuilt/lib-fdroid.sh); FDROID_PINS holds any of them to one versionCode.
#
# Runs at sync time. It has to: PRODUCT_PACKAGES resolves at product-config time, and each module is
# guarded on its APK existing, so a missing APK means a missing app and no error -- which is why
# require.sh checks before the build and post-build.sh checks the image.
set -o pipefail
AOSP="${1:-/aosp}"
# Refuse before touching the directory. require.sh checks the same thing, but it runs at build prep
# and this runs during the overlay, so by then the subset fetch has already deleted the four apps the
# nextcloud option put there -- the conflict was reported only after breaking the other option.
case " ${BUILD_OPTIONS:-} " in
  *" nextcloud "*)
    echo "!! nextcloud-core: nextcloud is also on; it already carries these four. Pick one." >&2
    echo "   Refusing before the fetch, which would remove the other four from the shared" >&2
    echo "   prebuilts/nextcloud directory." >&2
    exit 1 ;;
esac

FEATURE_DEST="$AOSP/vendor/lineage/prebuilts/nextcloud" \
NEXTCLOUD_MODULES="NextcloudFiles NextcloudTalk NextPush DAVx5" NEXTCLOUD_LABEL=nextcloud-core \
  bash "${FORGE_DIR:?FORGE_DIR unset}/prebuilt/fetch-nextcloud.sh" "$AOSP" || exit 1
