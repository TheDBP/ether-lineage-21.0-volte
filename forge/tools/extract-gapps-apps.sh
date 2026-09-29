#!/bin/bash
# extract-gapps-apps.sh — pull the Google versions of the stock apps out of a GApps zip and stage
# them as /product prebuilts, so a WITH_GAPPS build swaps the Lineage/AOSP apps for Google's.
#
#   ./extract-gapps-apps.sh <GApps.zip> [AOSP_ROOT]
#
# Works with a flat GApps zip (MindTheGapps-style: bare APKs) OR a nested one (NikGApps-style: each
# app inside a .tar.xz / .xz). Apps are matched by PACKAGE NAME via aapt2, so the zip's internal
# layout doesn't matter. The APKs are PROPRIETARY (Google) — extracted from YOUR zip, gitignored,
# never committed. AOSP_ROOT defaults to /aosp. Idempotent. Runs in-container (aapt2 + xz live there).
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

ZIP="${1:?usage: extract-gapps-apps.sh <GApps.zip|URL> [AOSP_ROOT]}"
AOSP="${2:-/aosp}"
_SELF_REPO="$(cd "$(dirname "$0")/../.." && pwd)"; [ -f "$_SELF_REPO/device.conf" ] && source "$_SELF_REPO/device.conf"
: "${DEVICE:?device.conf missing or DEVICE unset}"
DEV="$AOSP/device/$DEVICE"
# Staged into vendor/extra, not the device tree, so the gapps option is the same on every device
# and needs no device patch to be included. It also sidesteps a real trap: from Android 16
# (lineage-23.0) build/soong/ui/build/androidmk_denylist.go rejects Android.mk under device/google/,
# device/generic/, device/common/ and others, failing lunch outright -- these prebuilts used to live
# exactly there.
OUT="$AOSP/vendor/extra/gapps-extras"
GAPPS_EXTRAS_REL="vendor/extra/gapps-extras"

[ -d "$DEV" ] || { echo "!! $DEVICE device tree not found under $AOSP"; exit 1; }
AAPT2="$(command -v aapt2 || echo "$AOSP/prebuilts/sdk/tools/linux/bin/aapt2")"
[ -x "$AAPT2" ] || { echo "!! aapt2 not found (need it to match APKs by package)"; exit 1; }

# module : package : privileged? : Lineage/AOSP module(s) it replaces (LOCAL_OVERRIDES_PACKAGES).
# Phone needs priv-app to be the default dialer; Messages works as default SMS from /product/app.
# Camera is intentionally NOT swapped. "-" = nothing to override (Lineage ships no Files app).
# NOTE: Chrome is intentionally NOT swapped here — NikGapps ships it as a dex-less stub, and we
# replace the browser with Firefox (Fennec F-Droid) instead, a real APK (see prebuilt/fetch-firefox.sh
# + the WITH_GAPPS Firefox prebuilt in device.mk). Firefox is what overrides Jelly + is the default.
TARGETS="
GoogleCalculator:com.google.android.calculator:0:ExactCalculator
GoogleCalendar:com.google.android.calendar:0:Etar
GoogleClock:com.google.android.deskclock:0:DeskClock
GoogleContacts:com.google.android.contacts:0:Contacts
GoogleFiles:com.google.android.apps.nbu.files:0:-
GoogleMessages:com.google.android.apps.messaging:0:messaging Messaging
GooglePhone:com.google.android.dialer:1:Dialer
"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# $1 may be a local path OR an http(s) URL — if a URL, fetch it here (in-container) so nothing
# platform-specific runs on the host. SourceForge /download links redirect to a mirror; -L follows.
case "$ZIP" in
  http://*|https://*)
    echo ">> downloading GApps package (in-container)"
    curl -fSL -o "$TMP/pkg.zip" "$ZIP" || { echo "!! GApps download failed: $ZIP" >&2; exit 1; }
    ZIP="$TMP/pkg.zip" ;;
