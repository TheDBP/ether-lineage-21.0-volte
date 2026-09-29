#!/usr/bin/env bash
# fetch-termoneplus.sh — download TermOne Plus (terminal emulator, GPL-3.0) for the termoneplus
# option: the build F-Droid currently suggests, verified against the pinned signing certificate (see
# lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree). The F-Droid APK is
# universal (all ABIs); only arm64-v8a is unpacked.
#   ./fetch-termoneplus.sh [AOSP_ROOT]
# FDROID_PINS="com.termoneplus=570" holds it to one build.
#
# The APK ships byte for byte, so what its author packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK (every release so far) -> lib/arm64-v8a/*.so unpacked
# to lib/arm64-v8a/ beside it for the module to install; on Soong branches (the patch ships no
# Android.mk) the module file is written here, Android.bp, gitignored, with
# skip_preprocessed_apk_checks matching.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/termoneplus}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="com.termoneplus"
# The author's key (a reproducible build on F-Droid, not F-Droid-signed). Read on 2026-09-17.
SIGNER="de7986a766d1c5cb948d46bf7addd9c448e6b1b27e52d9b7125e73f1c39f448b"

fdroid_stage "$PKG" "$DEST/TermOnePlus.apk" "$SIGNER" TermOnePlus "$DEST" || { echo "!! termoneplus: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-termoneplus.sh
  fdroid_bp_module "$DEST/Android.bp" TermOnePlus TermOnePlus.apk "$PKG" "$FDROID_UNPACKED"
  echo "   termoneplus: wrote $DEST/Android.bp"
fi
