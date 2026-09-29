#!/usr/bin/env bash
# fetch-kdeconnect.sh — download KDE Connect (GPL-2.0+) for the kdeconnect option: the build F-Droid
# currently suggests, verified against the pinned signing certificate (see lib-fdroid.sh). Runs
# in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-kdeconnect.sh [AOSP_ROOT]
# FDROID_PINS="org.kde.kdeconnect_tp=13515" holds it to one build.
#
# The APK ships byte for byte, so what its author packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK -> lib/arm64-v8a/*.so unpacked to lib/arm64-v8a/
# beside it for the module to install; on Soong branches (the patch ships no Android.mk) the module
# file is written here, Android.bp, gitignored, with skip_preprocessed_apk_checks matching.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/kdeconnect}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="org.kde.kdeconnect_tp"
# KDE's own key (a reproducible build on F-Droid, not F-Droid-signed). Read on 2026-09-17.
SIGNER="79b50031486746dffbc746f48fb0eb62fc7bb0ae7b976e7d6507b2c078840d92"

fdroid_stage "$PKG" "$DEST/KDEConnect.apk" "$SIGNER" KDEConnect "$DEST" || { echo "!! kdeconnect: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-kdeconnect.sh
  fdroid_bp_module "$DEST/Android.bp" KDEConnect KDEConnect.apk "$PKG" "$FDROID_UNPACKED"
  echo "   kdeconnect: wrote $DEST/Android.bp"
fi
