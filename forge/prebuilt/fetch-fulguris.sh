#!/usr/bin/env bash
# fetch-fulguris.sh — download Fulguris (Apache-2.0) for the fulguris option: the build F-Droid
# currently suggests, verified against the pinned signing certificate (see lib-fdroid.sh).
# Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-fulguris.sh [AOSP_ROOT]
# FDROID_PINS="net.slions.fulguris.full.fdroid=261" holds it to one build.
#
# A WebView browser: it carries no native code of its own, so nothing is unpacked beside it today.
# The wiring is still decided per fetch, like every app option -- if a release ever packs libraries
# compressed, they are unpacked and installed by jni/Android.mk, and post-build.sh fails if they
# are not.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/fulguris}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="net.slions.fulguris.full.fdroid"
# Fulguris's own key (signed by its maintainer, not F-Droid's key). Read on 2026-09-18.
SIGNER="66958f3366388c23ca1a3cbfd91545cca4abf3e79edaab4fe988213e392b07a1"

fdroid_stage "$PKG" "$DEST/Fulguris.apk" "$SIGNER" Fulguris "$DEST" || { echo "!! fulguris: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-fulguris.sh
  fdroid_bp_module "$DEST/Android.bp" Fulguris Fulguris.apk "$PKG" "$FDROID_UNPACKED" 'overrides: ["Jelly"],'
  echo "   fulguris: wrote $DEST/Android.bp"
fi
