#!/usr/bin/env bash
# kernel-rebuild.sh — rebuild just the boot image (or any make target) after a kernel change, with
# the environment of the last full build. ~20 min instead of a bootstrap run.
#
#   ./forge/tools/kernel-rebuild.sh [--am <patch>...] [target ...]      default target: bootimage
#
# Run from the device repo. --am applies overlay patches to the LIVE kernel tree first
# (build_output/src/<TARGET_KERNEL_SOURCE>, identity from FORGE_GIT_NAME/FORGE_GIT_EMAIL or the
# device repo's git config) — that is how a kernel-gate patch gets onto hardware before the next
# bootstrap picks it up from overlay/patches. Refuses while another aosp-* container is running.
# Output: out/target/product/<codename>/boot.img; log build_output/logs/kernel.log (appended).
set -u
REPO="${FORGE_DEVICE_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -f "$REPO/device.conf" ] || { echo "!! not a device repo: $REPO" >&2; exit 1; }
source "$REPO/device.conf"; [ -f "$REPO/device.conf.local" ] && source "$REPO/device.conf.local"
SRC="${AOSP_SRC:-${BUILD_ROOT:-$REPO/build_output}/src}"
AM=()
while [ $# -gt 0 ]; do
  case "$1" in
    --am) AM+=("$(realpath "$2")"); shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || set -- bootimage
cont=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^aosp-' || true)
[ "$cont" -eq 0 ] || { echo "!! refusing: $cont aosp-* container(s) running" >&2; exit 1; }

if [ ${#AM[@]} -gt 0 ]; then
  bc="$(grep -rl '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=' "$SRC/device/${DEVICE%%/*}" 2>/dev/null | head -1)"
  ks="$(sed -n 's/^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=[[:space:]]*//p' "$bc" | head -1)"
  [ -d "$SRC/$ks/.git" ] || { echo "!! kernel tree not found ($ks)" >&2; exit 1; }
  name="${FORGE_GIT_NAME:-$(git -C "$REPO" config user.name)}"; email="${FORGE_GIT_EMAIL:-$(git -C "$REPO" config user.email)}"
  for p in "${AM[@]}"; do
    echo ">> git am $p -> $ks"
    git -C "$SRC/$ks" -c user.name="$name" -c user.email="$email" am "$p" || { git -C "$SRC/$ks" am --abort; exit 1; }
  done
fi
echo ">> targets: $* (log: ${BUILD_ROOT:-$REPO/build_output}/logs/kernel.log)"
LOG_TAG=kernel "$REPO/forge/docker/aosp.sh" bash -lc "JOBS=${JOBS:-} bash /repo/forge/docker/_build_target.sh $*"
