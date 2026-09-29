#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_SYNCTHING_FORK=true: APK present (the module is
# guarded on it, so without it the build succeeds and quietly ships no Syncthing), the module file
# naming it, on 20.0 the build/make presigned-warn patch (forge/prebuilt/lib-app-checks.sh), and the
# extracted core the SyncthingFork_core module installs as product/bin/syncthing.
AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
. "${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/prebuilt/lib-app-checks.sh"
DIR="$AOSP/vendor/lineage/prebuilts/syncthing-fork"
app_require syncthing-fork "$DIR" SyncthingFork || exit 1
[ -s "$DIR/syncthing" ] || {
  echo "!! syncthing-fork: $DIR/syncthing missing -- the core the app execs. Re-run the option's fetch.sh" >&2
  exit 1
}
echo "   syncthing-fork: core present for product/bin/syncthing"
