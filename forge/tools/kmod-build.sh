#!/usr/bin/env bash
# kmod-build.sh — build an out-of-tree kernel module against the device's last kernel build in the forge container.
# Uses exactly the make environment the ROM build used.
#
#   ./forge/tools/kmod-build.sh <module-dir>            # dir holds a kbuild Makefile (obj-m := x.o)
#
# Run from the device repo. <module-dir> must be inside the device repo (it is reached as
# /repo/<relpath>); build_output/tmp/<name> is the usual place. Output: <module-dir>/*.ko.
#
# WHY NOT `make M=... O=KERNEL_OBJ` ON THE HOST
#
# Kbuild records the command line of every object it built. A host make, with a different clang,
# different paths or different flags, decides the recorded commands are stale and REBUILDS parts of
# KERNEL_OBJ (the vdso first, because arch/arm64 makes `prepare` depend on `vdso_prepare`), and then
# fails half way, leaving the ROM's kernel objects in a state the next real build has to repair.
# The container has the same toolchain at the same paths, so the only new objects are the module's.
#
# WHAT IT REPRODUCES
#
# vendor/lineage/build/tasks/kernel.mk's make-kbuild-module-target: KERNEL_MAKE_CMD, KERNEL_MAKE_FLAGS,
# KERNEL_CROSS_COMPILE, TOOLS_PATH_OVERRIDE from `get_build_var`; CC="<ccache> clang" LD=ld.lld and
# CLANG_TRIPLE as kernel.mk sets them (those two are task-local and not visible to get_build_var);
# PATH with the kernel clang and gcc bin dirs; LD_LIBRARY_PATH for the clang libs.
#
# LOADING THE RESULT ON A KERNEL FROM A DIFFERENT BUILD (official nightly, another toolchain)
#
# vermagic matches when UTS_RELEASE matches, but with CONFIG_MODVERSIONS the __versions CRCs must
# match too, and genksyms CRCs change with the compiler for some symbols (module_layout,
# param_ops_*) and not others. If insmod says "disagrees about version of symbol", rewrite the CRCs
# from the running kernel's Image with kmod-rebase-crcs.py. That is safe only when the two kernels
# are the same source and the same config for every struct the module touches: diff
# `zcat /proc/config.gz` against KERNEL_OBJ/.config first.
set -euo pipefail

[ $# -eq 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
REPO="$(pwd)"
[ -f "$REPO/device.conf" ] || { echo "!! run from the device repo (device.conf not found)" >&2; exit 1; }
source "$REPO/device.conf"
MOD="$(cd "$1" && pwd)"
case "$MOD" in "$REPO"/*) ;; *) echo "!! $MOD is not inside the device repo; the container cannot see it" >&2; exit 1 ;; esac
REL="${MOD#"$REPO"/}"
export BUILD_ROOT="${BUILD_ROOT:-$REPO/build_output}"

cat > "$MOD/.kmod-build-in-container.sh" <<EOS
#!/bin/bash
set -o pipefail
cd /aosp || exit 1
export USE_CCACHE=1 CCACHE_DIR=/ccache
source build/envsetup.sh >/dev/null
lunch "$LUNCH_TARGET" >/dev/null 2>&1 || { echo "!! lunch $LUNCH_TARGET failed"; exit 1; }
KSRC="\$(get_build_var TARGET_KERNEL_SOURCE)"; KOUT="\$(get_build_var TARGET_OUT_INTERMEDIATES)/KERNEL_OBJ"
CLANG="\$(get_build_var TARGET_KERNEL_CLANG_PATH)"; GCC="\$(get_build_var KERNEL_TOOLCHAIN_PATH_gcc)"
ARCH="\$(get_build_var KERNEL_ARCH)"; WRAP="\$(get_build_var KERNEL_CC_WRAPPER)"
case "\$ARCH" in arm64) TRIPLE=aarch64-linux-gnu- ;; arm) TRIPLE=arm-linux-gnu- ;; *) TRIPLE=x86_64-linux-gnu- ;; esac
[ -d "\$KOUT" ] || { echo "!! \$KOUT missing: run a full build first"; exit 1; }
export PATH="\$GCC:\$CLANG/bin:/aosp/out/host/linux-x86/bin:\$PATH" LD_LIBRARY_PATH="\$CLANG/lib64"
M=/repo/$REL
eval "\$(get_build_var TOOLS_PATH_OVERRIDE) \$(get_build_var KERNEL_MAKE_CMD) \$(get_build_var KERNEL_MAKE_FLAGS) \\
  -C /aosp/\$KSRC O=\$KOUT ARCH=\$ARCH \$(get_build_var KERNEL_CROSS_COMPILE) CLANG_TRIPLE=\$TRIPLE \\
  CC=\"\$WRAP clang\" LD=ld.lld M=\$M modules" 2>&1 | grep -v 'nsjail error'
rc=\${PIPESTATUS[0]}
ls -la \$M/*.ko 2>/dev/null
exit \$rc
EOS
chmod +x "$MOD/.kmod-build-in-container.sh"
CONTAINER="aosp-${DEVICE_SLUG}-kmod" LOG_TAG=kmod "$REPO/forge/docker/aosp.sh" bash "/repo/$REL/.kmod-build-in-container.sh"
