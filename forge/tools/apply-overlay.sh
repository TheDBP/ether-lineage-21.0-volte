#!/bin/bash
# apply-overlay.sh — apply the composed customization stack onto a synced LineageOS tree:
#   1. local_manifests (device repo)   2. enabled options (forge/options)
#   3. the device's own overlay/patches  4. optional wallpaper + F-Droid/Firefox.
# rom-forge: generic. Feature set + toggles come from the device repo's device.conf.
#
#   ./forge/tools/apply-overlay.sh [--manifests-only] [AOSP_ROOT]   (AOSP_ROOT defaults to /aosp)
#
# Two phases: --manifests-only BEFORE `repo sync` (installs local_manifests only), then again WITHOUT
# it AFTER sync (git-am's the patches once the projects exist).
set -euo pipefail

DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"   # tools -> forge -> device repo root (= /repo in container)
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
OVL="$DEVICE_REPO/overlay"
FORGE="$DEVICE_REPO/forge"

MANIFESTS_ONLY=false
if [ "${1:-}" = "--manifests-only" ]; then MANIFESTS_ONLY=true; shift; fi
AOSP="${1:-/aosp}"

[ -d "$AOSP/.repo" ] || { echo "!! $AOSP doesn't look like a repo tree (.repo missing)"; exit 1; }

