#!/usr/bin/env bash
# bootstrap.sh — build a device's ROM in Docker: image -> init -> manifests -> sync -> features+patches
# -> build. Run from a device repo root; per-device values from ./device.conf. Host needs only Docker.
#   ./forge/bootstrap.sh                        # the first preset in device.conf
#   PRESET=clean ./forge/bootstrap.sh           # a named set of options
#   OPTIONS="gapps root" ./forge/bootstrap.sh   # an ad-hoc set
# One run builds one image.
#   JOBS=8  SYNC_JOBS="4 2 1"  BUILD_ROOT=/path  # overrides
#   SOONG_MEM_LIMIT=20GiB                        # cap soong_build's heap on a small machine
# JOBS sizes the COMPILE phase. It does nothing for analysis: soong_build is one process whose
# peak is set by the build graph (~30 GB live on a 24.0 tree, 60 GB at the Go default of a 2x
# heap), so on a 32 GB box the fix is SOONG_MEM_LIMIT, not a lower JOBS. It only reaches
# soong_build through patches/<branch>/build/soong (soong_ui starts it with `env -i`).
# OEM builds (the oem option) need a stock ROM: STOCK_ROM=path, a zip matching STOCK_ROM_GLOB, or STOCK_ROM_URL.
set -euo pipefail

FORGE="$(cd "$(dirname "$0")" && pwd)"            # .../<device repo>/forge

# --device <name>: in-place layout. Device config and patches under devices/<name>/ instead of a
# separate repo. aosp.sh layers the engine over /repo/forge, so container paths are unchanged.
INPLACE_DEVICE=""
_args=(); while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) INPLACE_DEVICE="${2:?--device needs a name}"; shift 2 ;;
    *)        _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

if [ -n "$INPLACE_DEVICE" ]; then
  DEVICE_REPO="$FORGE/devices/$INPLACE_DEVICE"
  [ -d "$DEVICE_REPO" ] || {
    echo "!! no device at $DEVICE_REPO" >&2
    echo "   create it:  ./tools/new-device-repo.sh --codename <codename> --device $INPLACE_DEVICE" >&2
    [ -d "$FORGE/devices" ] && { echo "   existing:"; ls -1 "$FORGE/devices" 2>/dev/null | sed 's/^/     /'; } >&2
    exit 1
  }
  export FORGE_DEVICE_REPO="$DEVICE_REPO"      # aosp.sh cannot derive this from its own path
else
  DEVICE_REPO="$(cd "$FORGE/.." && pwd)"        # device repo root
fi
OVL="$DEVICE_REPO/overlay"                        # device overlay (same definition as forge/tools/*.sh)
# Run from a bare clone rather than a device repo: the engine expects <device-repo>/forge/, so
# DEVICE_REPO resolves to the clone's parent, where no device.conf can exist.
if [ ! -f "$DEVICE_REPO/device.conf" ] && [ -x "$FORGE/tools/new-device-repo.sh" ] && [ -d "$FORGE/kernel-configs" ]; then
  cat >&2 <<'ONBOARD'
This is a rom-forge clone. The forge is the build engine; each device gets its own repo beside it
holding that device's config and patches.

Create one:

    ./tools/new-device-repo.sh --codename <codename> ~/<name>-android

Codename is what the device reports, not the marketing name:

    adb shell getprop ro.product.device        # or: fastboot getvar product

With a device connected, --codename can be omitted.

Then:

    cd ~/<name>-android && ./bootstrap.sh

Or build in place: ./tools/new-device-repo.sh --device <name> && ./bootstrap.sh --device <name>

See README.md, "Setting up a device".
ONBOARD
  exit 1
