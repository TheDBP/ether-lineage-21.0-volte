#!/usr/bin/env bash
# push-system-app.sh -- iterate a reworked /system app on an already-flashed device WITHOUT a full
# ROM reflash: match the device's platform signer, sign, push, and swap it into /system across a
# reboot. Turns a ~45-min rebuild+reflash loop into a ~3-min one when debugging a system app's
# runtime (dex fixes, resource fixes) -- NOT for sepolicy (policy is in the boot image; needs reflash).
#
#   push-system-app.sh <reworked.apk> <device-install-dir> [-s SERIAL]
#     e.g. push-system-app.sh Ims4-reworked.apk /system/priv-app/Ims4
#
# Three things this gets right, each of which cost a debugging cycle to learn:
#
#   1. SHARED-UID SIGNATURE. An app with android:sharedUserId (android.uid.phone, .system, ...) must
#      be signed with the SAME key as the other apps in that uid, or PackageManager rejects it at scan
#      with "Signature mismatch for shared user" and the package silently does not install. The right
#      key is whatever signed the platform apps on THIS build -- often build/make's default `platform`
#      key, NOT testkey and NOT a custom release key. This script reads the device's actual platform
#      cert (from an installed platform app) and finds the matching key among the candidates, instead
#      of guessing.
#   2. UNCOMPRESSED JNI. android_app_import stores a system app's embedded .so uncompressed+aligned;
#      harmless to keep compressed for extractNativeLibs=true apps, but we zipalign -p either way.
#   3. THE FLAKY /system REMOUNT. On a block (non-overlay, dm-verity-less-but-RO) system-as-root, only
#      the FIRST `mount -o rw,remount /` after a clean boot persists; later ones report "not user
#      mountable in fstab" and adb push lands in a view that reverts on reboot. So: adb push to /data,
#      then reboot, then as the very first op on the fresh boot remount and `cp` from /data within ONE
#      root shell (same mount namespace). This is why a plain `adb push` to /system seems to work and
#      then vanishes.
#
# Needs adb root (`adb root`), the tree's zipalign + apksigner, and the candidate signing keys. Does
# TWO reboots (one to land the cp, one for PM to rescan). Reads BUILD_ROOT for the host tools/keys.
set -uo pipefail
APK="${1:?usage: push-system-app.sh <reworked.apk> <device-install-dir> [-s SERIAL]}"
DIR="${2:?device install dir, e.g. /system/priv-app/Ims4}"; shift 2
SER=(); while [ $# -gt 0 ]; do case "$1" in -s) SER=(-s "$2"); shift 2;; *) echo "!! unknown arg $1" >&2; exit 2;; esac; done
[ -f "$APK" ] || { echo "!! no such apk: $APK" >&2; exit 1; }
A=("${ADB:-adb}" "${SER[@]+"${SER[@]}"}")
S="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/src"
ZA="$S/out/host/linux-x86/bin/zipalign"; AS="$S/out/host/linux-x86/bin/apksigner"
for t in "$ZA" "$AS"; do [ -x "$t" ] || { echo "!! missing $t (set BUILD_ROOT)" >&2; exit 1; }; done
"${A[@]}" root >/dev/null 2>&1; sleep 2

# 1. find the platform key that matches the device's platform signer.
base=$(basename "$DIR"); devapk=$("${A[@]}" shell "ls $DIR/*.apk 2>/dev/null | head -1" | tr -d '\r')
[ -n "$devapk" ] || { echo "!! no apk in $DIR on device -- is the dir right?" >&2; exit 1; }
W="${TMPDIR:-$(dirname "$APK")}/.push-sysapp"; mkdir -p "$W"
"${A[@]}" pull "$devapk" "$W/ref.apk" >/dev/null 2>&1
DEVFP=$("$AS" verify --print-certs "$W/ref.apk" 2>/dev/null | awk '/SHA-256 digest/{print $NF; exit}')
[ -n "$DEVFP" ] || { echo "!! could not read device platform cert from $devapk" >&2; exit 1; }
KEY=""
for k in "$S"/build/make/target/product/security/platform "$S"/build/make/target/product/security/testkey \
         "${KEYS_DIR:-/nonexistent}"/platform "${KEYS_DIR:-/nonexistent}"/releasekey; do
  [ -f "$k.x509.pem" ] || continue
  fp=$(openssl x509 -in "$k.x509.pem" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//;s/://g' | tr 'A-Z' 'a-z')
  [ "$fp" = "$DEVFP" ] && { KEY="$k"; break; }
done
[ -n "$KEY" ] || { echo "!! no candidate key matches the device platform cert ($DEVFP); set KEYS_DIR" >&2; exit 1; }
echo ">> signing with $(basename "$KEY") (matches device platform cert)"

# 2. zipalign + sign
"$ZA" -p -f 4 "$APK" "$W/aligned.apk" >/dev/null 2>&1
"$AS" sign --key "$KEY.pk8" --cert "$KEY.x509.pem" --out "$W/signed.apk" "$W/aligned.apk" >/dev/null 2>&1 \
  || { echo "!! apksigner failed" >&2; exit 1; }

# 3. push to /data, reboot, first-op remount+cp on the fresh boot, reboot for PM rescan
"${A[@]}" push "$W/signed.apk" /data/local/tmp/.pushapp.apk >/dev/null 2>&1
echo ">> reboot #1 (to land the /system write on a fresh mount)"
"${A[@]}" reboot; until "${A[@]}" devices 2>/dev/null | awk 'NR==2{exit($2=="device"?0:1)}'; do sleep 5; done
sleep 8; "${A[@]}" root >/dev/null 2>&1; sleep 3
"${A[@]}" shell "mount -o rw,remount / 2>/dev/null; cp -f /data/local/tmp/.pushapp.apk $DIR/$base.apk && restorecon $DIR/$base.apk && rm -rf $DIR/oat && sync && echo '   deployed '\$(stat -c %s $DIR/$base.apk)' bytes'" 2>&1 | tr -d '\r'
echo ">> reboot #2 (PackageManager rescans the swapped apk)"
"${A[@]}" reboot; until "${A[@]}" devices 2>/dev/null | awk 'NR==2{exit($2=="device"?0:1)}'; do sleep 5; done
t0=$(date +%s); until [ "$("${A[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do [ $(( $(date +%s)-t0 )) -gt 240 ] && break; sleep 15; done
echo ">> boot_completed=[$("${A[@]}" shell getprop sys.boot_completed | tr -d '\r')] (+$(( $(date +%s)-t0 ))s)"
true
