#!/usr/bin/env bash
# android-cc.sh — compile a small C probe into an aarch64 Android binary using the device tree's
# own toolchain, and optionally push it. For one-file diagnostics you want to run on the phone when
# adding a Soong module would mean a build.
#
#   android-cc.sh <src.c> [out] [--push] [-s SERIAL]
#   android-cc.sh tools/native-probes/qmi-idl-probe.c --push
#
# Why not the NDK: you probably do not have one, and the tree does -- prebuilts/clang plus the
# generated out/soong/ndk/sysroot. Why not freestanding (see freestanding-arm64.sh): that is for
# raw-syscall helpers; anything that dlopens a vendor library needs bionic and the real linker.
#
# Two traps this handles, both of which fail with unhelpful linker errors:
#   * -nostdlib is required, because the NDK sysroot here ships no crtbegin/crtend. They come from
#     out/soong/.intermediates/bionic, and the FIRST match is often the wrong architecture --
#     "crtend_android.o is incompatible with aarch64linux" is an arm (32-bit) object picked by a
#     glob. Both are selected by arm64 path here.
#   * libc/libdl come from the built product tree, not the sysroot.
set -euo pipefail
SRC=""; OUT=""; PUSH=0; SERIAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    -s) SERIAL=(-s "${2:?-s needs a serial}"); shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) if [ -z "$SRC" ]; then SRC="$1"; else OUT="$1"; fi; shift ;;
  esac
done
[ -n "$SRC" ] || { echo "usage: android-cc.sh <src.c> [out] [--push] [-s SERIAL]" >&2; exit 2; }
[ -f "$SRC" ] || { echo "!! no such source: $SRC" >&2; exit 1; }
# Default the output next to nothing in particular -- the CWD -- but if the caller gave a path,
# honour it. basename-ing it (as this first did) silently writes to the CWD instead, and then the
# push step looks right while pushing a file from somewhere else.
OUT="${OUT:-$(basename "${SRC%.c}")}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
S="${AOSP_ROOT:-$REPO/build_output/src}"
[ -d "$S/prebuilts/clang" ] || { echo "!! no synced tree at $S (set AOSP_ROOT)" >&2; exit 1; }
CLANG="$(ls -d "$S"/prebuilts/clang/host/linux-x86/clang-r*/bin/clang 2>/dev/null | tail -1)"
[ -x "$CLANG" ] || { echo "!! no clang under $S/prebuilts/clang" >&2; exit 1; }
SYSROOT="$S/out/soong/ndk/sysroot"
[ -d "$SYSROOT" ] || { echo "!! no NDK sysroot at $SYSROOT -- build the tree once first" >&2; exit 1; }

# arm64 path match, not first match: the glob otherwise yields a 32-bit object and the linker
# complains about the architecture rather than about the glob.
CRTB="$(find "$S/out/soong/.intermediates/bionic/libc/crtbegin_dynamic" -name crtbegin_dynamic.o -path '*arm64*' 2>/dev/null | head -1)"
CRTE="$(find "$S/out/soong/.intermediates/bionic/libc/crtend_android"  -name crtend_android.o  -path '*arm64*' 2>/dev/null | head -1)"
[ -n "$CRTB" ] && [ -n "$CRTE" ] || { echo "!! no arm64 crtbegin/crtend under out/soong/.intermediates/bionic" >&2; exit 1; }

LIBDIR="$(ls -d "$S"/out/target/product/*/system/lib64 2>/dev/null | head -1)"
[ -n "$LIBDIR" ] || { echo "!! no built system/lib64 under $S/out/target/product" >&2; exit 1; }

"$CLANG" --target="${ANDROID_TARGET:-aarch64-linux-android30}" --sysroot="$SYSROOT" \
  -nostdlib -O2 -o "$OUT" "$CRTB" "$SRC" "$CRTE" -L"$LIBDIR" -lc -ldl
echo ">> built $OUT ($(stat -c%s "$OUT") bytes)"

if [ "$PUSH" = 1 ]; then
  ADB="${ADB:-adb}"
  "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" push "$OUT" /data/local/tmp/ >/dev/null
  "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" shell chmod 755 "/data/local/tmp/$OUT"
  echo ">> pushed /data/local/tmp/$OUT"
  echo "   run it with the vendor libs visible:"
  echo "   adb shell 'LD_LIBRARY_PATH=/vendor/lib64:/system/lib64 /data/local/tmp/$OUT'"
fi
