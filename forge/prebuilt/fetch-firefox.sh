#!/usr/bin/env bash
# fetch-firefox.sh — download Firefox (Fennec F-Droid, MPL) for the firefox option: the build
# F-Droid currently suggests, verified against the pinned signing certificate (see lib-fdroid.sh).
# Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-firefox.sh [AOSP_ROOT]
# FDROID_PINS="org.mozilla.fennec_fdroid=1550020" holds it to one build.
#
# F-Droid publishes Fennec per ABI under one package (three versionCodes per release); the suggested
# build, the highest code, is the arm64 one. If that ever changes, verification fails on "not an
# arm64 build" and the fetch stops rather than shipping the wrong ABI.
#
# The APK ships byte for byte, so what Mozilla packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK (every release so far: extractNativeLibs=true) ->
# lib/arm64-v8a/*.so unpacked to lib/arm64-v8a/ beside it for the module to install; on Soong
# branches (the patch ships no Android.mk) the module file is written here, Android.bp, gitignored,
# with skip_preprocessed_apk_checks matching. The option's post-patch.sh copies APK and libraries
# on to a device tree that carries its own Firefox module (ether 20.0).
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/firefox}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="org.mozilla.fennec_fdroid"
# Fennec F-Droid's own key (F-Droid's build of Firefox, signed by its maintainer, not F-Droid's
# key). Read on 2026-09-17.
SIGNER="06665358efd8ba05be236a47a12cb0958d7d75dd939d77c2b31f5398537ebdc5"

fdroid_stage "$PKG" "$DEST/Firefox.apk" "$SIGNER" Firefox "$DEST" || { echo "!! firefox: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-firefox.sh
  fdroid_bp_module "$DEST/Android.bp" Firefox Firefox.apk "$PKG" "$FDROID_UNPACKED" 'overrides: ["Jelly"],'
  echo "   firefox: wrote $DEST/Android.bp"
fi