esac
[ -f "$ZIP" ] || { echo "!! GApps zip not found: $ZIP" >&2; exit 1; }
echo ">> unpacking $(basename "$ZIP")"
unzip -qo "$ZIP" -d "$TMP/z" || true
# NikGApps and friends nest each app inside an archive — unpack any we find so the APKs surface.
find "$TMP/z" -name '*.tar.xz' -exec tar -xf {} -C "$TMP/z" \; 2>/dev/null || true
find "$TMP/z" -name '*.tar.lz' -exec sh -c 'lzip -dc "$1" | tar -x -C "'"$TMP"'/z"' _ {} \; 2>/dev/null || true
find "$TMP/z" -name '*.xz' ! -name '*.tar.xz' -exec xz -dk {} \; 2>/dev/null || true
# NikGapps (2024) nests each app as a plain .zip (AppSet/<App>/<App>.zip -> ___*___/<App>.apk).
# Snapshot the list FIRST so zips we extract aren't re-discovered; `unzip -d` only creates the last
# path component, so mkdir -p the target — without it every nested unpack silently fails to "0 APKs".
find "$TMP/z" -name '*.zip' > "$TMP/nested-zips.txt" 2>/dev/null || true
nzi=0
while IFS= read -r z; do
  [ -e "$z" ] || continue
  d="$TMP/z/nested/$nzi"; mkdir -p "$d"
  unzip -qo "$z" -d "$d" 2>/dev/null || true
  nzi=$((nzi + 1))
done < "$TMP/nested-zips.txt"

# Index every APK we can see by its package name (once).
echo ">> indexing APKs by package"
INDEX="$TMP/index.txt"; : > "$INDEX"
while IFS= read -r -d '' apk; do
  pkg="$("$AAPT2" dump packagename "$apk" 2>/dev/null)" || pkg=""
  [ -n "$pkg" ] && echo "$pkg|$apk" >> "$INDEX"
done < <(find "$TMP/z" -name '*.apk' -print0)
echo "   found $(wc -l < "$INDEX") APK(s) in the zip"