fi
[ -f "$DEVICE_REPO/device.conf" ] || { echo "!! no device.conf at $DEVICE_REPO — copy forge/device.conf.example"; exit 1; }
source "$DEVICE_REPO/device.conf"
# Personal, per-checkout settings. Gitignored, so it never reaches the published repo: this is where
# "every build I make also wants the reclaimed OEM assets" belongs, as EXTRA_OPTIONS="oem". Sourced
# after device.conf so it can override anything there, and applies to whichever preset you build
# rather than needing an -oem twin of each one. Anything it adds is reflected in the build tag.
[ -f "$DEVICE_REPO/device.conf.local" ] && source "$DEVICE_REPO/device.conf.local"
: "${DEVICE:?}" "${DEVICE_CODENAME:?}" "${DEVICE_SLUG:?}" "${BRANCH:?}" "${LUNCH_TARGET:?}"
: "${UBUNTU_VER:=20.04}" "${JDK_VER:=11}" "${MANIFEST_URL:=https://github.com/LineageOS/android.git}"

BUILD_ROOT="${BUILD_ROOT:-$DEVICE_REPO/build_output}"   # everything (tree, ccache, logs, fetched zips); gitignored
SRC="$BUILD_ROOT/src"
FORGE_DIR="$FORGE"; export FORGE_DIR
source "$FORGE/lib/presets.sh"

IMG="aosp-${DEVICE_SLUG}:${UBUNTU_VER}"

# One run builds one image. PRESET names a saved set of options; OPTIONS gives one directly.
# Neither given -> the first preset, which is the ordinary build for this device.
if [ -z "${OPTIONS:-}" ] && [ -z "${PRESET:-}" ]; then
  PRESET="$(forge_preset_names | head -1)"
  [ -n "$PRESET" ] || { echo "!! device.conf defines no PRESETS, and neither PRESET nor OPTIONS was given" >&2; exit 1; }
fi
if [ -n "${PRESET:-}" ]; then
  forge_preset_tag "$PRESET" >/dev/null || {
    echo "!! no preset '$PRESET' (PRESETS defines: $(forge_preset_names | tr '\n' ' '))" >&2; exit 1; }
  forge_preset_validate "$PRESET" || exit 1
  # The tag is derived HERE, where EXTRA_OPTIONS (and device.conf.local) are visible. The container
  # never sees them, so deriving it there silently dropped the -oem suffix from the filename.
  TURBO_BUILD_ID="${TURBO_BUILD_ID:-$(forge_preset_tag "$PRESET")}"
else
  # An ad-hoc OPTIONS= set has no preset tag, and before this it fell through to whatever the device
  # defaults to -- so OPTIONS="oem" produced an image called turbo-ether.zip: indistinguishable from
  # the full preset and silent about carrying reclaimed OEM assets. Derive it from the options, for the
  # same reason the preset tags are derived here rather than in the container.
  TURBO_BUILD_ID="${TURBO_BUILD_ID:-$(forge_adhoc_tag "$OPTIONS")}"
fi
BUILD_OPTIONS="${OPTIONS:-$(forge_preset_options "${PRESET:-}")}"
BUILD_OPTIONS="${BUILD_OPTIONS//,/ }"
# REQUIRES in an option.conf pulls in another option, so a pairing that only makes sense together
# does not depend on every preset remembering it (root without a terminal being the case in point).
# One pass is deliberate: a chain deep enough to need recursion means the options are wrong.
for _o in $BUILD_OPTIONS; do
  _req=$(sed -n 's/^REQUIRES=//p' "$FORGE/options/$_o/option.conf" 2>/dev/null | tr -d '"' | tr ',' ' ')
  for _r in $_req; do
    case " $BUILD_OPTIONS " in
      *" $_r "*) ;;
      *) [ -d "$FORGE/options/$_r" ] || { echo "!! option $_o REQUIRES '$_r', which does not exist" >&2; exit 1; }
         echo "   option $_o requires $_r -- adding it"
         BUILD_OPTIONS="$BUILD_OPTIONS $_r" ;;
    esac
  done
done
# Signing is a per-checkout choice (device.conf.local), so say which one this build gets.
if [ -n "${KEYS_DIR:-}" ]; then echo ">> signing: release keys from $KEYS_DIR"
else echo ">> signing: AOSP test keys (set KEYS_DIR in device.conf.local for a publishable image)"; fi

