#!/usr/bin/env bash
# fetch-linphone.sh — download Linphone (GPL-3.0) for the linphone option: the build F-Droid
# currently suggests, verified against the pinned signing certificate (see lib-fdroid.sh).
# Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-linphone.sh [AOSP_ROOT]
# FDROID_PINS="org.linphone=6000213" holds it to one build.
#
# A SIP client, not VoLTE: it does not register with the carrier's IMS, so it carries no mobile
# number of its own and cannot place emergency calls. On a device with no VoLTE it is the only
# voice path left over LTE data, which is why it is worth baking in -- Android dropped its own SIP
# stack in 12.
#
# Its native libraries are stored and aligned in the APK today, so nothing is unpacked beside it.
# That is decided per fetch like every app option; if a release ever packs them compressed they are
# unpacked and installed by jni/Android.mk, and post-build.sh fails if they are not.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/linphone}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="org.linphone"
# Belledonne Communications' own key (signed by the upstream, not F-Droid's key). Read 2026-09-19.
SIGNER="d3bc295122641bd49a01006d01e939c51e8505d26c93fdac585e6ed8f5df611c"

fdroid_stage "$PKG" "$DEST/Linphone.apk" "$SIGNER" Linphone "$DEST" || { echo "!! linphone: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-linphone.sh
  fdroid_bp_module "$DEST/Android.bp" Linphone Linphone.apk "$PKG" "$FDROID_UNPACKED"
  echo "   linphone: wrote $DEST/Android.bp"
fi
