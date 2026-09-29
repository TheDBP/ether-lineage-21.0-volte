#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_NEXTCLOUD_CORE=true: the four APKs present and
# named in the module file, the other four bundle apps absent (the guard is per APK, so a leftover
# from a whole-bundle build would ship), on 20.0 the build/make presigned-warn patch, and not
# combined with the nextcloud option (same patch, same directory: the second patch fails to apply
# and the fetches fight over the directory).
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
. "$FORGE_DIR/prebuilt/lib-app-checks.sh"
[ "${WITH_NEXTCLOUD:-false}" != true ] || { echo "!! nextcloud-core: nextcloud is also on; it already carries these four. Pick one." >&2; exit 1; }
_dir="$AOSP/vendor/lineage/prebuilts/nextcloud"
app_require nextcloud-core "$_dir" NextcloudFiles NextcloudTalk NextPush DAVx5 || exit 1
_extra=""
for _m in $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh"); do
  case "$_m" in NextcloudFiles|NextcloudTalk|NextPush|DAVx5) continue ;; esac
  [ ! -f "$_dir/$_m.apk" ] || _extra="$_extra $_m"
done
[ -z "$_extra" ] || { echo "!! nextcloud-core: also present in ${_dir#"$AOSP"/}:$_extra -- the guard would ship them. Re-run the option's fetch.sh." >&2; exit 1; }