# Parallelism: default min(cores, MemAvailable_GB/2) so a plain run uses full parallelism without OOM.
if [ -z "${JOBS:-}" ]; then
  _cores="$(nproc)"; _ramgb="$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 8)"
  _ramjobs=$(( _ramgb / 2 )); [ "$_ramjobs" -lt 1 ] && _ramjobs=1
  JOBS=$(( _cores < _ramjobs ? _cores : _ramjobs ))
fi
export BUILD_ROOT

echo "== $DEVICE_CODENAME ROM bootstrap ($BRANCH) =="
echo "   device repo: $DEVICE_REPO"
echo "   build root:  $BUILD_ROOT"
echo "   building:    ${PRESET:-<ad-hoc>}  [${BUILD_OPTIONS:-no options}]"
echo "   jobs:        $JOBS"
echo

# ---- preflight ----
command -v docker >/dev/null || { echo "!! Docker not installed"; exit 1; }
docker info >/dev/null 2>&1 || { echo "!! can't talk to the Docker daemon — are you in the 'docker' group (re-login after usermod)?"; exit 1; }
mkdir -p "$BUILD_ROOT"  # ensure it exists first — the df space-check below trips set -e/pipefail if not
avail=$(df -PBG "$BUILD_ROOT" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4);print $4}')
if [ "${avail:-0}" -lt 250 ] 2>/dev/null; then
  echo "!! warning: only ${avail:-?}G free at $BUILD_ROOT — a full build wants ~250G. Ctrl-C to bail."; sleep 5
fi
mkdir -p "$SRC"

AOSP="$FORGE/docker/aosp.sh"                        # the container runner (per-device via device.conf)

# ---- 0. fetch pinned Magisk (verified) for the pre-root boot patch ----
echo ">> [0/5] fetching pinned Magisk APK (sha256-verified)"
bash "$FORGE/prebuilt/fetch-magisk.sh"

# ---- 1. docker image ----
# SKIP_IMAGE_BUILD=1 reuses an existing image instead of rebuilding it. Editing the
# Dockerfile for one device invalidates the layer cache for every Ubuntu version it
# supports, so an unrelated change can force a full apt install -- and a distro
# archive that is slow, throttled or briefly unreachable then blocks the build
# entirely. Ubuntu 20.04 took 4528s to fail on a single .deb this way.
if [ "${SKIP_IMAGE_BUILD:-0}" = "1" ] && docker image inspect "$IMG" >/dev/null 2>&1; then
  echo ">> [1/5] reusing existing image $IMG (SKIP_IMAGE_BUILD=1)"
else
  echo ">> [1/5] building image $IMG (ubuntu $UBUNTU_VER + JDK $JDK_VER; uid/gid $(id -u):$(id -g))"
  if ! docker build --build-arg UBUNTU_VER="$UBUNTU_VER" --build-arg JDK_VER="$JDK_VER" \
      --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t "$IMG" "$FORGE/docker"; then
    if docker image inspect "$IMG" >/dev/null 2>&1 && [ "${STRICT_IMAGE:-0}" != "1" ]; then
      echo "!! ---------------------------------------------------------------------"
      echo "!! Image build FAILED, but $IMG already exists -- continuing with it."
      echo "!!"
      echo "!! Usually a distro mirror being slow or briefly unreachable. Note that"
      echo "!! editing the Dockerfile for ONE device invalidates the layer cache for"
      echo "!! every Ubuntu version it supports, so an unrelated change can force a"
      echo "!! full apt install here."
      echo "!!"
      echo "!! If you changed the Dockerfile and NEED those changes, the image in use"
      echo "!! is stale. Re-run with STRICT_IMAGE=1 to fail instead of falling back."
      echo "!! ---------------------------------------------------------------------"
      docker image inspect -f '   using image built {{.Created}}' "$IMG" 2>/dev/null || true
    else
      echo "!! image build failed and no usable $IMG exists."
      exit 1
    fi
  fi
