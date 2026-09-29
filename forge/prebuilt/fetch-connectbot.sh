#!/usr/bin/env bash
# fetch-connectbot.sh — download ConnectBot (Apache-2.0) for the connectbot option: the build
# F-Droid currently suggests, verified against the pinned signing certificate (see lib-fdroid.sh).
# Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-connectbot.sh [AOSP_ROOT]
# FDROID_PINS="org.connectbot=11009000" holds it to one build.
#
# LineageOS already ships the OpenSSH binaries (ssh, scp, sftp, sshd) in config/common.mk, so with a
# terminal you can already reach a host. This adds the part a phone actually wants: saved hosts, key
# generation and an agent, and port forwarding, without a terminal in the way.
#
# Its native libraries are stored and aligned in the APK today, so nothing is unpacked beside it.
# That is decided per fetch like every app option.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/connectbot}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

PKG="org.connectbot"
# ConnectBot's own key (signed by its upstream, not F-Droid's key). Read 2026-09-19.
SIGNER="08789bad18ce8ec7b6637b5e70245a763ae5024f4d49ac85324047fb06b5da8a"

fdroid_stage "$PKG" "$DEST/ConnectBot.apk" "$SIGNER" ConnectBot "$DEST" || { echo "!! connectbot: fetch failed — see above" >&2; exit 1; }
if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-connectbot.sh
  fdroid_bp_module "$DEST/Android.bp" ConnectBot ConnectBot.apk "$PKG" "$FDROID_UNPACKED"
  echo "   connectbot: wrote $DEST/Android.bp"
fi
