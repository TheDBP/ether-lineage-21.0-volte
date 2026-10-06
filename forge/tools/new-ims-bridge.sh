#!/usr/bin/env bash
# new-ims-bridge.sh -- instantiate the compat-ImsService bridge (templates/ims-bridge) that presents an
# OEM's legacy com.android.ims (Android 7.x API) IMS app to the modern telephony stack as an MMTel
# ImsService. The Java is the generic part of every such port (Robin/QTI ims.apk on 13, V20/LG Ims4 on
# 17); the per-device parts are the renamed legacy package the reworked app now speaks, the OEM's AIDL
# (gen-legacy-aidl.py) and any OEM wire extension to the parcelables.
#
#   new-ims-bridge.sh <out-dir> --legacy-pkg <pkg> --oem-app <Name> --device <codename> [--restrict-cause]
#   new-ims-bridge.sh device/lge/msm8996-common/ims/bridge --legacy-pkg com.lge.imslegacy \
#       --oem-app Ims4 --device vs995 --restrict-cause
#
#   --legacy-pkg      the private package merge-legacy-classes.py renamed com.android.ims to; the AIDL
#                     from gen-legacy-aidl.py (LEGACY_PKG) must use the same one
#   --oem-app         the OEM IMS app's module name (comments/log lines only)
#   --device          codename; names the config-probe property persist.<device>.ims.configprobe
#   --restrict-cause  the OEM's ImsCallProfile.writeToParcel appends restrictCause after mediaProfile
#                     (LG does; AOSP 7.x does not). Read the stock parcelable's smali before deciding:
#                     a wrong answer does not throw, it shifts every later field by one.
#
# Afterwards (the build script does these, see docs/debugging-volte.md "Rework"):
#   1. gen-legacy-aidl.py <deodex> <out-dir>/aidl   -> <out-dir>/aidl/<legacy/pkg/path>/{,internal/}*.aidl
#      (commit the generated .aidl; the ROM build compiles it). Compare the result with the stock
#      $Stub tables: aidl-tx-diff.py <stub-smali-dir> <out-dir>/aidl/<legacy/pkg/path>/internal
#   2. Device wiring: PRODUCT_PACKAGES += ImsBridge android.hardware.telephony.ims.prebuilt.xml;
#      overlay packages/services/Telephony config_ims_mmtel_package = org.lineageos.ims.bridge;
#      PRODUCT_PROPERTY_OVERRIDES += ro.telephony.block_binder_thread_on_incoming_calls=false.
#   3. Diff each src/<legacy>/*.java parcelable's write order against the stock smali writeToParcel.
#   4. PATCH THE FRAMEWORK FIRST. Binding ANY compat ImsService on 17 restart-loops com.android.phone:
#      ImsServiceControllerCompat never calls setDefaultExecutor(), so the adapter NPEs on
#      CompletableFuture.screenExecutor. An AOSP bug, not yours. See debugging-volte.md "Bridge the
#      reworked app" -- without it the first boot after wiring the bridge in is a boot loop.
#   5. sepolicy: a service type + service_contexts entry per binder the OEM stack publishes, and a
#      property type for its prop prefixes (a coredomain may only set a system_property_type).
#      Expect to need it even to get a permissive boot's audit to be meaningful.
#   6. The OEM's own sec_config usually omits the QMI service its IMS stack needs, and the symptom is
#      a call that connects with no audio -- run qmi-sec-check.sh. Rules bind at service REGISTRATION,
#      so this must be in the image at boot; running irsc_util afterwards does nothing.
# Re-running on an existing out-dir refuses unless --force (it would overwrite local edits).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); T=$HERE/templates/ims-bridge
OUT=; PKG=; APP=; DEV=; RC=false; FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --legacy-pkg) PKG=$2; shift 2;; --oem-app) APP=$2; shift 2;; --device) DEV=$2; shift 2;;
  --restrict-cause) RC=true; shift;; --force) FORCE=1; shift;;
  -h|--help) sed -n '2,30p' "$0"; exit 0;;
  -*) echo "!! unknown option $1"; exit 2;; *) OUT=$1; shift;; esac; done
[ -n "$OUT" ] && [ -n "$PKG" ] && [ -n "$APP" ] && [ -n "$DEV" ] || { sed -n '2,30p' "$0"; exit 2; }
[[ "$PKG" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]] || { echo "!! --legacy-pkg must be a java package (a.b.c)"; exit 2; }
if [ -e "$OUT/Android.bp" ] && [ $FORCE = 0 ]; then echo "!! $OUT already holds a bridge; --force to overwrite"; exit 1; fi
PATHP=${PKG//.//}
mkdir -p "$OUT/src/$PATHP" "$OUT/aidl"
cp -r "$T/Android.bp" "$T/AndroidManifest.xml" "$OUT/"; cp -r "$T/aidl/." "$OUT/aidl/"; cp -r "$T/src/." "$OUT/src/"
cp "$T"/src-legacy/*.java "$OUT/src/$PATHP/"
grep -rl '@[A-Z_]*@' "$OUT" | xargs sed -i "s/@LEGACY_PKG@/$PKG/g; s/@OEM_APP@/$APP/g; s/@DEVICE@/$DEV/g; s/@RESTRICT_CAUSE@/$RC/g"
left=$(grep -rn '@[A-Z_]*@' "$OUT" || true); [ -z "$left" ] || { echo "!! unexpanded placeholders:"; echo "$left"; exit 1; }
echo ">> bridge written to $OUT (legacy pkg $PKG, app $APP, restrictCause=$RC)"
echo "   next: gen-legacy-aidl.py <deodex> $OUT/aidl   (LEGACY_PKG=$PKG), then aidl-tx-diff.py against the stock \$Stub smali"
