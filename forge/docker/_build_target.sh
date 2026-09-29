#!/bin/bash
# _build_target.sh — rebuild one or more make targets inside the container with the SAME product
# environment as the last full build, so out/ does not reconfigure or installclean.
#   ./forge/docker/aosp.sh bash -lc 'JOBS=12 bash /repo/forge/docker/_build_target.sh bootimage'
#
# _build_rom.sh records its tag and every option switch in out/.turbo_config; this exports the
# same set (a different set re-runs product config and triggers installclean) and runs mka.
set -o pipefail
cd /aosp || exit 1
export USE_CCACHE=1 CCACHE_DIR=/ccache
DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
: "${LUNCH_TARGET:?device.conf missing or LUNCH_TARGET unset}"
FORGE_DIR="$DEVICE_REPO/forge"; export FORGE_DIR
source "$FORGE_DIR/lib/presets.sh"
if [ -z "${JOBS:-}" ]; then
  _cores="$(nproc)"; _ramgb="$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 8)"
  _ramjobs=$(( _ramgb / 2 )); [ "$_ramjobs" -lt 1 ] && _ramjobs=1
  JOBS=$(( _cores < _ramjobs ? _cores : _ramjobs ))
fi
[ -f out/.turbo_config ] || { echo "!! no out/.turbo_config: no previous build to match"; exit 1; }
for kv in $(cat out/.turbo_config); do
  case "$kv" in
    tag=*)  export TURBO_BUILD_ID="${kv#tag=}" ;;
    WITH_*) export "$kv" ;;
  esac
done
forge_export_option_env || exit 1
echo "=== options: $(tr ' ' '\n' < out/.turbo_config | grep '^WITH_' | tr '\n' ' ') ==="
source build/envsetup.sh
lunch "$LUNCH_TARGET" || exit 1
for k in $(grep -rl '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=' "device/${DEVICE%%/*}" 2>/dev/null | sed -n 1p); do
  ks="$(sed -n 's/^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=[[:space:]]*//p' "$k" | sed -n 1p)"
  [ -d "$ks/.git" ] && echo "=== kernel $ks HEAD: $(git -C "$ks" log --oneline -1) ==="
done
echo "=== mka -j$JOBS $* (tag=$TURBO_BUILD_ID) ==="
mka -j"$JOBS" "$@"; rc=$?
echo "=== $* exit: $rc ==="
exit $rc
