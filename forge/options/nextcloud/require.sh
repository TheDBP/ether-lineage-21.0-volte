#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_NEXTCLOUD=true.
#
# 1. Every APK in the bundle must be in the tree. Each module is guarded on its APK, so without one
#    the build succeeds and ships the bundle minus that app.
# 2. The module file must be there and name every app: Android.mk from the 20.0 patch, or the
#    Android.bp fetch-nextcloud.sh writes on Soong branches (per fetch, because
#    skip_preprocessed_apk_checks has to match each APK). A stale or missing one is a lunch-time
#    error at best and a silently absent app at worst.
# 3. On 20.0 the modules ship the APKs verbatim through BUILD_PREBUILT's do_not_alter_apk path, and
#    stock build/make fails that path when an APK carries compressed dex -- most of these do. The
#    device tree has to carry the "warn instead of fail" patch to build/make/core/definitions.mk
#    (ether-20.0 does). Without it the failure is a hard build error at minute ~200, so check now.
set -o pipefail
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
FORGE_DIR="${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

missing=""
for mod in $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh"); do
  [ -f "$AOSP/vendor/lineage/prebuilts/nextcloud/$mod.apk" ] || missing="$missing $mod"
done
[ -z "$missing" ] || {
  echo "!! nextcloud: missing in vendor/lineage/prebuilts/nextcloud:$missing" >&2
  echo "!!     each module is guarded on its APK, so the build would ship the bundle without them." >&2
  echo "!!     Run the option's fetch.sh (bootstrap does)." >&2
  exit 1
}
DEST="$AOSP/vendor/lineage/prebuilts/nextcloud"
MODFILE="$DEST/Android.mk"; [ -f "$MODFILE" ] || MODFILE="$DEST/Android.bp"
[ -f "$MODFILE" ] || { echo "!! nextcloud: no module file in $DEST (Android.mk from the patch, or Android.bp from the fetch)" >&2; exit 1; }
for mod in $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh"); do
  grep -q "$mod" "$MODFILE" || { echo "!! nextcloud: $MODFILE does not name $mod -- stale; re-run the option's fetch.sh" >&2; exit 1; }
done
case "${BRANCH:-}" in
  lineage-20.0)
    grep -q 'presigned, shipped as-is' "$AOSP/build/make/core/definitions.mk" 2>/dev/null || {
      echo "!! nextcloud: on $BRANCH the verbatim-copy path needs the build/make patch that turns" >&2
      echo "!!     check-jni-dex-compression into a warning (these APKs ship compressed dex). Not applied." >&2
      exit 1
    } ;;
esac
echo "   nextcloud: all $(NEXTCLOUD_LIST_ONLY=1 bash "$FORGE_DIR/prebuilt/fetch-nextcloud.sh" | wc -l) APKs present, modules in $(basename "$MODFILE")"