echo ">> local_manifests -> $AOSP/.repo/local_manifests/"
mkdir -p "$AOSP/.repo/local_manifests"
cp "$OVL"/local_manifests/*.xml "$AOSP/.repo/local_manifests/"
echo "   installed: $(cd "$OVL/local_manifests" && echo *.xml)"

# Options can bring their own projects. gapps needs MindTheGapps in the tree, and that is true of
# every device, so it belongs to the option rather than being copy-pasted into each device repo --
# which is exactly how ether 20.0 ended up as the one branch without it, building GApps that
# silently contained no GMS.
#
# BRANCH-SCOPED, the same rule patches follow, because the upstream revision differs per Android
# release. A manifest under an option is a promise about a specific release, never a generic one.
for _o in ${BUILD_OPTIONS:-}; do
  _md="$FORGE/options/$_o/local_manifests/${BRANCH:-}"
  [ -d "$_md" ] || continue
  _n=0
  for _m in "$_md"/*.xml; do
    [ -e "$_m" ] || continue
    cp "$_m" "$AOSP/.repo/local_manifests/"
    _n=$((_n+1))
  done
  [ "$_n" -gt 0 ] && echo "   option $_o: +$_n manifest(s) for ${BRANCH:-?}"
done

if [ "$MANIFESTS_ONLY" = true ]; then
  echo ">> --manifests-only: local_manifests installed; skipping patches (re-run after 'repo sync')"
  exit 0
fi

# Apply one project's patch series from a patches root (idempotent — skips if the first subject is
# already in the log; matched in-shell, never `git log | grep -q`, which SIGPIPEs under pipefail).
apply_project_from() {
  local root="$1" proj="$2" tag="$3"
  local dir="$root/$proj"
  [ -d "$dir" ] || return 0
  local n; n=$(ls "$dir"/*.patch 2>/dev/null | wc -l); [ "$n" -gt 0 ] || return 0
  if [ ! -d "$AOSP/$proj/.git" ]; then echo "   (skip $proj — not synced yet)"; return 0; fi
  local subjs; subjs=$(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$dir"/*.patch)
  local subj="${subjs%%$'\n'*}"
  # Look at the local commits only -- those on top of BASE_REF -- not the project's whole history. A
  # subject is not unique: a patch that reverts an upstream commit has the same subject as an
  # upstream revert of the same commit, and upstream sometimes lands one of its own. Matching the
  # full log then "finds" the patch in upstream's history and silently skips it, leaving the tree
  # without the change. That is how hardware/google/pixel lost the drv2624 vibrator tree: upstream
  # carried its own Revert "pixel: Restore drv2624 vibrator HAL APEX" while the local one restores the
  # directory that revert deleted. Fall back to the old window only if BASE_REF does not resolve.
  local _range="-80"
  if [ -n "${BASE_REF:-}" ] && ( cd "$AOSP/$proj" && git rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1 ); then
    _range="$BASE_REF..HEAD"
  fi
  local applied; applied=$(cd "$AOSP/$proj" && git log --pretty=%s $_range 2>/dev/null) || applied=""
  if [ -n "$subj" ] && [[ "$applied" == *"$subj"* ]]; then
    echo "   ($proj: '$subj' already applied — skipping)"; return 0
  fi
  echo ">> $proj : applying $n patch(es) [$tag]"
  ( cd "$AOSP/$proj" && git am --3way --keep-cr "$dir"/*.patch ) \
    || { echo "   !! git am failed in $proj [$tag] — resolve, 'git am --continue', or 'git am --abort'"; return 1; }
}

# COMPAT gate: "all" | comma-OR of device=<vendor/codename> | soc=<x> | branch=<b>.
# Expand ${VAR} references in an assets.list path against device.conf. This is what lets one
# shared feature land somewhere different per device -- a style that is native to one phone can
# go in an always-on overlay there while riding along with the OEM assets elsewhere, without
# forking the feature. Only bare ${UPPER_CASE} is recognised: these paths come from a feature
# repo, so no eval, no command substitution, no $(...).
expand_dest() {
  local rest="$1" out="" name
  while [[ "$rest" =~ ^([^$]*)\$\{([A-Z_][A-Z0-9_]*)\}(.*)$ ]]; do
    name="${BASH_REMATCH[2]}"
    # An unset variable here means a device enabled a feature without configuring where its
    # assets go. Silently expanding to "" would write to a plausible-looking wrong path and
    # the miss would only show up as a missing asset in a finished image.
    [ -n "${!name-}" ] || { echo "   !! assets.list references \${$name}, which this device does not set" >&2; return 1; }
    out+="${BASH_REMATCH[1]}${!name}"
    rest="${BASH_REMATCH[3]}"
  done
  printf '%s%s' "$out" "$rest"
}

compat_ok() {
  local c="${1:-all}"; [ "$c" = all ] || [ -z "$c" ] && return 0
  local tok; local IFS=,
  for tok in $c; do
    case "$tok" in
      device=*) [ "${tok#device=}" = "${DEVICE:-}" ] && return 0 ;;
      soc=*)    [ "${tok#soc=}"    = "${SOC:-}" ]    && return 0 ;;
      branch=*) [ "${tok#branch=}" = "${BRANCH:-}" ] && return 0 ;;
    esac
  done
  return 1
}

# ---- options: the half that must run BEFORE device patches -----------------------------------
# An option's patches and fetches, for the options this build actually wants.
#
# Patches are the reason BUILD_OPTIONS has to be known at sync time. An option's makefile fragment
# can be gated at build time with ifeq, but a git-am patch modifies the tree -- and since one run
# now builds one image, the tree is this build's alone, so an option that is off must not have its
# patches applied at all.
#
# COMPAT works exactly as it does for features: an option that cannot apply to this device is
# skipped quietly rather than failing the build.
apply_option_prepatch() {
  # Two statements, not one: in `local a="$1" b="$a"`, bash declares both names (unsetting them)
  # before assigning, so $a inside the same local is empty and b silently becomes a truncated path.
  local oname="$1"
  local odir="$FORGE/options/$oname"
  [ -f "$odir/option.conf" ] || { echo "   !! no such option: $oname"; return 1; }
  local NAME DESC COMPAT
  source "$odir/option.conf"
  if ! compat_ok "${COMPAT:-all}"; then
    echo "   (option $oname -- COMPAT='${COMPAT:-all}' doesn't match this device; skipping)"; return 0
  fi
  # Patches are BRANCH-SCOPED: patches/<branch>/<project>/*.patch. They are diffs against upstream
  # source, and upstream source differs per release -- themed-icons alone has five distinct versions
  # across 19.1, 20.0 and 22.2. Everything else in an option (product.mk, tree/, hooks) is local
  # text and applies to every branch unchanged, so only this part is scoped.
  local pdir="$odir/patches/$BRANCH"
  if [ -d "$pdir" ]; then
    local proj
    for proj in $(cd "$pdir" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u); do
      apply_project_from "$pdir" "$proj" "opt:$oname" || return 1
    done
  elif [ -d "$odir/patches" ]; then
    # Patches for other branches but not this one. That is only a problem if the option has no other
    # way to contribute here -- fdroid, for instance, patches vendor/lineage on 22.2 but on 19.1 the
    # device tree already builds it and the option only needs to fetch the APKs. An option that can
    # do NOTHING on this branch is the real error; one that does less is a legitimate shape.
    local _can=0
    for _part in fetch.sh product.mk build-env assets.list tree require.sh post-patch.sh post-build.sh local_manifests; do
      [ -e "$odir/$_part" ] && _can=1
    done
    if [ "$_can" = 0 ]; then
      echo "   !! option $oname has patches for other branches, none for $BRANCH, and nothing else"
      echo "      to contribute here (available: $(ls "$odir/patches" 2>/dev/null | tr '\n' ' '))"
      return 1
    fi
    echo "   (option $oname: no patches for $BRANCH; using its other parts)"
  fi
  if [ -f "$odir/fetch.sh" ]; then
    echo ">> option $oname: fetch"
    # DEVICE/VENDOR/DEVICE_SLUG are sourced from device.conf above but were never exported, so a
    # hook reading $DEVICE saw an empty string and silently skipped whatever it guarded. That is how
    # F-Droid went missing from ether 20.0: its fetch.sh copies into device/<vendor>/<codename>/fdroid
    # only "if [ -n "$DEVICE" ]", which was never true. Firefox survived by accident -- bootstrap has
    # a separate step that places it -- which is exactly why the bug stayed invisible.
    # BUILD_OPTIONS is passed explicitly for the same reason DEVICE is: a fetcher that guards on it
    # must not depend on inheritance. nextcloud-core's fetch refuses to run when nextcloud is also on,
    # and that guard is worthless if the variable can arrive empty.
    ( cd "$AOSP" && FORGE_DIR="$FORGE" OPTION_DIR="$odir" \
        DEVICE="${DEVICE:-}" VENDOR="${VENDOR:-}" DEVICE_SLUG="${DEVICE_SLUG:-}" \
        FDROID_PINS="${FDROID_PINS:-}" BUILD_OPTIONS="${BUILD_OPTIONS:-}" \
        bash "$odir/fetch.sh" "$AOSP" ) \
      || { echo "   !! fetch failed for option $oname"; return 1; }
  fi
  return 0
}

# ---- 0b. vendored projects (VENDORED_PROJECTS in device.conf) ----
# Some projects have no upstream to sync: the ether device tree and the pre-rename qcom
# sepolicy-legacy were recovered from Software Heritage after their repos were deleted, and live in
# the device repo under vendored/. They must be re-installed on every run: `repo sync --force-sync`
# prunes worktrees that are no longer manifest projects, which silently removed device/nextbit/ether
# and then failed the build much later with "no BoardConfig defines TARGET_KERNEL_SOURCE".
#
# Format: "<src-under-device-repo>:<dest-under-AOSP> ..."
# Each gets a git repo with a single commit so it can be a PATCHED_PROJECT (git am needs history).
for _vp in ${VENDORED_PROJECTS:-}; do
  _vsrc="$DEVICE_REPO/${_vp%%:*}"
  _vdst="$AOSP/${_vp#*:}"
  [ -d "$_vsrc" ] || { echo "!! VENDORED_PROJECTS: no such source: $_vsrc"; exit 1; }
  # Re-vendor on EVERY run. vendored/ in the device repo is the source of truth. This used to skip
  # when the destination already existed ("left alone"), which meant any edit under vendored/ was
  # silently ignored after the first sync: a sepolicy fix built "successfully" while changing
  # nothing. Patches are re-applied from overlay/patches immediately below, so recreating the git
  # repo loses nothing, and cp -a preserves mtimes so an unchanged tree triggers no rebuild.
  rm -rf "$_vdst"
  mkdir -p "$(dirname "$_vdst")"
  cp -a "$_vsrc" "$_vdst"
  rm -rf "$_vdst/.git"
  git -C "$_vdst" init -q
  git -C "$_vdst" config user.name  "rom-forge"
  git -C "$_vdst" config user.email "rom-forge@localhost"
  git -C "$_vdst" add -A
  git -C "$_vdst" commit -q -m "vendored ${_vp%%:*} (recovered upstream; see overlay/local_manifests)"
  echo ">> vendored ${_vp%%:*} -> ${_vp#*:} (git-initialised for patching)"
done

# ---- 0. engine patches: forge/patches/<branch>/<project> -- every device, every preset ----------
# Build-system fixes that are about the machine, not the phone (soong_ui memory plumbing). Branch-
# scoped like every other patch; a branch with no directory here gets nothing.
if [ -d "$FORGE/patches/${BRANCH:-}" ]; then
  for proj in $(cd "$FORGE/patches/$BRANCH" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u); do
    apply_project_from "$FORGE/patches/$BRANCH" "$proj" "engine" || exit 1
  done
fi

# ---- 1a. enabled options: patches and fetches (before device patches) ----
for _o in ${BUILD_OPTIONS:-}; do apply_option_prepatch "$_o" || exit 1; done

# ---- 2. device-specific patches (this repo's overlay/patches; discovered from the tree) ----
if [ -d "$OVL/patches" ]; then
  for proj in $(cd "$OVL/patches" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u); do
    apply_project_from "$OVL/patches" "$proj" "device" || exit 1
  done
fi

# ---- 2'. prebuilt blob fixups (this repo's overlay/blob-fixups) ----
# DT_NEEDED edits to vendor blobs, one line each (tools/blob-fixups.sh documents the format). After
# the device patches on purpose: a patched vendor project was just reset to upstream, so its blobs
# are back to what the OEM shipped and every fixup has to go on again. Idempotent, so a project that
# was not reset is simply reported as already in place.
if [ -f "$OVL/blob-fixups" ]; then
  echo ">> blob fixups (overlay/blob-fixups)"
  bash "$FORGE/tools/blob-fixups.sh" "$AOSP" "$OVL/blob-fixups" || { echo "   !! blob fixups failed"; exit 1; }
fi

# ---- 2a. enabled options: placement that needs the device patches applied ----------------------
# fetch.sh deliberately runs BEFORE device patches: a module named in PRODUCT_PACKAGES that does not
# exist yet fails lunch outright, so the APK has to be on disk early. But some options must drop
# files INTO a directory those same patches create -- device/<vendor>/<codename>/fdroid is added by
# the device's own patch series, and did not exist when fetch.sh looked for it. The copy was guarded
# on that directory, so it silently never ran, and F-Droid shipped in no ether 20.0 image at all
# while the option reported success. Anything needing a patched tree belongs here instead.
for _o in ${BUILD_OPTIONS:-}; do
  _od="$FORGE/options/$_o"
  [ -f "$_od/post-patch.sh" ] || continue
  echo ">> option $_o: post-patch placement"
  # device.conf is sourced above but not exported, and `bash <script>` is a new process: a
  # hook only sees what is named here, otherwise it silently reads as unset.
  ( cd "$AOSP" && FORGE_DIR="$FORGE" OPTION_DIR="$_od" DEVICE_REPO="$DEVICE_REPO" \
      DEVICE="${DEVICE:-}" VENDOR="${VENDOR:-}" DEVICE_SLUG="${DEVICE_SLUG:-}" \
      APEX_EROFS_UNSUPPORTED="${APEX_EROFS_UNSUPPORTED:-false}" \
      bash "$_od/post-patch.sh" "$AOSP" ) \
    || { echo "   !! post-patch failed for option $_o"; exit 1; }
done

# ---- 2b. enabled options -> vendor/extra (AFTER device patches) --------------------------------
# The half of an option that is files: its makefile fragment, anything under tree/, and its
# assets.list. This runs after device patches for the same reason feature assets do -- an asset
# overwrites what is in the tree, and git am refuses to apply a patch that adds a file already
# sitting there untracked.
#
# Only the options this build asked for are staged. vendor/extra is cleared first so nothing from a
# previous build's option set survives into this one: a stale overlay directory looks exactly like a
# fresh one, and product.mk would still be naming it.
XTRA="$AOSP/vendor/extra"
rm -rf "$XTRA"
mkdir -p "$XTRA"
GEN="$XTRA/product.mk"
{
  echo "# GENERATED by rom-forge (tools/apply-overlay.sh). Do not edit -- it is rewritten on every"
  echo "# overlay run. To change what an option does, edit forge/options/<name>/product.mk."
  echo "#"
  echo "# LineageOS inherits this file on every device via vendor/lineage/config/common.mk, so"
  echo "# everything below applies to any device without a patch to its tree."
  echo ""
} > "$GEN"
_nopt=0
for _oname in ${BUILD_OPTIONS:-}; do
  _odir="$FORGE/options/$_oname"
  [ -f "$_odir/option.conf" ] || { echo "   !! no such option: $_oname"; exit 1; }
  ( NAME=""; DESC=""; COMPAT=""; source "$_odir/option.conf"; compat_ok "${COMPAT:-all}" ) || {
    echo "   (option $_oname -- COMPAT does not match this device; skipping)"; continue; }
  _osw="WITH_$(printf '%s' "$_oname" | tr 'a-z-' 'A-Z_')"
  if [ -d "$_odir/tree" ]; then
    ( cd "$_odir/tree" && find . -type f -print0 ) | while IFS= read -r -d '' _f; do
      mkdir -p "$AOSP/$(dirname "${_f#./}")"
      cp -f "$_odir/tree/${_f#./}" "$AOSP/${_f#./}"
    done
  fi

     # Validate any XML this option installs, before the build finds it. aapt2 reports a bare
     # "not well-formed (invalid token)" thousands of lines into a build log, and the usual cause is
     # a "--" inside an <!-- comment -->, which XML forbids and which is easy to type in prose.
     if [ -d "$_odir/tree" ] && command -v python3 >/dev/null 2>&1; then
       _xmlbad=0
       for _x in $(cd "$_odir/tree" && find . -name '*.xml' -type f); do
         python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$_odir/tree/${_x#./}" 2>/dev/null \
           || { echo "!! option $_oname: malformed XML in tree/${_x#./}" >&2
                echo "!! a '--' inside an XML comment is the usual cause; XML forbids it" >&2
                _xmlbad=1; }
       done
       [ "$_xmlbad" = 0 ] || { echo "!! refusing to build with malformed XML" >&2; exit 1; }
     fi
  if [ -f "$_odir/assets.list" ]; then
    while read -r op a b; do
      case "$op" in
        ''|'#'*) ;;
        copy) b="$(expand_dest "$b")" || exit 1
              mkdir -p "$AOSP/$(dirname "$b")"; cp -f "$_odir/assets/$a" "$AOSP/$b" || exit 1 ;;
        'copy?') if ! b="$(expand_dest "$b" 2>/dev/null)"; then
                   echo "   (skip $a -- destination not configured on this device)"; continue
                 fi
                 mkdir -p "$AOSP/$(dirname "$b")"; cp -f "$_odir/assets/$a" "$AOSP/$b" || exit 1 ;;
        rm)   rm -f "$AOSP/$(expand_dest "$a")" ;;
        *) echo "   !! unknown assets.list op '$op' in option $_oname"; exit 1 ;;
      esac
    done < "$_odir/assets.list"
  fi
  if [ -f "$_odir/product.mk" ]; then
    {
      echo "# ---- option: $_oname"
      echo "ifeq (\$($_osw),true)"
      grep -v '^#' "$_odir/product.mk" | sed '/^[[:space:]]*$/d'
      echo "endif"
      echo ""
    } >> "$GEN"
  fi
  _nopt=$((_nopt+1))
  echo "   option $_oname staged (gated by $_osw)"
done
echo ">> forge options: $_nopt staged into vendor/extra"

# ---- 3. optional default-wallpaper override ----
if [ -n "${CUSTOM_WALLPAPER_DST:-}" ] && [ -f "$DEVICE_REPO/custom-wallpaper.jpg" ]; then
  DEF_WP="$AOSP/$CUSTOM_WALLPAPER_DST"
  [ -f "$DEF_WP" ] && { cp -f "$DEVICE_REPO/custom-wallpaper.jpg" "$DEF_WP"; echo ">> using custom default wallpaper"; }
fi


# ---- 4b. kernel contributions from the enabled options ----------------------------------------
# Most options end up in product config. Some belong to the kernel instead -- `linux` needs
# namespace and cgroup support compiled in. Those declare KERNEL_CONFIGS / KERNEL_PATCHES in their
# option.conf, and they are folded into the same lists a device can set directly, so nothing
# downstream has to know an option was involved.
#
# Sub-switches stay device-level, because they only ever narrow what an option does and mean nothing
# on their own: WITH_LINUX_FHANDLE (dockerd wants CONFIG_FHANDLE, the V20's VINTF matrix forbids it)
# and WITH_LINUX_CGROUP_PATCH (the patch needs kernfs, so the Robin's 3.10 kernel cannot take it).
# Both accumulate below. Initialise them: under `set -u` the `${VAR# }` trims further down are a
# hard error on an unset name, and a device that skips every kernel patch (ether sets
# WITH_LINUX_CGROUP_PATCH=false) never assigns KERNEL_EXTRA_PATCHES at all.
KERNEL_EXTRA_CONFIGS="${KERNEL_EXTRA_CONFIGS:-}"
KERNEL_EXTRA_PATCHES="${KERNEL_EXTRA_PATCHES:-}"
# Patches an option declares OPTIONAL: skipped with a warning when they do not apply, rather than
# failing the build. Only for instrumentation that ships no product config -- a functional patch that
# silently does not apply is how a ROM goes out broken.
KERNEL_EXTRA_PATCHES_OPTIONAL="${KERNEL_EXTRA_PATCHES_OPTIONAL:-}"
for _o in ${BUILD_OPTIONS:-}; do
  _oc="$FORGE/options/$_o/option.conf"
  [ -f "$_oc" ] || continue
  ( : ) ; KERNEL_CONFIGS=""; KERNEL_PATCHES=""; KERNEL_PATCHES_OPTIONAL=""
  # shellcheck disable=SC1090
  source "$_oc"
  for _c in ${KERNEL_CONFIGS:-}; do
    [ "$_c" = container-fhandle ] && [ "${WITH_LINUX_FHANDLE:-true}" != true ] && continue
    case " ${KERNEL_EXTRA_CONFIGS:-} " in *" $_c "*) ;; *) KERNEL_EXTRA_CONFIGS="${KERNEL_EXTRA_CONFIGS:-} $_c" ;; esac
  done
  for _p in ${KERNEL_PATCHES:-}; do
    [ "$_p" = cgroup-noprefix-symlinks ] && [ "${WITH_LINUX_CGROUP_PATCH:-true}" != true ] && continue
    case " ${KERNEL_EXTRA_PATCHES:-} " in *" $_p "*) ;; *) KERNEL_EXTRA_PATCHES="${KERNEL_EXTRA_PATCHES:-} $_p" ;; esac
  done
  for _p in ${KERNEL_PATCHES_OPTIONAL:-}; do
    case " ${KERNEL_EXTRA_PATCHES_OPTIONAL:-} " in *" $_p "*) ;; *) KERNEL_EXTRA_PATCHES_OPTIONAL="${KERNEL_EXTRA_PATCHES_OPTIONAL:-} $_p" ;; esac
  done
done
# container-fhandle rides with `linux` but is its own fragment, so a device can drop just that one.
for _o in ${BUILD_OPTIONS:-}; do
  [ "$_o" = linux ] || continue
  if [ "${WITH_LINUX_FHANDLE:-true}" = true ]; then
    case " ${KERNEL_EXTRA_CONFIGS:-} " in
      *" container-fhandle "*) ;;
      *) KERNEL_EXTRA_CONFIGS="${KERNEL_EXTRA_CONFIGS:-} container-fhandle" ;;
    esac
  fi
done
[ -n "$KERNEL_EXTRA_CONFIGS$KERNEL_EXTRA_PATCHES" ] && \
  echo ">> kernel: configs:'${KERNEL_EXTRA_CONFIGS# }' patches:'${KERNEL_EXTRA_PATCHES# }'"

# Resolve the BoardConfig that owns the kernel. It is NOT always under device/$DEVICE: on the V20
# DEVICE=lge/vs995 but TARGET_KERNEL_SOURCE is declared in device/lge/msm8996-common. Search the
# device dir first, then its vendor dir. Every grep is `|| true`-guarded: under `set -e` + pipefail
# a no-match returns 1 and kills the script *silently*, before any error message can print.
_find_kernel_boardconfig() {
  local hit=""
  hit="$(grep -rl '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=' "$AOSP/device/$DEVICE" 2>/dev/null | head -1 || true)"
  if [ -z "$hit" ]; then
    hit="$(grep -rl '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=' "$AOSP/device/${DEVICE%%/*}" 2>/dev/null | head -1 || true)"
  fi
  printf '%s' "$hit"
}

# ---- 5. extra kernel config fragments (KERNEL_EXTRA_CONFIGS in device.conf) ----
# LineageOS kernel.mk merges TARGET_KERNEL_CONFIG as a LIST: the first entry is the base defconfig
# and the rest are merged over it as fragments. That works on every branch built here.
#
# Do NOT use TARGET_KERNEL_CONFIG_EXT (absolute paths): it only exists on lineage-23.0. On 22.2 and
# 19.1 kernel.mk never references KERNEL_DEFCONFIG_EXT, so the fragment is accepted, reported as
# applied, and silently ignored -- which is exactly what happened to the V20 on 2026-09-05.
# Instead copy the fragment into the kernel's own configs dir and append it by name.
for _frag in ${KERNEL_EXTRA_CONFIGS:-}; do
  _src="$FORGE/kernel-configs/$_frag.config"
  [ -f "$_src" ] || { echo "!! KERNEL_EXTRA_CONFIGS: no such fragment: $_src"; exit 1; }
  _bc="$(_find_kernel_boardconfig)"
  [ -n "$_bc" ] || { echo "!! KERNEL_EXTRA_CONFIGS: no BoardConfig defines TARGET_KERNEL_SOURCE under device/$DEVICE"; exit 1; }
  _ksrc="$(grep -hoP '^\s*TARGET_KERNEL_SOURCE\s*:?=\s*\K\S+' "$_bc" 2>/dev/null | head -1 || true)"
  [ -n "$_ksrc" ] && [ -d "$AOSP/$_ksrc" ] || { echo "!! KERNEL_EXTRA_CONFIGS: cannot resolve kernel source ('$_ksrc')"; exit 1; }
  # Which arch/<a>/configs holds this kernel's defconfigs? Derive it rather than assuming arm64.
  _base="$(grep -hoP '^\s*TARGET_KERNEL_CONFIG\s*:?=\s*\K\S+' "$_bc" 2>/dev/null | head -1 || true)"
  _cfgdir=""
  for _a in arm64 arm x86 x86_64; do
    if [ -n "$_base" ] && [ -f "$AOSP/$_ksrc/arch/$_a/configs/$_base" ]; then _cfgdir="$AOSP/$_ksrc/arch/$_a/configs"; break; fi
  done
  [ -n "$_cfgdir" ] || for _a in arm64 arm x86 x86_64; do
    [ -d "$AOSP/$_ksrc/arch/$_a/configs" ] && { _cfgdir="$AOSP/$_ksrc/arch/$_a/configs"; break; }
  done
  [ -n "$_cfgdir" ] || { echo "!! KERNEL_EXTRA_CONFIGS: no arch/*/configs dir under $_ksrc"; exit 1; }
  # How the fragment gets merged depends on the kernel. `make foo.config` (scripts/kconfig's
  # %.config rule) exists on 3.18+ but NOT on 3.10 -- ether fails there with
  #   make[2]: *** No rule to make target 'forge_container.config'.  Stop.
  # So use the fragment-as-target path where supported (the fragment goes last, so it wins), and otherwise
  # append the options to the base defconfig, which every kconfig honours (later assignments
  # override earlier ones; kconfig just prints "override: reassigning", as it already does for
  # these device trees).
  if grep -q '^%\.config:' "$AOSP/$_ksrc/scripts/kconfig/Makefile" 2>/dev/null; then
    cp "$_src" "$_cfgdir/forge_$_frag.config"
    if grep -q "forge_$_frag.config" "$_bc"; then
      echo ">> kernel fragment '$_frag' already wired into ${_bc#$AOSP/}"
    else
      {
        echo ""
        echo "# added by rom-forge (KERNEL_EXTRA_CONFIGS=$_frag) -- merged over the base defconfig"
        echo "TARGET_KERNEL_CONFIG += forge_$_frag.config"
      } >> "$_bc"
      echo ">> kernel fragment '$_frag' -> ${_cfgdir#$AOSP/}/forge_$_frag.config + ${_bc#$AOSP/}"
    fi
  else
    _basecfg="$_cfgdir/$_base"
    [ -f "$_basecfg" ] || { echo "!! KERNEL_EXTRA_CONFIGS: base defconfig not found: $_basecfg"; exit 1; }
    if grep -q "rom-forge:$_frag" "$_basecfg"; then
      echo ">> kernel fragment '$_frag' already appended to ${_basecfg#$AOSP/}"
    else
      {
        echo "# --- rom-forge:$_frag (this kernel has no %.config rule, so the fragment is appended) ---"
        grep -E '^(CONFIG_|# CONFIG_)' "$_src"
      } >> "$_basecfg"
      echo ">> kernel fragment '$_frag' appended to ${_basecfg#$AOSP/} (no %.config support)"
    fi
  fi
