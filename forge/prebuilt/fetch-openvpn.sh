#!/usr/bin/env bash
# fetch-openvpn.sh — download OpenVPN for Android (de.blinkt.openvpn, GPL-2.0) for the openvpn
# option: the build F-Droid currently suggests, verified against the pinned signing certificate
# (see lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-openvpn.sh [AOSP_ROOT]
# FDROID_PINS="de.blinkt.openvpn=220" holds it to one build.
#
# NOTE ON TRUST, because this one differs from the rest. Every other app the forge fetches is
# signed by its own author and pinned to that key. This APK is signed by F-Droid itself
# (CN=FDroid, O=fdroid.org) -- upstream does not publish a reproducible build there -- so the pin
# proves "F-Droid built and signed this package", not "the OpenVPN author signed it". That is
# exactly the trust you get installing it from F-Droid by hand, and no less, but it is a different
# root from the others and should not be mistaken for an upstream signature.
#
# The APK ships byte for byte, so what its author packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK -> lib/arm64-v8a/*.so unpacked to lib/arm64-v8a/
# beside it for the module to install; on Soong branches (the patch ships no Android.mk) the module
# file is written here, Android.bp, gitignored, with skip_preprocessed_apk_checks matching.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/openvpn}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="de.blinkt.openvpn"
# F-Droid's own repo signing key: this app is built and signed by F-Droid. Read on 2026-09-22
# from de.blinkt.openvpn_220.apk (apksigner --print-certs).
SIGNER="4cd330fe6593e2e64b1e1fa383f0c6d73892184fc1cd1a909e71d558d862e212"

fdroid_stage "$PKG" "$DEST/OpenVPN.apk" "$SIGNER" OpenVPN "$DEST" || { echo "!! openvpn: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-openvpn.sh
  fdroid_bp_module "$DEST/Android.bp" OpenVPN OpenVPN.apk "$PKG" "$FDROID_UNPACKED"
  echo "   openvpn: wrote $DEST/Android.bp"
fi
