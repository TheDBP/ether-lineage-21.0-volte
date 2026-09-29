#!/bin/bash
# _build_rom.sh — build the per-device ROM inside the container (robin-forge).
# Run via aosp.sh so paths/mounts are set:
#   ./forge/docker/aosp.sh bash -lc 'bash /repo/forge/docker/_build_rom.sh'
# Per-device values (LUNCH_TARGET, DEVICE, PRESETS) come from /repo/device.conf.
#
# ONE invocation builds ONE image. Say what you want either way round:
#   PRESET=full                        a named set of options from PRESETS
#   OPTIONS="gapps root nav-icons"     an ad-hoc set
#   TURBO_BUILD_ID=x                   version tag (…-UNOFFICIAL-<x>-<codename>); default "turbo"
#
# OPTIONS and TURBO_BUILD_ID override the preset's values when both are given.
#
# Building several images used to be possible in one run. It was never once used, and it saved a
# single apply-overlay pass -- seconds -- because installclean runs between images either way and
# the expensive reuse comes from out/ persisting on disk. Dropping it is what let patches and
# makefile fragments become the same kind of thing.
#
# JOBS controls parallelism; default = min(cores, RAM_GB/2) to avoid OOM. Override with JOBS=N.
set -o pipefail
cd /aosp || exit 1
export USE_CCACHE=1 CCACHE_DIR=/ccache
ccache -M "${CCACHE_SIZE:-50G}" >/dev/null 2>&1 || true

DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"       # /repo inside the container
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
: "${LUNCH_TARGET:?device.conf missing or LUNCH_TARGET unset}"
: "${DEVICE:?device.conf missing or DEVICE unset}"

if [ -z "${JOBS:-}" ]; then
  _cores="$(nproc)"; _ramgb="$(awk '/MemAvailable/{print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 8)"
  _ramjobs=$(( _ramgb / 2 )); [ "$_ramjobs" -lt 1 ] && _ramjobs=1
  JOBS=$(( _cores < _ramjobs ? _cores : _ramjobs ))
fi

FORGE_DIR="$DEVICE_REPO/forge"; export FORGE_DIR
source "$FORGE_DIR/lib/presets.sh"

source build/envsetup.sh

build_one() {
  # $1=TURBO_BUILD_ID (the build tag)   $2=space-separated option names
  #
  # One invocation builds one image. gapps, oem and root used to be three positional booleans here
  # because they existed before options did; they are ordinary options now and arrive in $2 like any
  # other. Every option the forge knows about is set to false first, so the build is exactly the set
  # asked for and nothing inherited from the environment.
  export TURBO_BUILD_ID="$1"
  local _o _sw OPT_FP=""
  for _o in $(forge_all_options); do export "$(forge_option_switch "$_o")=false"; done
  for _o in $2; do
    _sw="$(forge_option_switch "$_o")"
    export "$_sw=true"
  done
  for _o in $(forge_all_options); do
    _sw="$(forge_option_switch "$_o")"; OPT_FP="$OPT_FP $_sw=${!_sw}"
  done
  forge_export_option_env || return 1
  echo "=== options:${OPT_FP:- none} ==="
  # KEEP_GOING=true -> mka -k: do not stop at the first error. A port onto a new branch fails in
  # clusters, and stopping at error #1 means one build cycle (30+ min here) per fix. With -k a
  # single run surfaces the whole error surface, which forge/tools/triage-build-log.sh then
  # collapses into distinct causes. Off by default: -k also masks which failure came first, and
  # a normal build should stop at the first real problem.
  MKA_K=""; [ "${KEEP_GOING:-}" = true ] && MKA_K="-k"
  echo "=== building tag=$1 (mka $MKA_K -j$JOBS bacon) ==="
  lunch "$LUNCH_TARGET" || { echo "!! lunch failed"; return 1; }
  # Stale-staging guard. out/target/product keeps modules no longer in the install set, and the next
  # build repackages them (e.g. two dialers). Two triggers: (a) a build that DIED mid-way (out/.build_
  # in_flight sentinel); (b) the module set CHANGED since the last SUCCESSFUL build (config fingerprint).
  # Either => installclean first (a repackage, not a recompile).
  mkdir -p out
  # Which releasekey signed the last build is part of the fingerprint: swapping keys must
  # installclean, or the staged APKs keep the old signature.
  local keys_fp; keys_fp="$(sha256sum vendor/lineage-priv/keys/releasekey.x509.pem 2>/dev/null | cut -c1-12)"
  cur_fp="tag=$TURBO_BUILD_ID${OPT_FP} keys=${keys_fp:-test} mods=$(
    { ls -d vendor/extra/gapps-extras/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null
      ls -d "device/$DEVICE/gapps-extras/"*/ 2>/dev/null | xargs -n1 basename 2>/dev/null
      [ -f "device/$DEVICE/firefox/Firefox.apk" ] && echo Firefox
      [ -f vendor/lineage/prebuilts/firefox/Firefox.apk ] && echo Firefox
    } | sort -u | tr '\n' ',')"
  if [ -f out/.build_in_flight ] || [ "$cur_fp" != "$(cat out/.turbo_config 2>/dev/null || true)" ]; then
    echo "=== installclean (previous build unfinished, or config/module set changed) ==="
    mka installclean 2>/dev/null || true
  fi
  # Prerequisites first. Hours of compile before discovering a missing input is the expensive way
  # to find out, and it is the one this used to take.
  run_option_hooks require.sh || { echo "!! prerequisites not met for tag=$1"; return 1; }

  : > out/.build_in_flight
  printf '%s' "$cur_fp" > out/.turbo_config
  mka $MKA_K -j"$JOBS" bacon; local rc=$?
  echo "=== tag=$1 exit: $rc ==="
  # NB: the sentinel is cleared once at the end of the whole run, not here — so a later build in
  # in the same run sees it and installcleans the previous one's staging first.
  [ "$rc" -ne 0 ] && return $rc
  # Post-build hooks for whichever options are on. root's is the Magisk bake; the failure it used
  # to guard against -- shipping an unrooted image under a rooted tag -- is now caught before the
  # compile by the same option's require.sh, rather than after it.
  run_option_hooks post-build.sh || return 1
  return 0
}

