#!/usr/bin/env bash
# lib-app-checks.sh — the require.sh / post-build.sh checks shared by every option that bundles a
# fetched, presigned APK (k9, kdeconnect, termoneplus, firefox, fdroid, nextcloud). Source it; then:
#
#   app_require OPT DIR MOD...      before the build
#   app_post_build OPT DIR MOD...   after it
#
# DIR is the option's vendor/lineage/prebuilts/<opt>, or -- on a branch where the option has no
# vendor/lineage patch and the module is a device-tree one (ether 20.0 firefox/fdroid) -- that
# device directory, which post-patch.sh has already populated. Each module MOD is DIR/MOD.apk or
# DIR/MOD/MOD.apk. Native libraries the fetcher unpacked sit in DIR/lib/arm64-v8a/ (one-app
# options) or DIR/MOD/lib/arm64-v8a/ (bundles).
#
# require: every APK present (each module is guarded on its APK, so a missing one is a silently
# smaller image, not an error); the module file present and naming every module (Android.mk from
# the 20.0 patch, or the Android.bp the fetcher writes on Soong branches -- a stale one is a
# lunch-time error at best and a silently absent app at worst); on 20.0, the build/make patch that
# makes check-jni-dex-compression a warning (BUILD_PREBUILT's do_not_alter_apk path otherwise fails
# on compressed dex, at minute ~200).
#
# post-build: every shipped APK byte-identical to the fetched one -- any rewrite (uncompressing libs
# or dex, re-aligning) invalidates the whole-file v2 signature, and PackageManager then skips the
# package at boot scan without logging; every unpacked library installed beside its APK as
# <app>/lib/arm64/<lib>.so, or the app dies at launch in UnsatisfiedLinkError.
set -o pipefail

_app_apk() {  # DIR MOD -> the APK, flat or in its own subdirectory
  if [ -f "$1/$2.apk" ]; then echo "$1/$2.apk"; else echo "$1/$2/$2.apk"; fi
}

_app_libdir() {  # DIR MOD -> where the fetcher unpacked this module's libraries, if anywhere
  [ -d "$1/$2/lib/arm64-v8a" ] && { echo "$1/$2/lib/arm64-v8a"; return; }
  [ -d "$1/lib/arm64-v8a" ] && echo "$1/lib/arm64-v8a"
}

app_require() {
  local opt="$1" dir="$2" mod modfile missing=""; shift 2
  for mod in "$@"; do [ -f "$(_app_apk "$dir" "$mod")" ] || missing="$missing $mod"; done
  [ -z "$missing" ] || {
    echo "!! $opt: missing in ${dir#"$AOSP"/}:$missing" >&2
    echo "!!     each module is guarded on its APK, so the build would ship without it. Run the option's" >&2
    echo "!!     fetch.sh (bootstrap does)." >&2
    return 1
  }
  modfile="$dir/Android.mk"; [ -f "$modfile" ] || modfile="$dir/Android.bp"
  [ -f "$modfile" ] || { echo "!! $opt: no module file in ${dir#"$AOSP"/} (Android.mk from the patch, or Android.bp from the fetch)" >&2; return 1; }
  for mod in "$@"; do
    grep -q "$mod" "$modfile" || { echo "!! $opt: $modfile does not name $mod -- stale; re-run the option's fetch.sh" >&2; return 1; }
  done
  case "${BRANCH:-}" in
    lineage-20.0)
      grep -q 'presigned, shipped as-is' "$AOSP/build/make/core/definitions.mk" 2>/dev/null || {
        echo "!! $opt: on $BRANCH the verbatim-copy path needs the build/make patch that turns" >&2
        echo "!!     check-jni-dex-compression into a warning. Not applied." >&2
        return 1
      } ;;
  esac
  echo "   $opt: $# APK(s) present, modules in $(basename "$modfile")"
}

app_post_build() {
  local opt="$1" dir="$2" mod src apk lib libdir rc=0; shift 2
  local out="$AOSP/out/target/product/${DEVICE_CODENAME:?DEVICE_CODENAME unset and device.conf not found}"
  for mod in "$@"; do
    src="$(_app_apk "$dir" "$mod")"
    apk="$(find "$out" -name "$mod.apk" -path '*app*' -not -path '*/obj/*' 2>/dev/null | head -1)"
    [ -n "$apk" ] || { echo "!! $opt: no $mod.apk in the built image"; rc=1; continue; }
    [ -f "$src" ] || { echo "   $opt: $mod: no fetched copy to compare against, skipping"; continue; }
    if ! cmp -s "$src" "$apk"; then
      echo "!! $opt: the build rewrote $mod.apk, so its signature no longer verifies."
      echo "!!   fetched: $(stat -c%s "$src") bytes   shipped: $(stat -c%s "$apk") bytes"
      echo "!! PackageManager will refuse it at boot scan and the app will simply be absent."
      rc=1; continue
    fi
    echo "   $opt: $mod shipped byte-identical to the fetched one -- signature intact"
    libdir="$(_app_libdir "$dir" "$mod")"
    for lib in "${libdir:-/nonexistent}"/*.so; do
      [ -f "$lib" ] || continue
      if cmp -s "$lib" "$(dirname "$apk")/lib/arm64/$(basename "$lib")"; then
        echo "   $opt: $mod: $(basename "$lib") installed beside it"
      else
        echo "!! $opt: $mod: $(basename "$lib") missing beside the APK -- it packs its libraries compressed and would not launch"
        rc=1
      fi
    done
  done
  return $rc
}
