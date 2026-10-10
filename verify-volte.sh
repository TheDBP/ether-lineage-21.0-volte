#!/usr/bin/env bash
# verify-volte.sh — check the VoLTE stack against the tree, the stock blobs and
# the bullhead reference. Prints PASS/FAIL per claim; exits non-zero if any fails.
#
#   ./verify-volte.sh [--inventory DIR] [--bullhead DIR]
#
# Defaults assume the layout VOLTE-BRINGUP.md describes: the extracted stock IMS blobs under
# $BUILD_ROOT/tmp/ims-inventory, and device_lge_bullhead under a sibling upstream-reference/.
#
# A checker that cannot fail is worth nothing: this one was negative-tested by pointing it at
# missing inputs, which is how C4d was found passing vacuously (an empty manifest dump has no
# intent-filter, so "has none" succeeded). It now requires the service element to exist first.
set -u
R="$(cd "$(dirname "$0")" && pwd)"
SRC="$R/build_output/src"
BUILD_ROOT="${BUILD_ROOT:-$R/build_output}"
W="${IMS_INVENTORY:-$BUILD_ROOT/tmp/ims-inventory}"
B="${BULLHEAD_DIR:-$(cd "$R/.." && pwd)/upstream-reference/device_lge_bullhead}"
while [ $# -gt 0 ]; do
  case "$1" in
    --inventory) W="$2"; shift 2 ;;
    --bullhead)  B="$2"; shift 2 ;;
    *) echo "!! unknown argument: $1" >&2; exit 2 ;;
  esac
done
# Checks C7 to C10 read the bullhead tree. Without it they simply fail, which looks like a broken
# port rather than a missing input, so say what to do instead of reporting ten failures.
if [ ! -d "$B/.git" ]; then
  cat >&2 <<EOM
!! bullhead reference not found at: $B
!!
!! Checks C7-C10 compare this port against LineageOS commit 5cef16f, which disabled the pre-P IMS
!! stack upstream. Clone it:
!!
!!   mkdir -p "$(dirname "$B")" && cd "$(dirname "$B")"
!!   git clone https://github.com/LineageOS/android_device_lge_bullhead.git device_lge_bullhead
!!
!! Or point at an existing checkout with --bullhead DIR (or BULLHEAD_DIR). See VOLTE-BRINGUP.md 6.1.
EOM
  exit 2
fi

