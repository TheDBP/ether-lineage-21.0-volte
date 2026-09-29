#!/usr/bin/env bash
# fetch-fdroid.sh — download the F-Droid client and its Privileged Extension (GPL-3.0) for the
# fdroid option: the build F-Droid currently suggests of each, verified against F-Droid's signing
# certificate (see lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-fdroid.sh [AOSP_ROOT]
# FDROID_PINS="org.fdroid.fdroid=1023052 org.fdroid.fdroid.privileged=2070" holds them to one build.
#
# Each APK ships byte for byte, so what F-Droid packed decides how it is wired, per fetch: native
# libraries compressed or unaligned in the APK -> lib/arm64-v8a/*.so unpacked to <App>/lib/arm64-v8a/
# beside it for the module to install; on Soong branches (the patch ships no Android.mk) the module
# file is written here, Android.bp, gitignored, with skip_preprocessed_apk_checks matching (the
# Privileged Extension needs it whenever its dex is compressed, which F-Droid's builds are). The
# option's post-patch.sh copies APKs and libraries on to a device tree that carries its own F-Droid
# modules (ether 20.0).
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/fdroid}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

# F-Droid's release key, which signs both. Read on 2026-09-17.
SIGNER="43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab"

fail=0
fdroid_stage org.fdroid.fdroid "$DEST/FDroid.apk" "$SIGNER" FDroid "$DEST/FDroid" || fail=1
client_unpacked="$FDROID_UNPACKED"
fdroid_stage org.fdroid.fdroid.privileged "$DEST/FDroidPrivilegedExtension.apk" "$SIGNER" FDroidPrivilegedExtension "$DEST/FDroidPrivilegedExtension" || fail=1
priv_unpacked="$FDROID_UNPACKED"
[ "$fail" = 0 ] || { echo "!! fdroid: fetch failed — see above" >&2; exit 1; }

if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-fdroid.sh
  fdroid_bp_module "$DEST/Android.bp" FDroid FDroid.apk org.fdroid.fdroid "$client_unpacked"
  # priv-app: INSTALL_PACKAGES/DELETE_PACKAGES are granted through the allowlist the patch copies to
  # /product/etc/permissions.
  fdroid_bp_module "$DEST/Android.bp" FDroidPrivilegedExtension FDroidPrivilegedExtension.apk org.fdroid.fdroid.privileged "$priv_unpacked" 'privileged: true,'
  echo "   fdroid: wrote $DEST/Android.bp"
fi
