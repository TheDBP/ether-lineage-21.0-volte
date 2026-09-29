#!/bin/bash
# post-build.sh -- prove the Syncthing-Fork APK in the image is byte-identical to the fetched one (a
# rewrite breaks the v2 signature and PackageManager drops the app silently at boot scan), that any
# native libraries the fetcher unpacked were installed beside it (forge/prebuilt/lib-app-checks.sh),
# and that the core is in product/bin with the symlink the app execs it through. The lib check
# covers libsyncthingnative.so too: it follows the symlink, so it also proves the symlink resolves.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
DIR="$AOSP/vendor/lineage/prebuilts/syncthing-fork"
app_post_build syncthing-fork "$DIR" SyncthingFork || exit 1
OUT="$AOSP/out/target/product/${DEVICE_CODENAME:?DEVICE_CODENAME unset and device.conf not found}"
CORE="$(find "$OUT" -path '*product/bin/syncthing' -not -path '*/obj/*' 2>/dev/null | head -1)"
[ -n "$CORE" ] && cmp -s "$DIR/syncthing" "$CORE" || { echo "!! syncthing-fork: product/bin/syncthing missing or not the fetched core" >&2; exit 1; }
LINK="$(dirname "$CORE")/../app/SyncthingFork/lib/arm64/libsyncthingnative.so"
[ -L "$LINK" ] && cmp -s "$DIR/syncthing" "$LINK" || { echo "!! syncthing-fork: app/SyncthingFork/lib/arm64/libsyncthingnative.so is not a symlink to the core -- the app would exec a 0644 file, or nothing" >&2; exit 1; }
echo "   syncthing-fork: core in product/bin, symlinked from the app's lib dir"