fi
echo "   logs: $BUILD_ROOT/logs/  (Portainer container: aosp-${DEVICE_SLUG})"

# ---- 2. repo init + manifests ----
# REPO_REFERENCE: shared git object store (one object store shared by every repo) so a second
# device on the same branch downloads only what differs. Identity-mounted by aosp.sh. Only applies
# at `repo init` time; the reference is load-bearing until `repo sync --dissociate`.
REF_ARG=""
# An ALREADY-INITIALISED tree records its reference in git's alternates files, and git stores those
# as ABSOLUTE paths. If that path is not mounted at the same location inside the container, sync dies
# with a message that looks like a network fault but is not:
#   error: unable to normalize alternate object path: /.../build_output/src/.repo/project-objects/...
#   fatal: pack has N unresolved deltas
# Nothing records the reference in device.conf, so re-running a build without REPO_REFERENCE set used
# to fail this way every time (bonito and vs995 both did). Recover it from the tree itself.
if [ -z "${REPO_REFERENCE:-}" ] && [ -d "$SRC/.repo" ]; then
  _alt="$SRC/.repo/manifests.git/objects/info/alternates"
  if [ -f "$_alt" ]; then
    _ref="$(sed -n '1p' "$_alt" 2>/dev/null | sed 's#/\.repo/.*##')"
    if [ -n "$_ref" ] && [ -d "$_ref/.repo" ] && [ "$_ref" != "$SRC" ]; then
      REPO_REFERENCE="$_ref"
      echo "   detected existing git-object reference: $REPO_REFERENCE"
    fi
  fi
fi
if [ -n "${REPO_REFERENCE:-}" ]; then
  [ -d "$REPO_REFERENCE" ] || { echo "!! REPO_REFERENCE=$REPO_REFERENCE does not exist"; exit 1; }
  export MIRROR_DIR="$REPO_REFERENCE"
  REF_ARG="--reference=$REPO_REFERENCE"
  echo "   borrowing git objects from: $REPO_REFERENCE"
fi
echo ">> [2/5] repo init ($BRANCH) + install local_manifests"
LOG_TAG=init "$AOSP" bash -lc "
  cd /aosp
  [ -d .repo ] || repo init -u $MANIFEST_URL -b $BRANCH --git-lfs $REF_ARG
  BUILD_OPTIONS='${BUILD_OPTIONS:-}' /repo/forge/tools/apply-overlay.sh --manifests-only /aosp
"

# ---- 2.5. resolve inputs BEFORE sync (so downloads can be prefetched in parallel) ----
# GApps are ANDROID-VERSION specific, and getting it wrong is SILENT: the build succeeds, the apps
# install, they are simply built for another platform. This used to be a single hardcoded Android-11
# URL, so any device that did not set GAPPS_URL itself got Android 11 GApps whatever it was building
# -- ether/lineage-19.1 (Android 12.1) shipped that way for its whole life.
#
# Resolve the ANDROID VERSION, not the branch: BRANCH naming is ROM-specific (lineage-22.2,
# android-15.0.0_r1, 15.0, bka, fourteen, ...) and the forge is not only for LineageOS. Order:
#   1. ANDROID_VERSION in device.conf                -- explicit, ROM-agnostic, always correct
#   2. derived from BRANCH for naming we recognise   -- convenience for LineageOS and plain AOSP
#   3. otherwise fail and ask                        -- never guess
android_version_for_branch() {
  case "$1" in
    lineage-18.*)  echo 11 ;;
    lineage-19.1)  echo 12.1 ;;    # 19.1 is Android 12.1 (12L); NikGapps ships 12 and 12.1 apart
    lineage-19.*)  echo 12 ;;
    lineage-20.*)  echo 13 ;;
    lineage-21.*)  echo 14 ;;
    lineage-22.*)  echo 15 ;;
    lineage-23.*)  echo 16 ;;
    lineage-24.*)  echo 17 ;;
    android-*)     v="${1#android-}"; echo "${v%%.*}" ;;   # AOSP tags: android-15.0.0_r1 -> 15
    *)             return 1 ;;
  esac
}

