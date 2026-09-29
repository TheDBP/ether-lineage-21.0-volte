#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_ROOT=true. Non-zero here stops the build.
#
# The point is to fail at minute 0 rather than at minute 300. Previously this check lived inline
# after the compile, so a build with no Magisk APK spent the whole compile before anyone found out
# -- and an earlier version of it fell out of an if/elif silently and shipped an UNROOTED image
# under a rooted tag.
set -o pipefail
_apks="$(ls -t "$FORGE_DIR"/prebuilt/Magisk-*.apk 2>/dev/null || true)"
if [ -z "$_apks" ] && [ -x "$FORGE_DIR/prebuilt/fetch-magisk.sh" ]; then
  echo "   root: no Magisk APK yet, fetching"
  bash "$FORGE_DIR/prebuilt/fetch-magisk.sh" || true
  _apks="$(ls -t "$FORGE_DIR"/prebuilt/Magisk-*.apk 2>/dev/null || true)"
fi
if [ -z "$_apks" ]; then
  echo "!! root: no Magisk APK at $FORGE_DIR/prebuilt/Magisk-*.apk, and fetching one failed." >&2
  echo "!! Refusing to build: a rooted tag on an unrooted image is worse than no image." >&2
  echo "!! Run forge/prebuilt/fetch-magisk.sh, or build without the root option." >&2
  exit 1
fi
echo "   root: Magisk APK present ($(basename "${_apks%%$'\n'*}"))"