rm -rf "$OUT"/*/ 2>/dev/null || true          # clear old extracted apps (keep .gitignore + Android.mk)
# Sweep the old device-tree location. Before this option existed these prebuilts were staged into
# device/<vendor>/<codename>/gapps-extras, and a tree that has been built once still has them there.
# Leaving them would be two copies of every Google app in the tree, with only the removal of one
# -include line deciding which set the build uses -- and a stale set is indistinguishable from a
# fresh one by looking at it.
if [ -d "$DEV/gapps-extras" ]; then
  echo ">> removing the old $DEVICE/gapps-extras staging (moved to $GAPPS_EXTRAS_REL)"
  rm -rf "$DEV/gapps-extras"
fi

mkdir -p "$OUT"
: > "$OUT/packages.mk"
# Does this tree's Soong accept `preprocessed` on android_app_import? Added around Android 13; on
# older trees the identifier exists only in androidTestImportProperties, and passing it to an
# android_app_import is a hard build failure rather than a no-op. Probe the actual properties struct
# so this tracks the tree instead of a hardcoded version boundary.
PREPROCESSED_OK=0
_app_import_go="$AOSP/build/soong/java/app_import.go"
if [ -f "$_app_import_go" ] && awk '/^type AndroidAppImportProperties struct/{f=1; next} f&&/^}/{exit} f&&/Preprocessed \*bool/{print "yes"; exit}' "$_app_import_go" | grep -q yes; then
  PREPROCESSED_OK=1
fi
echo "   soong android_app_import 'preprocessed' supported: $([ "$PREPROCESSED_OK" = 1 ] && echo yes || echo no)"

echo "# generated by extract-gapps-apps.sh — the Google apps this build swaps in (WITH_GAPPS)" >> "$OUT/packages.mk"
echo "PRODUCT_PACKAGES += \\" >> "$OUT/packages.mk"

missing=""
while IFS=: read -r mod pkg priv override; do
  [ -n "$mod" ] || continue
  apk="$(awk -F'|' -v p="$pkg" '$1==p{print $2; exit}' "$INDEX")"
  if [ -z "$apk" ]; then missing="$missing $mod($pkg)"; continue; fi
  ov=""; [ "$override" != "-" ] && ov="$override"     # Lineage module(s) this Google app replaces
  moddir="$OUT/$mod"; mkdir -p "$moddir"
  cp -f "$apk" "$moddir/$mod.apk"
  # A privileged app MUST ship a privapp-permissions allowlist. Without one PackageManagerService
  # refuses to boot rather than silently granting signature|privileged permissions:
  #   FATAL EXCEPTION IN SYSTEM PROCESS: main
  #   java.lang.IllegalStateException: Signature|privileged permissions not in privapp-permissions
  #   allowlist: {com.google.android.dialer (/system/product/priv-app/GooglePhone):
  #              android.permission.MODIFY_PHONE_STATE, ...}
  #     at PermissionManagerService.systemReady(PermissionManagerService.java:4595)
  # system_server dies, zygote restarts, and the device replays the boot animation forever with no
  # crash dialog and no reboot -- ether/lineage-19.1 and bonito/lineage-22.2 both hung exactly here.
  # NikGapps ships the allowlist beside the APK as ___etc___permissions/<pkg>.xml; take it as well.
  if [ "$priv" = 1 ]; then
    _pdir="$(dirname "$(dirname "$apk")")"
    _perm="$_pdir/___etc___permissions/$pkg.xml"
    [ -f "$_perm" ] || _perm="$(find "$_pdir" -name "$pkg.xml" -path '*permission*' 2>/dev/null | head -1)"
    if [ -n "$_perm" ] && [ -f "$_perm" ]; then
      mkdir -p "$OUT/permissions"; cp -f "$_perm" "$OUT/permissions/$pkg.xml"
      echo "   + privapp allowlist: $pkg.xml ($(grep -c '<permission ' "$_perm" 2>/dev/null || echo ?) permissions)"
    else
      echo "!! $mod is privileged but no privapp-permissions XML was found next to its APK." >&2
      echo "!! Shipping it would hang the device on the boot animation. Failing instead." >&2
      exit 1
    fi
  fi
  # A dex-less "stub" (NikGapps ships Chrome/Files as tiny stubs Play fills in on first sign-in) can't
  # be dexpreopt'd (dex2oat: "No dex files in zip"), and must NOT override its Lineage counterpart —
  # else the ROM ships with no working app until Play downloads the payload (needs net + a Google
  # account). Detect by absence of classes*.dex: disable preopt and keep the Lineage app.
  stub=0
  # capture-then-count: `grep -q` exits early -> unzip SIGPIPEs -> pipefail flags EVERY app a stub
  # (which would keep every Lineage app AND ship its Google dup — two dialers/SMS/etc).
  if [ "$(unzip -l "$moddir/$mod.apk" 2>/dev/null | grep -cE 'classes[0-9]*\.dex' || true)" -eq 0 ]; then stub=1; ov=""; fi
    # Android.bp, NOT Android.mk. build/soong/ui/build/androidmk_denylist.go blocks Android.mk under
    # device/google/, device/generic/, device/common/ and more from Android 16 (lineage-23.0):
    #   Found blocked Android.mk file: device/google/bonito/gapps-extras/GoogleCalculator/Android.mk
    # which fails lunch outright. android_app_import is the Soong equivalent and predates Android 10,
    # so it works on every branch we build -- emit it unconditionally rather than per-branch.
    {
      echo "// generated by extract-gapps-apps.sh -- do not edit"
      echo "android_app_import {"
      echo "    name: \"$mod\","
      echo "    apk: \"$mod.apk\","
      echo "    presigned: true,"
      # preprocessed: the APK ships already signed and zipaligned, so Soong must copy it verbatim.
      # Required from Android 15 (lineage-22.2): build/soong/scripts/check_prebuilt_presigned_apk.py
      # rejects a presigned prebuilt whose targetSdkVersion >= 30 without it --
      #   Prebuilt, presigned apks with targetSdkVersion >= 30 ... must set preprocessed: true
      #   in the Android.bp definition (because they must be zipaligned with -p)
      #
      # But it is NOT simply ignored on older branches: Soong rejects unknown properties outright,
      # and on lineage-19.1 (Android 12.1) the whole build dies with
      #   error: .../GoogleClock/Android.bp:6:17: unrecognized property "preprocessed"
      # There, Preprocessed exists only on android_test_import, not android_app_import. So ask the
      # tree rather than assuming a version cutoff -- see PREPROCESSED_OK above.
      if [ "$PREPROCESSED_OK" = 1 ]; then echo "    preprocessed: true,"; fi
      echo "    product_specific: true,"
      if [ "$priv" = 1 ]; then echo "    privileged: true,"; fi
      if [ "$stub" = 1 ]; then echo "    dex_preopt: { enabled: false },"; fi
        # <uses-library>: these are presigned vendor prebuilts, and manifest_check compares the
        # manifest against the dexpreopt class-loader context -- which for an android_app_import
        # stays empty even when optional_uses_libs is set correctly (the deps do not resolve into
        # it), so the check fails no matter what we declare:
        #   error: mismatch in the <uses-library> tags between the build system and the manifest
        #     optional libraries in build system: [] vs. in the manifest: [org.apache.http.legacy]
        # Declaring the REQUIRED ones is worse still: they become hard Soong deps on modules that
        # live in a GApps namespace the device may not import (GooglePhone ->
        # com.google.android.dialer.support in vendor/gapps/common).
        # So skip the check per-module. This is NOT RELAX_USES_LIBRARY_CHECK, which is global.
        echo "    enforce_uses_libs: false,"
        if [ -n "$ov" ]; then
          printf '    overrides: ['
          first=1; for o in $ov; do [ "$first" = 1 ] || printf ', '; printf '"%s"' "$o"; first=0; done
          echo '],'
        fi
      echo "}"
    } > "$moddir/Android.bp"
    rm -f "$moddir/Android.mk"
  echo "    $mod \\" >> "$OUT/packages.mk"
  echo "   + $mod  ($pkg)$([ "$priv" = 1 ] && echo '  [priv-app]')$([ "$stub" = 1 ] && echo '  [stub -> keep Lineage]')$([ -n "$ov" ] && echo "  overrides: $ov")"
done <<EOF
$TARGETS
EOF
echo "" >> "$OUT/packages.mk"

# Install the allowlists gathered above, so they land in /product/etc/permissions where
# PackageManagerService looks for them. Paths are written in full rather than as $(LOCAL_PATH):
# packages.mk is now -include'd from vendor/extra/product.mk, so LOCAL_PATH would no longer be
# the device directory -- and it would still expand to something, just to the wrong place.
if [ -d "$OUT/permissions" ] && [ -n "$(ls -A "$OUT/permissions" 2>/dev/null)" ]; then
  {
    echo "# privapp-permissions allowlists for the privileged apps above -- without these"
    echo "# PackageManagerService throws at systemReady() and the device never finishes booting."
    echo "PRODUCT_COPY_FILES += \\"
    _first=1
    for _x in "$OUT"/permissions/*.xml; do
      _b="$(basename "$_x")"
      [ "$_first" = 1 ] || echo " \\"
      printf '    %s/permissions/%s:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/%s' "$GAPPS_EXTRAS_REL" "$_b" "$_b"
      _first=0
    done
    echo ""
    echo ""
  } >> "$OUT/packages.mk"
fi

# Missing apps aren't fatal (LOCAL_OVERRIDES only fires for apps present, so the Lineage counterpart
# is simply kept) — but a zip with NONE of them is the wrong package.
[ -n "$missing" ] && echo ">> note: not in this GApps zip, kept the Lineage version:$missing"
found=$(find "$OUT" -mindepth 2 -name '*.apk' 2>/dev/null | wc -l)
if [ "$found" -eq 0 ]; then
  echo "!! none of the target Google apps were found in $ZIP — wrong/incomplete GApps package? Failing." >&2
  exit 1
fi
echo ">> done: staged $found Google app(s). WITH_GAPPS builds swap these in + set the defaults."
