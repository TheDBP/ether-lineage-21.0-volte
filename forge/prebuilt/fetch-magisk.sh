#!/bin/bash
# fetch-magisk.sh — download the pinned Magisk APK into this dir, verified by sha256.
# Magisk (GPLv3) is FETCHED, not vendored, so no third-party binary lives in git. Idempotent:
# re-runs are a no-op once the verified APK is present. Called automatically by bootstrap.sh /
# apply-overlay.sh; run it standalone too.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VER="v30.7"
SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
APK="$HERE/Magisk-$VER.apk"
URL="https://github.com/topjohnwu/Magisk/releases/download/$VER/Magisk-$VER.apk"

if [ -f "$APK" ] && echo "$SHA256  $APK" | sha256sum -c - >/dev/null 2>&1; then
  echo "Magisk $VER already present + verified"; exit 0
fi

echo "fetching Magisk $VER from GitHub releases..."
curl -fL --retry 3 -o "$APK.tmp" "$URL"
if ! echo "$SHA256  $APK.tmp" | sha256sum -c - >/dev/null 2>&1; then
  echo "!! sha256 mismatch — refusing to use this download"; rm -f "$APK.tmp"; exit 1
fi
mv -f "$APK.tmp" "$APK"
echo "Magisk $VER fetched + verified"
