#!/usr/bin/env bash
# aosp.sh — build/enter the per-device AOSP/LineageOS build container (robin-forge).
# Portable: all paths derive from the device-repo location; per-device values come from device.conf.
#
#   ./forge/docker/aosp.sh                     # interactive build shell
#   ./forge/docker/aosp.sh <cmd...>            # run one command; output tee'd to BUILD_ROOT/logs/<LOG_TAG>.log
#   LOG_TAG=sync ./forge/docker/aosp.sh <cmd>  # label the phase log (bootstrap.sh sets this per phase)
#   BUILD_ROOT=/path CPUS=12 ./forge/docker/aosp.sh ...
#
# The container is named 'aosp-<DEVICE_SLUG>' by default, or $CONTAINER — bootstrap gives concurrent
# phases (prefetch/sync, the two extractors) distinct names so they don't collide. Command runs are
# NOT --rm'd, so the finished container (and its logs) stay in Portainer; a persistent greppable copy
# is also written under BUILD_ROOT/logs/.
#
# Layout (device repo root = forge/.. ; all build state under BUILD_ROOT, gitignored):
#   <build_root>/src      -> /aosp     source tree (~100GB)
#   <build_root>/ccache   -> /ccache   persistent ccache
#   <device repo root>    -> /repo      forge/ (scripts) + overlay/ (patches, manifests) + device.conf
set -euo pipefail

# Normally the engine lives at <device-repo>/forge/, so the repo root is two levels up. In-place
# layout (a device under a bare forge clone's devices/) has no forge/ of its own, so bootstrap.sh
# passes the path explicitly.
DEVICE_REPO="${FORGE_DEVICE_REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
[ -f "$DEVICE_REPO/device.conf.local" ] && source "$DEVICE_REPO/device.conf.local"   # personal: KEYS_DIR etc.
: "${DEVICE_SLUG:?device.conf missing or DEVICE_SLUG unset}"
: "${UBUNTU_VER:=20.04}"

BUILD_ROOT="${BUILD_ROOT:-$DEVICE_REPO/build_output}"   # holds src/ + ccache/ + logs/ (gitignored)
SRC="${AOSP_SRC:-$BUILD_ROOT/src}"
CCACHE="${CCACHE_HOST:-$BUILD_ROOT/ccache}"
LOGDIR="$BUILD_ROOT/logs"
IMAGE="${IMAGE:-aosp-${DEVICE_SLUG}:${UBUNTU_VER}}"
CPUS="${CPUS:-$(nproc)}"                                # dedicated machine: use all cores

mkdir -p "$SRC" "$CCACHE" "$LOGDIR"

# Container name — parameterized so phases that run CONCURRENTLY each get their own container.
CONTAINER="${CONTAINER:-aosp-${DEVICE_SLUG}}"

# Optional mounts: stock ROM dir (-> /stock, ro), GApps zip dir (-> /gapps, ro), download-staging (-> /dl).
STOCK_MNT=()
[ -n "${STOCK_DIR:-}" ] && [ -d "${STOCK_DIR:-}" ] && STOCK_MNT=(-v "$STOCK_DIR":/stock:ro)
GAPPS_MNT=()
[ -n "${GAPPS_DIR:-}" ] && [ -d "${GAPPS_DIR:-}" ] && GAPPS_MNT=(-v "$GAPPS_DIR":/gapps:ro)
DL_MNT=()
[ -n "${DL_DIR:-}" ] && { mkdir -p "$DL_DIR"; DL_MNT=(-v "$DL_DIR":/dl); }
# Shared git object store (repo init --reference). Identity mount — SAME absolute path inside the
# container as on the host, because git records the alternates path ABSOLUTELY; a container-only
# path (/mirror) would leave the tree unusable from the host.
MIRROR_MNT=()
[ -n "${MIRROR_DIR:-}" ] && [ -d "${MIRROR_DIR:-}" ] && MIRROR_MNT=(-v "$MIRROR_DIR":"$MIRROR_DIR")

# Signing keys (KEYS_DIR, from device.conf.local; made by tools/make-keys.sh). Mounted read-only at
# the path vendor/lineage/config/common.mk -includes keys.mk from, so the tree never holds a copy
# of them. Unset -> AOSP test keys, ro.build.tags=test-keys, and release.sh refuses the result.
# The mount point is created here as the user; left to the daemon it would be root-owned.
KEYS_MNT=()
if [ -n "${KEYS_DIR:-}" ]; then
  [ -f "$KEYS_DIR/keys.mk" ] || { echo "!! KEYS_DIR=$KEYS_DIR has no keys.mk -- run forge/tools/make-keys.sh" >&2; exit 1; }
  mkdir -p "$SRC/vendor/lineage-priv/keys"
  KEYS_MNT=(-v "$KEYS_DIR":/aosp/vendor/lineage-priv/keys:ro)
fi

# Clear only OUR OWN leftover container (by this name) — never another concurrent phase's.
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# In-place layout: the device dir has no forge/ of its own, so layer the engine over /repo/forge with
# a second bind mount. Everything inside the container keeps resolving /repo/forge/... unchanged.
FORGE_MNT=()
if [ ! -d "$DEVICE_REPO/forge" ]; then
  _forge_root="$(cd "$(dirname "$0")/.." && pwd)"
  FORGE_MNT=(-v "$_forge_root":/repo/forge)
fi

# SOONG_MEM_LIMIT caps soong_build's Go heap (GOMEMLIMIT). Analysis is ONE process whose peak is
# set by the size of the build graph, not by JOBS -- on a 24.0 tree the live graph is ~30 GB and
# Go's default GC lets the heap reach twice that, which is a 32 GB machine plus all of its swap.
# The soft limit makes the GC work harder instead of growing the heap; above the limit Go caps GC
# at half the CPU, so it degrades rather than spirals. Leave unset to let it grow.
# soong_ui runs soong_build under `env -i`: this variable only arrives if
# patches/<branch>/build/soong carries the forwarding patch (apply-overlay step 0).
GOMEM_ENV=()
[ -n "${SOONG_MEM_LIMIT:-}" ] && GOMEM_ENV=(-e "GOMEMLIMIT=$SOONG_MEM_LIMIT")

COMMON=(--name "$CONTAINER" --cpus="$CPUS" "${GOMEM_ENV[@]}"
  -v "$SRC":/aosp -v "$CCACHE":/ccache -v "$DEVICE_REPO":/repo
  "${FORGE_MNT[@]}"
  "${STOCK_MNT[@]}" "${GAPPS_MNT[@]}" "${DL_MNT[@]}" "${MIRROR_MNT[@]}" "${KEYS_MNT[@]}")

# Interactive shell: allocate a TTY, keep it ephemeral.
if [ "$#" -eq 0 ]; then
  exec docker run --rm -it "${COMMON[@]}" "$IMAGE"
fi

# Command mode: retain the container (no --rm) so Portainer keeps the finished logs, and tee the
# output to a persistent per-phase host log.
LOG="$LOGDIR/${LOG_TAG:-aosp}.log"
set +e
{ printf '\n==== %s :: aosp.sh %s ====\n' "$(date '+%F %T')" "$*"
  docker run "${COMMON[@]}" "$IMAGE" "$@"; } 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
exit "$rc"