A="$SRC/out/host/linux-x86/bin/aapt2"
MISSING="${IMS_MISSING:-$W/../ims-missing.txt}"
fail=0
ck(){ if [ "$2" = 1 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

# C1 transport
n=$(strings "$W/system/vendor/lib64/libril-qc-qmi-1.so" 2>/dev/null | grep -c 'qcril_qmi_ims_socket_agent')
ck "C1  libril-qc-qmi-1.so exports qcril_qmi_ims_socket_agent ($n)" "$([ "$n" -ge 3 ] && echo 1 || echo 0)"
z=$(unzip -l "$R/Ether_Stock_ROM_*.zip" 2>/dev/null | grep -ciE 'NON-HLOS|modem\.img')
ck "C1b no modem image in the stock zip (claim marked unverified)" "$([ "$z" -eq 0 ] && echo 1 || echo 0)"

# C2 inventory
miss=$(wc -l < $MISSING 2>/dev/null || echo 0)
ck "C2  58 IMS files absent from the vendor set ($miss)" "$([ "$miss" -eq 58 ] && echo 1 || echo 0)"
ent=$(grep -cvE '^\s*(#|$)' "$R/proprietary-files-ims.txt" 2>/dev/null || echo 0)
def_=$(grep -cE '^#(vendor/app|priv-app|framework)/' "$R/proprietary-files-ims.txt" 2>/dev/null || echo 0)
ck "C2b step-4 list has 53 active entries ($ent)"  "$([ "$ent" -eq 53 ] && echo 1 || echo 0)"
ck "C2c 15 deferred to steps 1-3 ($def_)"          "$([ "$def_" -eq 15 ] && echo 1 || echo 0)"

# C3 carrier config patch. Matched by slug, not number: the series gets renumbered whenever it is
# regrouped, and a stale number here silently checks the wrong patch.
p=$(ls "$R"/overlay/patches/device/nextbit/ether/*advertise-what-this-modem*.patch 2>/dev/null | head -1)
n=$(grep -ciE 'mcc310|mnc260|volte|ims' "$p" 2>/dev/null || echo 0)
ck "C3  the IMS capability patch carries the carrier config ($n lines)" "$([ -n "$p" ] && [ "$n" -ge 10 ] && echo 1 || echo 0)"

# C4 pre-P shape
m=$("$A" dump xmltree --file AndroidManifest.xml "$W/system/vendor/app/ims/ims.apk" 2>/dev/null)
ck "C4  package org.codeaurora.ims"        "$(echo "$m" | grep -qc 'package="org.codeaurora.ims"' >/dev/null && echo "$m" | grep -q 'package="org.codeaurora.ims"' && echo 1 || echo 0)"
ck "C4b service runs in com.android.phone" "$(echo "$m" | grep -q 'process(0x01010011)="com.android.phone"' && echo 1 || echo 0)"
ck "C4c sharedUserId android.uid.phone"    "$(echo "$m" | grep -q 'sharedUserId(0x0101000b)="android.uid.phone"' && echo 1 || echo 0)"
# must find the service element first, or "no intent-filter" passes vacuously on an empty dump
has_svc=$(echo "$m" | grep -c 'E: service')
svc=$(echo "$m" | awk '/E: service/{f=1} f&&/E: intent-filter/{print "HAS"; exit} f&&/E: receiver/{exit}')
ck "C4d service exists AND has no intent-filter" "$([ "$has_svc" -ge 1 ] && [ -z "$svc" ] && echo 1 || echo 0)"

# C5 pre-P registration surface
s=$(strings "$W/system/vendor/app/ims/oat/arm64/ims.odex" 2>/dev/null)
ck "C5  odex references IImsService"       "$(echo "$s" | grep -q 'com/android/ims/internal/IImsService' && echo 1 || echo 0)"

# C6 compat path alive on 13
ck "C6  compat ImsService in frameworks/base" "$([ -f "$SRC/frameworks/base/telephony/java/android/telephony/ims/compat/ImsService.java" ] && echo 1 || echo 0)"
ck "C6b ImsServiceControllerCompat in opt/telephony" "$([ -f "$SRC/frameworks/opt/telephony/src/java/com/android/internal/telephony/ims/ImsServiceControllerCompat.java" ] && echo 1 || echo 0)"
ck "C6c MmTelFeatureCompatAdapter in opt/telephony"  "$([ -f "$SRC/frameworks/opt/telephony/src/java/com/android/internal/telephony/ims/MmTelFeatureCompatAdapter.java" ] && echo 1 || echo 0)"
ck "C6d ImsResolver still scans compat"   "$(grep -q 'compat ImsService' "$SRC/frameworks/opt/telephony/src/java/com/android/internal/telephony/ims/ImsResolver.java" 2>/dev/null && echo 1 || echo 0)"

# C7 bullhead citation
ck "C7  bullhead 5cef16f exists"          "$(git -C "$B" show -s --format=%s 5cef16f 2>/dev/null | grep -q 'Disable pre-P IMS stack' && echo 1 || echo 0)"
ck "C7b it only changed the blobs list"   "$(git -C "$B" show --stat --format= 5cef16f 2>/dev/null | grep -q 'lineage-proprietary-blobs-vendor.txt' && echo 1 || echo 0)"

# C8/C9/C10 bullhead material
ck "C8  bullhead init defines imsqmidaemon" "$(grep -q '^service imsqmidaemon' "$B/init.bullhead.rc" 2>/dev/null && echo 1 || echo 0)"
ck "C8b property trigger QMI_DAEMON_STATUS" "$(grep -q 'sys.ims.QMI_DAEMON_STATUS=1' "$B/init.bullhead.rc" 2>/dev/null && echo 1 || echo 0)"
ck "C9  bullhead sepolicy/ims.te exists"    "$([ -f "$B/sepolicy/ims.te" ] && echo 1 || echo 0)"
ck "C9b ims_socket + qcom_ims_prop types"   "$(grep -q 'type ims_socket' "$B/sepolicy/file.te" 2>/dev/null && grep -q 'type qcom_ims_prop' "$B/sepolicy/property.te" 2>/dev/null && echo 1 || echo 0)"
ck "C10 Android.mk IMS_SYMLINKS"            "$(grep -q 'IMS_SYMLINKS' "$B/Android.mk" 2>/dev/null && echo 1 || echo 0)"


# ---------------------------------------------------------------- step 4: the stack we built
P18=$(ls "$R"/overlay/patches/device/nextbit/ether/*IMS-daemons-JNI-symlinks*.patch 2>/dev/null | head -1)
DT="$SRC/device/nextbit/ether"
RC="$DT/rootdir/init.target.rc"
ck "S1  the IMS daemons patch exported (rc + mk only)"                 "$([ -n "$P18" ] && echo 1 || echo 0)"
ck "S1b the IMS daemons patch has no local paths"       "$([ -s "$P18" ] && ! grep -qE '/home/|/media/Storage|NBQGLMB' "$P18" 2>/dev/null && echo 1 || echo 0)"

# the four daemons, from ether's own stock init -- not bullhead's two
for d in imsqmidaemon imsdatadaemon ims_rtp_daemon imscmservice; do
  ck "S2  init: service $d at /vendor/bin"   "$(grep -q "^service $d /vendor/bin/$d\$" "$RC" 2>/dev/null && echo 1 || echo 0)"
done
ck "S2b init: QMI_DAEMON_STATUS starts imsdatadaemon"  "$(grep -A1 'sys.ims.QMI_DAEMON_STATUS=1'  "$RC" 2>/dev/null | grep -q 'start imsdatadaemon'  && echo 1 || echo 0)"
ck "S2c init: DATA_DAEMON_STATUS starts ims_rtp_daemon" "$(grep -A1 'sys.ims.DATA_DAEMON_STATUS=1' "$RC" 2>/dev/null | grep -q 'start ims_rtp_daemon' && echo 1 || echo 0)"
ck "S2d init: the two chained daemons are disabled"    "$([ "$(awk '/^service (imsdatadaemon|ims_rtp_daemon) /{f=1} f&&/^ *disabled/{n++; f=0} END{print n+0}' "$RC" 2>/dev/null)" = 2 ] && echo 1 || echo 0)"

# sepolicy: device/qcom/sepolicy-legacy already carries the whole IMS policy. Declaring any of it
# again is a hard build failure ("Duplicate declaration of type"), so these assert ABSENCE on our
# side and PRESENCE on the legacy side.
QS="$SRC/device/qcom/sepolicy-legacy"
ck "S3  we ship no ims.te of our own"        "$([ ! -e "$DT/sepolicy/ims.te" ] && echo 1 || echo 0)"
ck "S3b we do not redeclare ims_socket"      "$([ -d "$DT/sepolicy" ] && ! grep -rqE '^[[:space:]]*type[[:space:]]+ims_socket' "$DT/sepolicy" 2>/dev/null && echo 1 || echo 0)"
ck "S3c we do not redeclare qcom_ims_prop"   "$([ -d "$DT/sepolicy" ] && ! grep -rqE '^[[:space:]]*type[[:space:]]+qcom_ims_prop' "$DT/sepolicy" 2>/dev/null && echo 1 || echo 0)"
ck "S3d legacy policy has the ims domain"    "$(grep -qE '^[[:space:]]*type[[:space:]]+ims,' "$QS/common/ims.te" 2>/dev/null && echo 1 || echo 0)"
ck "S3e legacy policy labels all 4 daemons"  "$([ "$(grep -rhE '/bin/(imsqmidaemon|imsdatadaemon|ims_rtp_daemon|imscmservice)[[:space:]]' "$QS"/*/file_contexts 2>/dev/null | wc -l)" -ge 4 ] && echo 1 || echo 0)"
ck "S3f legacy policy has sys.ims. context"  "$(grep -rq 'sys.ims.' "$QS"/*/property_contexts 2>/dev/null && echo 1 || echo 0)"
ck "S3g legacy grants set_prop(ims,...)"     "$(grep -q 'set_prop(ims, qcom_ims_prop)' "$QS/common/ims.te" 2>/dev/null && echo 1 || echo 0)"

# build wiring
ck "S4  device.mk includes vendor/ims-blobs/ims-blobs.mk" "$(grep -q 'include vendor/ims-blobs/ims-blobs.mk' "$DT/device.mk" 2>/dev/null && echo 1 || echo 0)"
# the tree and the PATCH must agree: an unstaged tree edit is replayed over at the next build, which
# is how the include kept pointing at vendor/extra while the tree looked right
ck "S4a the IMS daemons patch carries the same path"    "$([ -s "$P18" ] && grep -q '^+.*include vendor/ims-blobs/ims-blobs.mk' "$P18" 2>/dev/null && echo 1 || echo 0)"
ck "S4b the IMS daemons patch does NOT mention vendor/extra/ims-blobs" "$([ -s "$P18" ] && ! grep -q '^+.*vendor/extra/ims-blobs' "$P18" 2>/dev/null && echo 1 || echo 0)"
ck "S4c Android.mk symlinks the JNI libs"    "$(grep -q 'IMS_SYMLINKS' "$DT/Android.mk" 2>/dev/null && echo 1 || echo 0)"
# a comment between a backslash line and its continuation silently breaks make and shell alike
ck "S4d no comment inside a continuation"    "$([ -s "$RC" ] && [ -s "$DT/Android.mk" ] && [ -s "$DT/device.mk" ] && { for f in "$RC" "$DT/Android.mk" "$DT/device.mk"; do awk '/\\$/{p=1;next} p&&/^[[:space:]]*#/{print "x"} {p=0}' "$f" 2>/dev/null; done | grep -q x && echo 0 || echo 1; } || echo 0)"

# staged blobs
# NOTE: apply-overlay clears vendor/extra at the start of every build, so the S5 checks only mean
# anything after extract-ims-blobs.sh has run. Re-stage before trusting them.
MK="$SRC/vendor/ims-blobs/ims-blobs.mk"
ck "S5  blobs staged (53 files)"             "$([ "$(find "$SRC/vendor/ims-blobs" -type f ! -name '*.mk' 2>/dev/null | wc -l)" = 53 ] && echo 1 || echo 0)"
# APKs must NOT be staged: PRODUCT_COPY_FILES rejects them outright, and ims.apk is dex-stripped
# so importing it alone installs a shell with no code.
ck "S5b no APK in the generated fragment"    "$([ -s "$MK" ] && ! grep -q '\.apk' "$MK" 2>/dev/null && echo 1 || echo 0)"
ck "S5f all four daemons in the fragment"    "$([ "$(grep -cE 'vendor/bin/(imsqmidaemon|imsdatadaemon|ims_rtp_daemon|imscmservice):' "$MK" 2>/dev/null)" = 4 ] && echo 1 || echo 0)"
# the destination decides the partition, not the source: etc/ is system-side, vendor/ is not
ck "S5c system-side entries go to SYSTEM"    "$(grep -q 'etc/permissions/qcrilhook.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/qcrilhook.xml' "$MK" 2>/dev/null && echo 1 || echo 0)"
ck "S5d daemons go to VENDOR"                "$(grep -q 'vendor/bin/imsqmidaemon:$(TARGET_COPY_OUT_VENDOR)/bin/imsqmidaemon' "$MK" 2>/dev/null && echo 1 || echo 0)"
ck "S5e last mk line has no trailing backslash" "$([ -s "$MK" ] && { tail -1 "$MK" | grep -q '\\$' && echo 0 || echo 1; } || echo 0)"

# Every library the daemons NEED must be shipped or already in the vendor set. Name-matching missed
# five (lib-rtp*, lib-dplmedia) and ims_rtp_daemon restart-looped on "CANNOT LINK EXECUTABLE".
_unmet=$(python3 - "$SRC" "$W" 2>/dev/null <<'PYEOF'
import os,sys,subprocess
SRC,W=sys.argv[1],sys.argv[2]
stage=os.path.join(SRC,'vendor/ims-blobs'); vend=os.path.join(SRC,'vendor/nextbit/ether/proprietary')
have={os.path.basename(f) for r,_,fs in os.walk(stage) for f in fs}
have|={os.path.basename(f) for r,_,fs in os.walk(vend) for f in fs}
plat=('libc.so','libm.so','libdl.so','libc++.so','liblog.so','libcutils.so','libutils.so','libbinder.so','libdiag.so','libidl.so','libwpa_client.so')
miss=set()
for d in ('imsqmidaemon','imsdatadaemon','ims_rtp_daemon','imscmservice'):
    p=os.path.join(W,'system/bin',d)
    if not os.path.exists(p): continue
    out=subprocess.run(['readelf','-d',p],capture_output=True,text=True).stdout
    for l in out.splitlines():
        if 'NEEDED' not in l: continue
        n=l.split('[')[1].split(']')[0]
        if n not in have and n not in plat: miss.add(n)
print(len(miss))
PYEOF
)
ck "S6  every daemon NEEDED is shipped (${_unmet:-?} unmet)" "$([ "${_unmet:-1}" = 0 ] && echo 1 || echo 0)"

echo
[ "$fail" -eq 0 ] && echo "RESULT: CLEAN" || echo "RESULT: $fail FAILURE(S)"
exit $fail