export DEVICE_REPO

# Run one hook for every option whose switch is on. An option is a capability, and not every
# capability is a product-config edit: nav-icons is a makefile fragment, root is a boot image that
# has to be patched after the build produced it. Hooks are how the second kind is expressed, so
# _build_rom.sh does not need to know that Magisk exists.
#
#   require.sh     before the build. Non-zero stops it.
#   post-build.sh  after a successful build. Non-zero fails the build.
#
# Switch names are derived from the directory name, the same rule apply-overlay.sh uses.
run_option_hooks() {
  local hook="$1" odir oname osw rc=0
  [ -d "$FORGE_DIR/options" ] || return 0
  for odir in "$FORGE_DIR/options"/*/; do
    [ -f "$odir/option.conf" ] || continue
    [ -f "$odir/$hook" ] || continue
    oname="$(basename "$odir")"
    osw="WITH_$(printf '%s' "$oname" | tr 'a-z-' 'A-Z_')"
    [ "${!osw:-false}" = true ] || continue
    echo "=== option $oname: $hook ==="
    if ! ( cd /aosp && bash "$odir/$hook" ); then
      echo "!! option $oname: $hook failed"; rc=1
    fi
  done
  return $rc
}

# ---- what to build -------------------------------------------------------------------------------
# PRESET names a saved set of options; OPTIONS gives one directly. Exactly one image comes out.
BUILD_OPTIONS="${OPTIONS:-}"
BUILD_TAG="${TURBO_BUILD_ID:-}"
if [ -n "${PRESET:-}" ]; then
  forge_preset_tag "$PRESET" >/dev/null || {
    echo "!! no preset '$PRESET' (PRESETS defines: $(forge_preset_names | tr '\n' ' '))"; exit 1; }
  forge_preset_validate "$PRESET" || exit 1
  [ -n "$BUILD_OPTIONS" ] || BUILD_OPTIONS="$(forge_preset_options "$PRESET")"
  [ -n "$BUILD_TAG" ]     || BUILD_TAG="$(forge_preset_tag "$PRESET")"
fi
BUILD_OPTIONS="${BUILD_OPTIONS//,/ }"
[ -n "$BUILD_TAG" ] || BUILD_TAG=turbo

build_one "$BUILD_TAG" "$BUILD_OPTIONS" || exit $?
rm -f out/.build_in_flight   # finished cleanly (a failed build exits above, leaving the sentinel)
exit 0
