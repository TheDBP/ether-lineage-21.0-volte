#!/bin/bash
# post-build.sh -- prove Files, Talk, NextPush and DAVx5 in the image are byte-identical to the fetched
# ones (a rewrite breaks the v2 signature and PackageManager drops the app silently at boot scan),
# that any native libraries the fetcher unpacked were installed beside them, and that none of the
# other four bundle apps got in.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$FORGE_DIR/prebuilt/lib-app-checks.sh"
app_post_build nextcloud-core "$AOSP/vendor/lineage/prebuilts/nextcloud" NextcloudFiles NextcloudTalk NextPush DAVx5 || exit 1
_out="$AOSP/out/target/product/${DEVICE_CODENAME:?DEVICE_CODENAME unset and device.conf not found}"
for _m in $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh"); do
  case "$_m" in NextcloudFiles|NextcloudTalk|NextPush|DAVx5) continue ;; esac
  _hit="$(find "$_out" -name "$_m.apk" -path '*app*' -not -path '*/obj/*' 2>/dev/null | head -1)"
  [ -z "$_hit" ] || { echo "!! nextcloud-core: $_m.apk is in the image; only Files, Talk, NextPush and DAVx5 belong here" >&2; exit 1; }
done
echo "   nextcloud-core: none of the other bundle apps in the image"
