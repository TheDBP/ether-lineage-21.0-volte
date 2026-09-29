#!/usr/bin/env bash
# fetch-syncthing-fork.sh — download Syncthing-Fork (MPL-2.0) for the syncthing-fork option: the
# build F-Droid currently suggests, verified against the pinned signing certificate (see
# lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-syncthing-fork.sh [AOSP_ROOT]
# FDROID_PINS="com.github.catfriend1.syncthingfork=2010500" holds it to one build.
#
# Continuous file sync between your own devices, no server and no account: the Syncthing core as
# an Android service with the fork's run conditions (wifi/charging/SSID) and a folder picker.
#
# Two things beside the APK, both decided per fetch:
#   - lib/arm64-v8a/: the native libraries, unpacked when the release packs them compressed (it
#     does today) so the jni modules can install them beside the APK like every app option.
#   - syncthing: the Syncthing core, always. The app does not dlopen it: it execs
#     nativeLibraryDir/libsyncthingnative.so with ProcessBuilder, and fs_config makes everything
#     under product/app/ 0644, so a copy beside the APK could never run. The module installs this
#     one as product/bin/syncthing (0755 by fs_config) and symlinks it back where the app looks.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/syncthing-fork}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="com.github.catfriend1.syncthingfork"
# Catfriend1's own key: the F-Droid build is reproducible and ships the developer-signed APK, so
# this is also the key on the GitHub release. Read 2026-09-20.
SIGNER="d374b8de5057013143c7d1515a015598c2df403be8160cae01a58c227e6e86aa"

fdroid_stage "$PKG" "$DEST/SyncthingFork.apk" "$SIGNER" Syncthing-Fork "$DEST" || { echo "!! syncthing-fork: fetch failed — see above" >&2; exit 1; }
if ! unzip -p "$DEST/SyncthingFork.apk" lib/arm64-v8a/libsyncthingnative.so > "$DEST/syncthing.download" || [ ! -s "$DEST/syncthing.download" ]; then
  rm -f "$DEST/syncthing.download"
  echo "!! syncthing-fork: no lib/arm64-v8a/libsyncthingnative.so in the APK — the core moved; fix the fetcher" >&2; exit 1
fi
mv -f "$DEST/syncthing.download" "$DEST/syncthing"
echo "   syncthing-fork: core extracted to $DEST/syncthing ($(stat -c%s "$DEST/syncthing") bytes) for product/bin"
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-syncthing-fork.sh
  fdroid_bp_module "$DEST/Android.bp" SyncthingFork SyncthingFork.apk "$PKG" "$FDROID_UNPACKED"
  echo "   syncthing-fork: wrote $DEST/Android.bp"
fi
