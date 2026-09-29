#!/usr/bin/env bash
# fetch-k9.sh — download K-9 Mail (Thunderbird for Android's codebase, Apache-2.0) for the k9
# option: the build F-Droid currently suggests, verified against the pinned signing certificate
# (see lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-k9.sh [AOSP_ROOT]
# FDROID_PINS="com.fsck.k9=39043" holds it to one build.
#
# The APK ships byte for byte, so what its author packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK -> lib/arm64-v8a/*.so unpacked to lib/arm64-v8a/
# beside it for the module to install; on Soong branches (the patch ships no Android.mk) the module
# file is written here, Android.bp, gitignored, with skip_preprocessed_apk_checks matching.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/k9}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="com.fsck.k9"
# Upstream's own key (K-9 is a reproducible build on F-Droid, not F-Droid-signed). Read on 2026-09-17.
SIGNER="c430665e3662253b2078dcda350c2c6ce44d915a3d8a147b63ced619bb9e8576"

fdroid_stage "$PKG" "$DEST/K9Mail.apk" "$SIGNER" K9Mail "$DEST" || { echo "!! k9: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-k9.sh
  fdroid_bp_module "$DEST/Android.bp" K9Mail K9Mail.apk "$PKG" "$FDROID_UNPACKED"
  echo "   k9: wrote $DEST/Android.bp"
fi
