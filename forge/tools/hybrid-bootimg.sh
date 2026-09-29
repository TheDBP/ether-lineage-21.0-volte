#!/usr/bin/env bash
# hybrid-bootimg.sh — a boot image with one build's kernel+dtb and another's ramdisk.
#
#   hybrid-bootimg.sh <kernel-from.img> <ramdisk-from.img> <out.img>
#
# The port-a-kernel-gap workflow (docs/porting-a-branch-bump.md): the new branch's kernel with the
# old branch's *recovery* ramdisk boots recovery/fastbootd on the candidate kernel, so you can run
# the new ramdisk's init under init-harness.sh before risking a normal boot. Header version, cmdline,
# offsets, os_version all come from <kernel-from.img>. Needs unpack_bootimg/mkbootimg: HOST_BIN, or
# */out/host/linux-x86/bin under $ANDROID_SRC or ./build_output/src.
set -euo pipefail
[ $# -eq 3 ] || { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SRC="${ANDROID_SRC:-$PWD/build_output/src}"
HB="${HOST_BIN:-$SRC/out/host/linux-x86/bin}"
[ -x "$HB/unpack_bootimg" ] && [ -x "$HB/mkbootimg" ] || { echo "!! no unpack_bootimg/mkbootimg in $HB (set HOST_BIN)" >&2; exit 1; }
OUT="$(realpath -m "$3")"; W="$OUT.work"; rm -rf "$W"; mkdir -p "$W/k" "$W/r"
kargs="$("$HB/unpack_bootimg" --boot_img "$1" --out "$W/k" --format=mkbootimg)"
"$HB/unpack_bootimg" --boot_img "$2" --out "$W/r" >/dev/null
[ -f "$W/r/ramdisk" ] || { echo "!! $2 has no ramdisk" >&2; exit 1; }
kargs="${kargs//"$W/k/ramdisk"/"$W/r/ramdisk"}"
eval "$HB/mkbootimg" $kargs --output "\"$OUT\""
rm -rf "$W"
ls -la "$OUT"
