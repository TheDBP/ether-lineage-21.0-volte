#!/bin/bash
# root option, post-build hook -- patch the built boot.img with Magisk and swap it into the ROM zip,
# producing a pre-rooted image. Run AFTER the build, inside the container:
#   run automatically when WITH_ROOT=true; by hand:
#   ./forge/docker/aosp.sh bash /repo/forge/options/root/post-build.sh
# The zip is re-signed afterwards: Lineage recovery verifies the whole-file signature on sideload,
# and swapping an entry breaks it. Also drops a standalone boot-magisk.img for fastboot users.
#
# How it works: Magisk's own boot_patch.sh, run headlessly. magiskboot is the x86_64
# build (runs on the host); the embedded payload (magiskinit/magisk/init-ld) is arm64
# (runs on the Robin). KEEPVERITY/KEEPFORCEENCRYPT match the Magisk app defaults.
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${DEVICE_REPO:?}/build_output/tmp"; mkdir -p "$TMPDIR"

# DEVICE_REPO and FORGE_DIR come from the hook runner in _build_rom.sh, which has already sourced
# device.conf. Deriving them from $0 is what broke when this moved out of docker/ into options/root/:
# "$(dirname $0)/../.." used to mean /repo and would now mean /repo/forge, so device.conf would
# silently not be found and DEVICE_CODENAME would be unset. The fallback keeps the script runnable
# by hand, but the hook path is the one that matters.
: "${FORGE_DIR:=/repo/forge}"
if [ -z "${DEVICE_CODENAME:-}" ]; then
  _SELF_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
  [ -f "$_SELF_REPO/device.conf" ] && source "$_SELF_REPO/device.conf"
fi
: "${DEVICE_CODENAME:?device.conf missing or DEVICE_CODENAME unset}"
# capture-then-first-line (never `ls | head` — the pipe SIGPIPEs ls under pipefail; `|| true` also
# absorbs the no-match case so set -e doesn't abort). See GOTCHAS.
# MAGISK_APK pins a specific APK. If it is set, it is honoured exactly -- a missing file is an
# error, not an invitation to go and fetch a different one. Silently substituting is how pointing
# this at a deliberately-bogus path (to check the preamble without patching anything) ended up
# downloading Magisk and rewriting a finished zip.
APK_PINNED=false
if [ -n "${MAGISK_APK:-}" ]; then APK="$MAGISK_APK"; APK_PINNED=true
else _apks="$(ls -t "$FORGE_DIR"/prebuilt/Magisk-*.apk 2>/dev/null || true)"; APK="${_apks%%$'\n'*}"; fi
if [ "$APK_PINNED" = true ] && [ ! -f "$APK" ]; then
  echo "!! MAGISK_APK=$APK does not exist. Not substituting another one." >&2; exit 1
fi
OUT=/aosp/out/target/product/$DEVICE_CODENAME
ZIP="$(ls -t "$OUT"/lineage-*.zip 2>/dev/null || true)"; ZIP="${ZIP%%$'\n'*}"

# APK is fetched (sha256-verified), not vendored — grab it if missing.
if [ ! -f "$APK" ] && [ "$APK_PINNED" = false ] && [ -x "$FORGE_DIR/prebuilt/fetch-magisk.sh" ]; then
  bash "$FORGE_DIR/prebuilt/fetch-magisk.sh"
  _apks="$(ls -t "$FORGE_DIR"/prebuilt/Magisk-*.apk 2>/dev/null || true)"; APK="${_apks%%$'\n'*}"
fi
[ -f "$APK" ] || { echo "!! Magisk APK not found: $APK (run prebuilt/fetch-magisk.sh)"; exit 1; }
[ -f "$ZIP" ] || { echo "!! ROM zip not found in $OUT"; exit 1; }
VER="$(unzip -p "$APK" assets/util_functions.sh | grep -m1 "MAGISK_VER=" | cut -d\' -f2)"
echo ">> baking Magisk $VER into $(basename "$ZIP")"