done

# ---- 6. extra kernel patches (KERNEL_EXTRA_PATCHES in device.conf) ----
# Generic kernel fixes that live in forge rather than per-device overlay/patches, because the same
# patch applies to several devices. Applied with `git apply` (GNU patch rejects these hunks even
# when the context matches byte-for-byte). Idempotent: a patch already applied is skipped.
for _kp in ${KERNEL_EXTRA_PATCHES:-}; do
  _p="$FORGE/kernel-patches/$_kp.patch"
  [ -f "$_p" ] || { echo "!! KERNEL_EXTRA_PATCHES: no such patch: $_p"; exit 1; }
  _kbc="$(_find_kernel_boardconfig)"
  _ksrc="$(grep -hoP '^\s*TARGET_KERNEL_SOURCE\s*:?=\s*\K\S+' "$_kbc" 2>/dev/null | head -1 || true)"
  if [ -z "$_ksrc" ] || [ ! -d "$AOSP/$_ksrc" ]; then
    echo "!! KERNEL_EXTRA_PATCHES: could not resolve TARGET_KERNEL_SOURCE under device/$DEVICE"; exit 1
  fi
  if ( cd "$AOSP/$_ksrc" && git apply --reverse --check "$_p" >/dev/null 2>&1 ); then
    echo ">> kernel patch '$_kp' already applied in $_ksrc"
  elif ( cd "$AOSP/$_ksrc" && git apply "$_p" 2>/dev/null ); then
    echo ">> kernel patch '$_kp' -> $_ksrc"
  else
    case " ${KERNEL_EXTRA_PATCHES_OPTIONAL:-} " in
      *" $_kp "*)
        echo "!! kernel patch '$_kp' does NOT apply to $_ksrc -- SKIPPED (declared optional)"
        echo "   Whatever it instruments is absent from this build, which is the option's whole"
        echo "   purpose, so treat the option as off. See forge/kernel-patches/$_kp.patch for the"
        echo "   kernels it targets."
        ;;
      *)
        echo "!! kernel patch '$_kp' does NOT apply to $_ksrc -- refusing to continue"
        echo "   (kernels differ; see forge/kernel-patches/$_kp.patch for which versions it targets)"
        exit 1
        ;;
    esac
  fi
done

echo ">> overlay applied."
# NB: must not be a trailing `[ ... ] && echo` -- an AND-list whose test fails is the script's exit
# status, so an unset pack made this script return 1 after succeeding, failing the apply phase.
case "${OEM_ASSET_PACK:-none}" in
  nextbit-robin) echo "   (optional) OEM assets: forge/tools/extract-nextbit-oem-assets.sh <stock-rom.zip> $AOSP" ;;
esac
exit 0
