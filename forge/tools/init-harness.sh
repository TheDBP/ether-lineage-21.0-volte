#!/usr/bin/env bash
# init-harness.sh — run a new ramdisk's /init on the live kernel, from recovery, without a boot.
#
#   init-harness.sh <boot.img | ramdisk-dir> [-t SECONDS] [-o OUTDIR] [-c 'CMD ...'] [-s SERIAL]
#
# Pushes the ramdisk to the phone's own tmpfs and runs its /init as PID 1 of a throwaway PID
# namespace (`unshare -f -p -m chroot`). reboot(2) from a non-root pidns only kills that namespace,
# so an InitFatalReboot is harmless and its message stays in the live kernel log, which is captured
# to OUTDIR/kmsg.log; the `init:` lines are printed, FATALs highlighted. Each FATAL is a kernel gap
# (or a ramdisk problem) found without burning a slot-retry on a normal boot.
#
# -c runs another command in the chroot instead of /init — for the bionic floor:
#     -c '/system/bin/toybox uname -a'      (aborts in libc init if the kernel lacks a syscall)
#
# Ceiling: recovery-mode init has no /system, so this covers first stage → selinux_setup → the start
# of second stage only. SetupCgroups, apexd-bootstrap and everything in early-init need a real boot;
# read those with dtbo-ramoops-alt.py + pstore-pull.sh. Stop it (-t) before second stage starts
# services if adb matters: the new adbd would reconfigure the USB gadget under the running recovery.
#
# Needs adb root; the recovery must be on the candidate kernel (hybrid-bootimg.sh). Unpacking a
# boot.img needs unpack_bootimg (HOST_BIN or */out/host/linux-x86/bin under $ANDROID_SRC or
# ./build_output/src) and lz4/gzip + cpio on the host.
set -u
T=20; OUT=./init-harness; CMD=""; SER=""; IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) T="$2"; shift 2 ;; -o) OUT="$2"; shift 2 ;; -c) CMD="$2"; shift 2 ;; -s) SER="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) IN="$1"; shift ;;
  esac
done
[ -n "$IN" ] || { echo "usage: init-harness.sh <boot.img|ramdisk-dir> [-t S] [-o DIR] [-c CMD]" >&2; exit 1; }
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"

RD="$IN"
if [ -f "$IN" ]; then
  SRC="${ANDROID_SRC:-$PWD/build_output/src}"; HB="${HOST_BIN:-$SRC/out/host/linux-x86/bin}"
  [ -x "$HB/unpack_bootimg" ] || { echo "!! no unpack_bootimg in $HB (set HOST_BIN)" >&2; exit 1; }
  rm -rf "$OUT/unpack" "$OUT/ramdisk"; mkdir -p "$OUT/unpack" "$OUT/ramdisk"
  "$HB/unpack_bootimg" --boot_img "$IN" --out "$OUT/unpack" >/dev/null
  case "$(head -c 4 "$OUT/unpack/ramdisk" | xxd -p)" in
    04224d18) lz4 -dc "$OUT/unpack/ramdisk" ;;
    1f8b*)    gzip -dc "$OUT/unpack/ramdisk" ;;
    *)        cat "$OUT/unpack/ramdisk" ;;
  esac | (cd "$OUT/ramdisk" && cpio -idm --quiet 2>/dev/null)
  RD="$OUT/ramdisk"
fi
[ -x "$RD/init" ] || [ -L "$RD/init" ] || { echo "!! $RD has no /init" >&2; exit 1; }

"${ADB[@]}" root >/dev/null 2>&1; sleep 1; "${ADB[@]}" wait-for-recovery
tar -C "$RD" -cf "$OUT/rd.tar" . 
"${ADB[@]}" push "$OUT/rd.tar" /tmp/rd.tar >/dev/null
"${ADB[@]}" shell 'rm -rf /tmp/rd; mkdir -p /tmp/rd && tar -xf /tmp/rd.tar -C /tmp/rd && chown -R 0:0 /tmp/rd && rm /tmp/rd.tar' || exit 1

"${ADB[@]}" shell 'dmesg -w' > "$OUT/kmsg.log" 2>/dev/null &
DM=$!; sleep 1
if [ -n "$CMD" ]; then
  echo "== chroot: $CMD"
  "${ADB[@]}" shell "timeout -s KILL $T toybox chroot /tmp/rd $CMD" | tee "$OUT/cmd.out"
else
  echo "== /init as PID 1 of a new pidns, ${T}s"
  "${ADB[@]}" shell "timeout -s KILL $T toybox unshare -f -p -m chroot /tmp/rd /init" > "$OUT/init.out" 2>&1
fi
sleep 2; kill $DM 2>/dev/null; wait $DM 2>/dev/null
"${ADB[@]}" shell 'rm -rf /tmp/rd' >/dev/null 2>&1

echo "== init: lines ($OUT/kmsg.log)"
grep -a ' init: ' "$OUT/kmsg.log" | sed 's/^[^]]*\] //' | tail -60
echo "== FATAL / avc"
grep -a -e 'FATAL' -e 'init: .*fatal' -e 'avc:  denied' "$OUT/kmsg.log" | sed 's/^[^]]*\] //' | head -20 || true