W="$(mktemp -d)"; cd "$W"
# host tool (x86_64) + target payload (arm64) + assets
unzip -oj "$APK" lib/x86_64/libmagiskboot.so    >/dev/null && mv libmagiskboot.so magiskboot
unzip -oj "$APK" lib/arm64-v8a/libmagiskinit.so >/dev/null && mv libmagiskinit.so magiskinit
unzip -oj "$APK" lib/arm64-v8a/libmagisk.so     >/dev/null && mv libmagisk.so magisk
unzip -oj "$APK" lib/arm64-v8a/libinit-ld.so    >/dev/null && mv libinit-ld.so init-ld
unzip -oj "$APK" assets/boot_patch.sh assets/util_functions.sh assets/stub.apk >/dev/null
chmod +x magiskboot boot_patch.sh

# A-only vs A/B. An A-only OTA zip carries boot.img as a plain entry, so it can be patched and
# swapped back in (one pre-rooted zip). An A/B zip is payload-based: no boot.img entry, and
# re-inserting one would mean regenerating and re-signing payload.bin. On A/B we patch the BUILT
# image and ship it standalone for fastboot; the zip stays stock.
# WHICH image: on GKI 2.0 devices (BOARD_USES_GENERIC_KERNEL_IMAGE — Tensor/Pixel 8 etc.) the
# generic ramdisk lives in init_boot, and that is what Magisk patches; boot.img there is
# kernel-only. Pre-GKI A/B devices keep the ramdisk in boot.img.
AB_ZIP=false
# grep -c (not -q): -q exits on first match and SIGPIPEs unzip under pipefail. `|| true` absorbs
# the no-match exit. See tools/check-sigpipe.sh.
_payload_n=$(unzip -l "$ZIP" | grep -c 'payload\.bin' || true)
if [ "${_payload_n:-0}" -gt 0 ]; then AB_ZIP=true; fi
IMG=boot
if [ "$AB_ZIP" = true ]; then
  if [ -f "$OUT/init_boot.img" ]; then IMG=init_boot; fi
  [ -f "$OUT/$IMG.img" ] || { echo "!! A/B zip ($(basename "$ZIP")) and no $OUT/$IMG.img to patch"; exit 1; }
  cp -f "$OUT/$IMG.img" boot.img
  echo "   A/B device: payload-based zip — patching $OUT/$IMG.img, shipping standalone"
else
  unzip -oj "$ZIP" boot.img >/dev/null
fi
export KEEPVERITY=true KEEPFORCEENCRYPT=true BOOTMODE=false
sh boot_patch.sh boot.img
[ -f new-boot.img ] || { echo "!! boot_patch produced no new-boot.img"; exit 1; }
./magiskboot unpack new-boot.img >/dev/null 2>&1 || { echo "!! patched boot won't re-unpack — aborting"; exit 1; }
echo "   patched boot verified (re-unpacks, magisk embedded)"

if [ "$AB_ZIP" = true ]; then
  # A/B: leave the zip untouched (payload is signed); ship the patched image for fastboot.
  cp -f new-boot.img "$OUT/$IMG-magisk.img"
  cd /; rm -rf "$W"
  echo ">> done — A/B device, zip left stock. Root it with:"
  echo "     adb sideload $(basename "$ZIP")"
  echo "     fastboot flash $IMG $IMG-magisk.img"
else
  # A-only: swap the patched boot into the ROM zip, then re-sign the whole file with the same key
  # the build used (release key when mounted, else the AOSP test key) or sideload refuses it.
  cp -f new-boot.img boot.img
  zip "$ZIP" boot.img >/dev/null
  KEY=/aosp/vendor/lineage-priv/keys/releasekey
  [ -f "$KEY.pk8" ] || KEY=/aosp/build/make/target/product/security/testkey
  java -Xmx2g -Djava.library.path=/aosp/out/host/linux-x86/lib64 \
       -jar /aosp/out/host/linux-x86/framework/signapk.jar -w "$KEY.x509.pem" "$KEY.pk8" "$ZIP" "$ZIP.signed"
  mv -f "$ZIP.signed" "$ZIP"
  echo "   re-signed with $(basename "$KEY")"
  cp -f new-boot.img "$OUT/boot-magisk.img"
  cd /; rm -rf "$W"
  echo ">> done — $(basename "$ZIP") now flashes a Magisk-patched boot; standalone: boot-magisk.img"
fi
