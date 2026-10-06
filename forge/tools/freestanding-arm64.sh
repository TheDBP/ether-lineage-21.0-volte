#!/usr/bin/env bash
# freestanding-arm64.sh — cross-compile one of the freestanding arm64 helpers (no libc, raw syscalls,
# own _start) in the cached cross-compile container and push it to /data/local/tmp. Sourced by the
# tool wrappers; not called directly.
#
#   freestanding-arm64.sh is SOURCED, not run: `. freestanding-arm64.sh` then xc_build_push ...
#
#   xc_build_push <src.c> <out-binary> <name-on-device>
#
# Freestanding so the same binary runs on any Android version and in recovery: nothing to link
# against, nothing bionic can refuse. The container is the one diag-efs.sh makes (ubuntu +
# gcc-aarch64-linux-gnu); it is created on first use.
xc_build_push() {
  local SRC="$1" OUT="$2" NAME="$3" IMAGE="${XC_IMAGE:-aosp-xc:22.04}" ADB="${ADB:-adb}"
  [ -f "$SRC" ] || { echo "!! missing $SRC" >&2; return 1; }
  if [ ! -x "$OUT" ] || [ "$SRC" -nt "$OUT" ]; then
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo ">> building $IMAGE (one time: ubuntu + gcc-aarch64-linux-gnu)"
      docker rm -f rom-forge-xc >/dev/null 2>&1
      docker run --name rom-forge-xc --user 0:0 "${XC_BASE:-ubuntu:22.04}" bash -c \
        'apt-get update -qq && apt-get install -y -qq gcc-aarch64-linux-gnu' >/dev/null 2>&1 || {
          echo "!! could not prepare the cross-compile image" >&2; return 1; }
      docker commit rom-forge-xc "$IMAGE" >/dev/null
      docker rm -f rom-forge-xc >/dev/null 2>&1
    fi
    echo ">> cross-compiling $(basename "$SRC") for aarch64 (freestanding)"
    docker run --rm --user 0:0 -v "$(cd "$(dirname "$SRC")" && pwd)":/w -w /w "$IMAGE" bash -c \
      "aarch64-linux-gnu-gcc -static -nostdlib -ffreestanding -fno-stack-protector -fno-builtin -O2 -Wall -o $(basename "$OUT") $(basename "$SRC")" || return 1
  fi
  [ "$("$ADB" shell id -u 2>/dev/null | tr -d '\r')" = "0" ] || echo "!! not root; run 'adb root' first" >&2
  "$ADB" push "$OUT" "/data/local/tmp/$NAME" >/dev/null 2>&1 || { echo "!! could not push $NAME" >&2; return 1; }
  "$ADB" shell "chmod 755 /data/local/tmp/$NAME"
}
