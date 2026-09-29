#!/bin/bash
# nextcloud option, post-build hook -- prove every APK in the image is the one that was fetched.
#
# Any rewrite of a presigned APK (uncompressing libs or dex, re-aligning) invalidates its whole-file
# v2 signature; PackageManager then skips it silently at boot scan and the build reports success
# with the app absent. Comparing installed against fetched catches every cause. Same check as k9.
# For an app whose native libraries the fetcher unpacked beside the APK, each one must also be in
# the image as <app>/lib/arm64/<lib>.so, or the app dies at launch in UnsatisfiedLinkError.
set -uo pipefail

AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$AOSP/out/target/product/${DEVICE_CODENAME:?DEVICE_CODENAME unset and device.conf not found}"

rc=0
for mod in $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh"); do
  SRC="$AOSP/vendor/lineage/prebuilts/nextcloud/$mod.apk"
  APK="$(find "$OUT" -name "$mod.apk" -path '*app*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  [ -n "$APK" ] || { echo "!! nextcloud: no $mod.apk in the built image"; rc=1; continue; }
  [ -f "$SRC" ] || { echo "   nextcloud: $mod: no fetched copy to compare against, skipping"; continue; }
  if cmp -s "$SRC" "$APK"; then
    echo "   nextcloud: $mod shipped byte-identical to the fetched one -- signature intact"
    for lib in "$AOSP/vendor/lineage/prebuilts/nextcloud/$mod"/lib/arm64-v8a/*.so; do
      [ -f "$lib" ] || continue
      if cmp -s "$lib" "$(dirname "$APK")/lib/arm64/$(basename "$lib")"; then
        echo "   nextcloud: $mod: $(basename "$lib") installed beside it"
      else
        echo "!! nextcloud: $mod: $(basename "$lib") missing beside the APK -- it packs its libraries compressed and would not launch"
        rc=1
      fi
    done
  else
    echo "!! nextcloud: the build rewrote $mod.apk, so its signature no longer verifies."
    echo "!!   fetched: $(stat -c%s "$SRC") bytes   shipped: $(stat -c%s "$APK") bytes"
    echo "!! PackageManager will refuse it at boot scan and the app will simply be absent."
    rc=1
  fi
done
exit $rc