_NIKGAPPS_BASE="https://sourceforge.net/projects/nikgapps/files/Releases"
nikgapps_url_for_version() {
  case "$1" in
    11)   echo "$_NIKGAPPS_BASE/Android-11/13-Aug-2024/NikGapps-full-arm64-11-20240813-signed.zip/download" ;;
    12)   echo "$_NIKGAPPS_BASE/Android-12/31-Dec-2024/NikGapps-full-arm64-12-20241231-signed.zip/download" ;;
    12.1) echo "$_NIKGAPPS_BASE/Android-12.1/04-Feb-2026/NikGapps-full-arm64-12.1-20260204-signed.zip/download" ;;
    13)   echo "$_NIKGAPPS_BASE/Android-13/04-Feb-2026/NikGapps-full-arm64-13-20260204-signed.zip/download" ;;
    14)   echo "$_NIKGAPPS_BASE/Android-14/04-Feb-2026/NikGapps-full-arm64-14-20260204-signed.zip/download" ;;
    15)   echo "$_NIKGAPPS_BASE/Android-15/04-Feb-2026/NikGapps-full-arm64-15-20260204-signed.zip/download" ;;
    16)   echo "$_NIKGAPPS_BASE/Android-16/22-Feb-2026/NikGapps-full-arm64-16-20260222-signed.zip/download" ;;
    *)    return 1 ;;
  esac
}

# Which sync-time downloads this build needs. Both are options, so this is just membership of the
# resolved set -- no second table to keep in step with the first. The app options (firefox, fdroid,
# k9, ...) fetch their own APKs from apply-overlay, after the tree exists: which build to take is
# resolved against F-Droid at that point, so there is nothing to prefetch.
WANT_OEM=false; WANT_GAPPS=false
for _o in $BUILD_OPTIONS; do
  case "$_o" in oem) WANT_OEM=true ;; gapps) WANT_GAPPS=true ;; esac
done
# OEM_ASSET_PACK names which manufacturer asset pack to reclaim, not a yes/no. Unset or
# "none" means this build bakes no OEM assets. "nextbit-robin" is the only pack that exists
# today; any device may select it (the Pixel borrows the Robin boot animation), because the
# constraint is the stock ROM you feed it, not the device being built.
case "${OEM_ASSET_PACK:-none}" in
  nextbit-robin) OEM_EXTRACTOR=extract-nextbit-oem-assets.sh ;;
  none|false|"")  WANT_OEM=false ;;
  *) echo "!! unknown OEM_ASSET_PACK $OEM_ASSET_PACK (known: nextbit-robin)"; exit 1 ;;
esac

STOCK_DL_URL=""
if [ "$WANT_OEM" = true ]; then
  if [ -n "${STOCK_ROM:-}" ]; then
    [ -f "$STOCK_ROM" ] || { echo "!! STOCK_ROM=$STOCK_ROM does not exist" >&2; exit 1; }
  else
    for c in "$PWD"/${STOCK_ROM_GLOB:-Stock_ROM_*.zip} "$DEVICE_REPO"/${STOCK_ROM_GLOB:-Stock_ROM_*.zip} "$BUILD_ROOT"/${STOCK_ROM_GLOB:-Stock_ROM_*.zip}; do
      [ -f "$c" ] && STOCK_ROM="$c" && break
    done
  fi
  if [ -z "${STOCK_ROM:-}" ]; then
    if [ -n "${STOCK_ROM_URL:-}" ]; then STOCK_DL_URL="$STOCK_ROM_URL"
    else
      echo "!! OEM build requested but no stock ROM found. Pass STOCK_ROM=/path, drop ${STOCK_ROM_GLOB:-a stock zip} in $PWD, or set STOCK_ROM_URL=... . Failing." >&2
      exit 1
    fi
  fi
fi

GAPPS_DL_URL=""
# WITH_GAPPS_EXTRAS=false narrows gapps to MindTheGapps: Play Store and GMS from the manifest
# repo, and none of the Google app swaps, which are what the NikGapps zip supplies. It exists for
# an Android version NikGapps has not released for yet. Explicit per device, never inferred: a
# build that quietly drops the swaps looks identical until the phone is in your hand, which is
# the failure the check below exists for. options/gapps/require.sh reads the same switch.
if [ "$WANT_GAPPS" = true ] && [ "${WITH_GAPPS_EXTRAS:-true}" != true ]; then
  echo "   GApps: MindTheGapps only (WITH_GAPPS_EXTRAS=false) -- no Google app swaps"
  WANT_GAPPS=false
fi
if [ "$WANT_GAPPS" = true ]; then
  if [ -n "${GAPPS_ZIP:-}" ]; then
    [ -f "$GAPPS_ZIP" ] || { echo "!! GAPPS_ZIP=$GAPPS_ZIP does not exist" >&2; exit 1; }
  else
    for c in "$PWD"/NikGapps*.zip "$PWD"/*[Gg][Aa]pps*.zip "$DEVICE_REPO"/*[Gg][Aa]pps*.zip "$BUILD_ROOT"/*[Gg][Aa]pps*.zip; do
      [ -f "$c" ] && GAPPS_ZIP="$c" && break
    done
  fi
  if [ -z "${GAPPS_ZIP:-}" ]; then
    if [ -n "${GAPPS_URL:-}" ]; then
      GAPPS_DL_URL="$GAPPS_URL"                       # explicit per-device override wins
    else
      _av="${ANDROID_VERSION:-$(android_version_for_branch "$BRANCH" || true)}"
      if [ -z "$_av" ]; then
        echo "!! cannot tell which Android version BRANCH=$BRANCH is." >&2
        echo "!! The forge is not LineageOS-only, so branch names are not a reliable signal." >&2
        echo "!! Set ANDROID_VERSION (e.g. ANDROID_VERSION=15) or GAPPS_URL in device.conf." >&2
        exit 1
      fi
      if ! GAPPS_DL_URL="$(nikgapps_url_for_version "$_av")"; then
        echo "!! no NikGapps release mapped for Android $_av." >&2
        echo "!! Add it to nikgapps_url_for_version() in forge/bootstrap.sh, or set GAPPS_URL." >&2
        echo "!! Refusing to guess -- the wrong version's GApps installs silently and only" >&2
        echo "!! shows up on the device." >&2
        exit 1
      fi
      echo "   GApps: Android $_av -> $(basename "${GAPPS_DL_URL%/download}")"
    fi
  fi
fi
# ---- 3. reset patched projects (feature targets + device patches), then prefetch + sync ----
# Compute the full set of projects our commits touch so repo sync can check them out clean.
RESET_PROJECTS="${PATCHED_PROJECTS:-}"
[ -d "$OVL/patches" ] && RESET_PROJECTS="$RESET_PROJECTS $(cd "$OVL/patches" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u)"
# Projects the enabled options patch. Derived from the directory layout -- patches/<project>/*.patch
# -- exactly as the device patches above are, so an option has no TARGETS field to declare and
# therefore no way for it to disagree with what is actually on disk.
for _o in ${BUILD_OPTIONS:-}; do
  _od="$FORGE/options/$_o/patches/$BRANCH"
  [ -d "$_od" ] && RESET_PROJECTS="$RESET_PROJECTS $(cd "$_od" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u)"
done
RESET_PROJECTS=$(printf '%s\n' $RESET_PROJECTS | sort -u | tr '\n' ' ')
echo ">> [3/5] reset patched projects so repo sync can check them out: $RESET_PROJECTS"
LOG_TAG=reset "$AOSP" bash -lc "
  for p in $RESET_PROJECTS; do
    d=/aosp/\$p; [ -d \"\$d/.git\" ] || continue
    git -C \"\$d\" am --abort 2>/dev/null
    git -C \"\$d\" reset --hard >/dev/null 2>&1 && echo \"   reset \$p\"
  done; exit 0"

DL="$BUILD_ROOT/dl"; mkdir -p "$DL"
echo ">> [3/5] prefetch downloads in background (overlapping sync) -> $DL"
( DL_DIR="$DL" CONTAINER=aosp-${DEVICE_SLUG}-prefetch LOG_TAG=prefetch "$AOSP" bash -lc \
    "STOCK_DL_URL='$STOCK_DL_URL' GAPPS_DL_URL='$GAPPS_DL_URL' /repo/forge/docker/prefetch.sh" ) &
PREFETCH_PID=$!

echo ">> [3/5] repo sync — hours + ~100GB the first time (progress in logs/sync.log)"
sync_ok=false
for sj in ${SYNC_JOBS:-8 6 4 2 1}; do
  echo "   repo sync -j$sj"
  if LOG_TAG=sync CONTAINER=aosp-${DEVICE_SLUG}-sync "$AOSP" bash -lc "cd /aosp && repo sync -c -j$sj --force-sync --no-clone-bundle"; then
    sync_ok=true; break
  fi
  echo "!! sync failed at -j$sj (often HTTP 429 throttling) — retrying at lower parallelism"
done
[ "$sync_ok" = true ] || { echo "!! repo sync failed at every parallelism level"; kill "$PREFETCH_PID" 2>/dev/null || true; exit 1; }

echo ">> [3/5] waiting for prefetch to finish"
wait "$PREFETCH_PID" || { echo "!! prefetch failed — see logs/prefetch.log (a missing input must stop the build)" >&2; exit 1; }

# ---- 4. apply patches ----
echo ">> [4/5] apply overlay patches"
# BUILD_OPTIONS goes in so apply-overlay knows which options are on. It needs that because an
# option's PATCHES modify the tree, and the tree is built once for one image -- so patches for an
# option this build does not want must not be applied at all.
# FDROID_PINS too: the app fetchers run in there, and a host env var does not cross into docker.
LOG_TAG=apply "$AOSP" bash -lc "BUILD_OPTIONS='${BUILD_OPTIONS:-}' FDROID_PINS='${FDROID_PINS:-}' /repo/forge/tools/apply-overlay.sh /aosp"

# ---- 4b + 4c: extract OEM assets and Google apps CONCURRENTLY (disjoint dirs) ----
EXTRACT_PIDS=()
if [ "$WANT_OEM" = true ]; then
  if [ -n "${STOCK_ROM:-}" ]; then
    echo ">> [4b] extracting OEM assets from $(basename "$STOCK_ROM") (concurrent)"
    ( STOCK_DIR="$(cd "$(dirname "$STOCK_ROM")" && pwd)" DL_DIR="$DL" CONTAINER=aosp-${DEVICE_SLUG}-oem LOG_TAG=oem "$AOSP" \
        bash -lc "/repo/forge/tools/$OEM_EXTRACTOR '/stock/$(basename "$STOCK_ROM")' /aosp" ) & EXTRACT_PIDS+=($!)
  else
    echo ">> [4b] extracting OEM assets from prefetched stock ROM (concurrent)"
    ( DL_DIR="$DL" CONTAINER=aosp-${DEVICE_SLUG}-oem LOG_TAG=oem "$AOSP" \
        bash -lc "/repo/forge/tools/$OEM_EXTRACTOR '/dl/stock.zip' /aosp" ) & EXTRACT_PIDS+=($!)
  fi
fi
if [ "$WANT_GAPPS" = true ]; then
  echo ">> [4c] extracting Google apps (concurrent)"
  if [ -n "${GAPPS_ZIP:-}" ]; then
    ( GAPPS_DIR="$(cd "$(dirname "$GAPPS_ZIP")" && pwd)" DL_DIR="$DL" CONTAINER=aosp-${DEVICE_SLUG}-gapps LOG_TAG=gapps "$AOSP" bash -lc \
        "/repo/forge/tools/extract-gapps-apps.sh '/gapps/$(basename "$GAPPS_ZIP")' /aosp" ) & EXTRACT_PIDS+=($!)
  else
    ( DL_DIR="$DL" CONTAINER=aosp-${DEVICE_SLUG}-gapps LOG_TAG=gapps "$AOSP" bash -lc \
        "/repo/forge/tools/extract-gapps-apps.sh '/dl/gapps.zip' /aosp" ) & EXTRACT_PIDS+=($!)
  fi
fi
if [ "${#EXTRACT_PIDS[@]}" -gt 0 ]; then
  for p in "${EXTRACT_PIDS[@]}"; do
    wait "$p" || { echo "!! an extractor failed — see logs/oem.log / logs/gapps.log" >&2; exit 1; }
  done
fi

# ---- 5. build ----
echo ">> [5/5] build the ROM(s) — progress in logs/build.log"
LOG_TAG=build "$AOSP" bash -lc "JOBS=$JOBS PRESET='${PRESET:-}' OPTIONS='${BUILD_OPTIONS:-}' TURBO_BUILD_ID='${TURBO_BUILD_ID:-}' KEEP_GOING='${KEEP_GOING:-}' bash /repo/forge/docker/_build_rom.sh"

echo
# Package the on-device Linux chroot as a flashable Magisk module, next to the ROM. It is tiny
# (~7 KB: scripts only, the rootfs is fetched on device) and independent of the ROM, so there is no
# reason not to always emit it -- installing it is opt-in on the phone.
if [ -d "$FORGE/modules/linux-chroot" ]; then
  _lxzip="$BUILD_ROOT/linux-chroot-$(grep -oP '^version=\K.*' "$FORGE/modules/linux-chroot/module.prop" 2>/dev/null || echo v0).zip"
  rm -f "$_lxzip"
  if ( cd "$FORGE/modules/linux-chroot" && zip -qr "$_lxzip" . -x '.*' ) 2>/dev/null; then
    echo "   Linux chroot module: $_lxzip  (install in Magisk, then run 'linux-setup')"
  fi
fi

# Keep the flashable set outside out/: the next preset's installclean deletes every zip there, so
# a build of `clean` after `cloud` silently costs the cloud zip. Hard links (same filesystem), so
# free; recovery.img and boot.img travel with the zip they came from, named for it, the way
# release.sh publishes them. release.sh reads out/ on purpose (it audits the tree); this is for
# flashing.
_out="$SRC/out/target/product/$DEVICE_CODENAME"
_zip="$(ls -t "$_out"/lineage-*-"$DEVICE_CODENAME".zip 2>/dev/null | head -1 || true)"
if [ -n "$_zip" ]; then
  _keep="$BUILD_ROOT/artifacts"; mkdir -p "$_keep"
  _stem="$(basename "${_zip%.zip}")"
  rm -f "$_keep/$_stem".*
  ln "$_zip" "$_keep/$_stem.zip" 2>/dev/null || cp "$_zip" "$_keep/$_stem.zip"
  for _img in recovery boot boot-magisk; do
    [ -f "$_out/$_img.img" ] && { ln "$_out/$_img.img" "$_keep/$_stem-$_img.img" 2>/dev/null || cp "$_out/$_img.img" "$_keep/$_stem-$_img.img"; }
  done
  ( cd "$_keep" && sha256sum "$_stem.zip" > "$_stem.zip.sha256" )
fi

echo "== DONE =="
echo "   ROM(s): $SRC/out/target/product/$DEVICE_CODENAME/lineage-*-$DEVICE_CODENAME.zip"
[ -n "$_zip" ] && echo "   kept:   $BUILD_ROOT/artifacts/$_stem.zip (+ -recovery/-boot/-boot-magisk.img; survives the next build)"
echo "   Flash in recovery. See the device repo's flashing/ if present."
