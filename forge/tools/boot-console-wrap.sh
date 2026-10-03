#!/usr/bin/env bash
# boot-console-wrap.sh — a boot image that gets the kernel console out of a boot loop or a hang,
# on a device whose bootloader gives you no serial, no ramoops across its resets, and no `fastboot boot`.
#
#   boot-console-wrap.sh build <boot.img> <recovery.img> <out.img> [--timeout 150] [--every 10] [--misc-offset-mib 16]
#                              [--enforcing] [--cmdline-add '...']
#   boot-console-wrap.sh pull  <out.txt> [--misc-offset-mib 16] [-s SERIAL]
#
# build: the real boot.img's kernel, header and cmdline, with a ramdisk made of the recovery
# ramdisk (for toybox and a shell) plus the boot ramdisk overlaid on it, the real /init renamed
# /init.boot, and `rdinit=/wrap.sh androidboot.init_fatal_reboot_target=recovery
# androidboot.selinux=permissive` appended. On every boot /wrap.sh, as PID 1:
#   1. mounts pstore and copies the previous iteration's console-ramoops into the misc partition at
#      --misc-offset-mib (32 MiB misc: bootloader and recovery use the first few KiB, recovery
#      zeroes the BCB on start, nothing touches 16 MiB);
#   2. forks a watchdog that writes `dmesg` 1 MiB after that every --every seconds and, after
#      --timeout seconds, arms a boot-recovery BCB and reboots with sysrq. This is what reads a
#      HANG: a forced power-off leaves nothing in ramoops, and a warm reboot the bootloader turns
#      into a cold one does not either. The loop therefore runs at most once more and lands in
#      recovery. The rolling snapshot is what reads an init that reboots to recovery on its own
#      before the timeout (`reboot,<target>` with a recovery target): the last snapshot before
#      the reboot is what pull shows, at most --every seconds short of the reason;
#   3. exec's /init.boot.
# Permissive by default: the watchdog stays in the `kernel` SELinux domain, and once init loads the
# policy that domain may write kmsg and sysrq but exec nothing, open nothing and write no block
# device (its misc node sits on tmpfs: `dontaudit kernel tmpfs:blk_file`, not even a denial shows).
# --enforcing therefore takes two iterations: the watchdog only resets at --timeout, no snapshots;
# the next boot of the same image finds a console with `wrap:` lines in ramoops, saves it (step 1)
# and goes straight to recovery. Any boot whose previous boot was also this image does that, so
# `adb reboot` from a running wrap boot lands in recovery too. Denials are logged in permissive as
# well, so build permissive unless the question is which denial *stops* the boot.
# pull: from that recovery, dumps the two misc slots as text, pstore slot first.
#
# Traps the watchdog has to dodge, each of which cost a flash:
#   - `SwitchRoot` MS_MOVEs every mount it can see onto the new root and PLOG(FATAL)s when the
#     mkdir under the read-only system fails -- so the watchdog lives in its own mount namespace
#     (`unshare -m`) and hands off with a marker file before init starts.
#   - `FreeRamdisk` deletes the rootfs after switch_root -- so the watchdog chroots into a tmpfs
#     holding its own toybox, libs, /proc and device nodes.
#   - PID 1 starts with fds 0-2 closed and the recovery ramdisk ships an empty /dev. bionic's
#     libc_init_common.cpp _exit(1)s every process except PID 1 whose stdio is closed when it can
#     open neither /dev/null nor /sys/fs/selinux/null -- so not even `toybox mknod /dev/null` can
#     run until a plain-file /dev/null exists (`: > /dev/null` in the shell) and the fds are open on
#     it. One version did this by accident (`2>/dev/null` on the mknod line); the version that
#     "cleaned that up" panicked the kernel 16 ms into rdinit: `Attempted to kill init!
#     exitcode=0x00000100`. `dd if=/dev/zero` on a missing node took another flash.
#   - bionic finds a binary by name only through /proc/self/exe: call toybox by absolute path.
#   - A visible `/system/bin/recovery` makes init boot recovery mode: it is removed at build time.
# Header versions 0-2 only: on v3+ the cmdline and ramdisk live in vendor_boot.
# Needs unpack_bootimg/mkbootimg (HOST_BIN, or */out/host/linux-x86/bin under $ANDROID_SRC or
# ./build_output/src), GNU cpio, and xz/gzip/lz4 to match the boot ramdisk's compression.
set -euo pipefail
usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
[ $# -ge 1 ] || usage
MODE="$1"; shift
TIMEOUT=150; EVERY=10; OFF=16; PERM=1; CADD=""; SER=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --every) EVERY="$2"; shift 2 ;;
    --misc-offset-mib) OFF="$2"; shift 2 ;;
    --enforcing) PERM=0; shift ;;
    --permissive) PERM=1; shift ;;
    --cmdline-add) CADD="$2"; shift 2 ;;
    -s) SER="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) POS+=("$1"); shift ;;
  esac
done
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")
SEEK=$(( OFF * 256 ))   # 4 KiB blocks; pstore copy at +0, watchdog dmesg at +1 MiB, 2 MiB read back

# ---------------------------------------------------------------- pull
if [ "$MODE" = pull ]; then
  [ ${#POS[@]} -eq 1 ] || usage
  OUT="${POS[0]}"
  # by-name is populated by recovery's ueventd; the sysfs scan is the fallback for a bare shell
  MISC="$("${ADB[@]}" shell 'm=$(readlink -f /dev/block/by-name/misc 2>/dev/null || readlink -f /dev/block/bootdevice/by-name/misc 2>/dev/null); [ -n "$m" ] && [ -b "$m" ] && echo "$m" && exit; for u in /sys/class/block/*/uevent; do grep -q "^PARTNAME=misc$" "$u" 2>/dev/null && echo /dev/block/$(basename $(dirname $u)) && exit; done' | tr -d '\r')"
  [ -n "$MISC" ] || { echo "!! cannot find the misc partition on the device" >&2; exit 1; }
  # two 1 MiB slots, read separately so a stale slot cannot masquerade as the tail of the other
  { for slot in 0 256; do
      echo "######## misc @ $(( OFF * 1024 * 1024 + slot * 4096 )) ########"
      "${ADB[@]}" exec-out "dd if=$MISC bs=4096 skip=$(( SEEK + slot )) count=256 2>/dev/null" | tr -d '\000'
      echo
    done; } > "$OUT"
  echo ">> $(wc -c < "$OUT") bytes from $MISC @ ${OFF} MiB -> $OUT"
  grep -E '^(WRAPLOG|DIAGLOG)' "$OUT" || echo "!! no WRAPLOG/DIAGLOG header: nothing was saved there yet"
  echo ">> each header's uptime= dates that slot; a slot is stale if its boot predates the image you flashed"
  exit 0
fi

# ---------------------------------------------------------------- build
[ "$MODE" = build ] && [ ${#POS[@]} -eq 3 ] || usage
BOOT="${POS[0]}"; REC="${POS[1]}"; OUT="$(realpath -m "${POS[2]}")"
SRC="${ANDROID_SRC:-$PWD/build_output/src}"
HB="${HOST_BIN:-$SRC/out/host/linux-x86/bin}"
[ -x "$HB/unpack_bootimg" ] && [ -x "$HB/mkbootimg" ] || { echo "!! no unpack_bootimg/mkbootimg in $HB (set HOST_BIN)" >&2; exit 1; }
W="$OUT.work"; rm -rf "$W"; mkdir -p "$W/b" "$W/r" "$W/root"
kargs="$("$HB/unpack_bootimg" --boot_img "$BOOT" --out "$W/b" --format=mkbootimg)"
"$HB/unpack_bootimg" --boot_img "$REC" --out "$W/r" >/dev/null
[ -f "$W/b/ramdisk" ] && [ -f "$W/r/ramdisk" ] || { echo "!! both images need a ramdisk" >&2; exit 1; }
hv="$(sed -n 's/.*--header_version \([0-9]*\).*/\1/p' <<<"$kargs")"
[ "${hv:-0}" -le 2 ] || { echo "!! header v$hv: cmdline and ramdisk live in vendor_boot, not handled" >&2; exit 1; }

decomp() {  # <file> -> stdout, and echo the compressor name on fd 3
  local m; m="$(od -An -tx1 -N4 "$1" | tr -d ' \n')"
  case "$m" in
    1f8b*)   echo gzip >&3; gzip -dc "$1" ;;
    fd377a58) echo xz >&3; xz -dc "$1" ;;
    02214c18|04224d18) echo lz4 >&3; lz4 -dc "$1" ;;
    *) echo "!! unknown ramdisk compression (magic $m)" >&2; return 1 ;;
  esac
}
# recovery first, boot on top: the boot ramdisk's fstab, first_stage_ramdisk/ and init win
( cd "$W/root" && decomp "$W/r/ramdisk" 3>/dev/null | cpio -idm --quiet 2>/dev/null ) || true
{ COMP="$(decomp "$W/b/ramdisk" 3>&1 >"$W/boot.cpio")"; } 3>&1
( cd "$W/root" && cpio -idmu --quiet < "$W/boot.cpio" 2>/dev/null ) || true
[ -x "$W/root/system/bin/toybox" ] || { echo "!! recovery ramdisk has no /system/bin/toybox" >&2; exit 1; }
[ -f "$W/root/init" ] || { echo "!! boot ramdisk has no /init" >&2; exit 1; }
mv "$W/root/init" "$W/root/init.boot"
rm -f "$W/root/system/bin/recovery"           # its presence is what puts init into recovery mode
mkdir -p "$W/root/dev" "$W/root/proc" "$W/root/sys" "$W/root/pstore"

cat > "$W/root/wrap.sh" <<EOF
#!/system/bin/sh
# generated by boot-console-wrap.sh -- see its header
T=/system/bin/toybox
# fds 0-2 are closed and /dev is empty. bionic _exit(1)s any process but PID 1 whose stdio is closed
# when neither /dev/null nor /sys/fs/selinux/null opens, so no toybox call can run yet: a shell
# redirection makes a plain-file stand-in, the fds are opened on it, then it is swapped for the node.
: > /dev/null
exec 0</dev/null 1>/dev/null 2>/dev/null
\$T mknod -m 666 /dev/.null c 1 3 && \$T mv -f /dev/.null /dev/null
\$T mknod -m 666 /dev/zero c 1 5; \$T mknod -m 600 /dev/kmsg c 1 11; \$T mknod -m 600 /dev/console c 5 1
exec 0</dev/null 1>/dev/kmsg 2>/dev/kmsg
\$T mkdir -p /proc /sys /pstore
echo "wrap: rdinit start (timeout ${TIMEOUT}s, dmesg every ${EVERY}s, misc@${OFF}MiB)"
\$T mount -t proc proc /proc; \$T mount -t sysfs sysfs /sys
\$T mount -t pstore pstore /pstore 2>/dev/null || echo "wrap: no pstore"
# the misc partition, by PARTNAME: its major:minor differs per storage type, so ask sysfs (and
# wait briefly -- the block driver may still be probing when PID 1 starts)
n=0; MM=""
while [ \$n -lt 50 ]; do
  for u in /sys/class/block/*/uevent; do
    if \$T grep -q '^PARTNAME=misc\$' "\$u" 2>/dev/null; then
      MM="\$(\$T sed -n 's/^MAJOR=//p' "\$u") \$(\$T sed -n 's/^MINOR=//p' "\$u")"; break
    fi
  done
  [ -n "\$MM" ] && break; \$T sleep 0.1; n=\$((n+1))
done
if [ -n "\$MM" ]; then \$T mknod -m 600 /dev/misc b \$MM && echo "wrap: misc is \$MM"; else echo "wrap: no misc partition found, nothing will be saved"; fi
{ echo "WRAPLOG v1 uptime=\$(\$T cat /proc/uptime)"; echo "pstore files: \$(\$T ls /pstore 2>/dev/null)"
  for f in /pstore/*; do [ -e "\$f" ] || continue; echo "===== \$f ====="; \$T cat "\$f"; done
  echo "===== WRAPLOG END ====="; } > /wraplog.txt
[ -e /dev/misc ] && \$T dd if=/dev/zero of=/dev/misc bs=4096 seek=$SEEK count=256 conv=notrunc 2>/dev/null && \$T dd if=/wraplog.txt of=/dev/misc bs=4096 seek=$SEEK count=256 conv=notrunc 2>/dev/null && \$T sync && echo "wrap: pstore saved to misc"
# A console that mentions the wrapper or its watchdog is the previous iteration's: it is saved,
# so go straight to recovery. This is the step the watchdog cannot take once init loads the
# policy (the kernel domain may write sysrq, not a block device), and the whole of a hang's
# evidence is that console -- ramoops survives the watchdog's sysrq reset.
if [ -e /dev/misc ] && \$T grep -qsE 'wrap: |watchdog: ' /pstore/console-ramoops*; then
  \$T dd if=/dev/zero of=/dev/misc bs=2048 count=1 conv=notrunc 2>/dev/null
  \$T printf boot-recovery | \$T dd of=/dev/misc conv=notrunc 2>/dev/null
  \$T printf 'recovery\\n' | \$T dd of=/dev/misc bs=1 seek=64 conv=notrunc 2>/dev/null
  \$T sync; echo "wrap: that console was the previous iteration's; BCB armed, rebooting to recovery"
  \$T sleep 1; echo b > /proc/sysrq-trigger; \$T sleep 5
fi
# watchdog: own mount namespace (SwitchRoot moves every mount it can see and dies on one it
# cannot), own tmpfs root (FreeRamdisk deletes the rootfs after switch_root)
\$T unshare -m /system/bin/sh -c '
exec 0</dev/null 1>/dev/kmsg 2>/dev/kmsg
T=/system/bin/toybox
\$T mkdir -p /diag && \$T mount -t tmpfs tmpfs /diag || echo "watchdog: tmpfs mount failed"
\$T mkdir -p /diag/dev /diag/proc /diag/system
\$T cp -a /system/bin /system/lib64 /system/lib /diag/system/ 2>/dev/null
[ -e /dev/misc ] && \$T cp -a /dev/misc /diag/dev/misc
\$T mknod -m 600 /diag/dev/kmsg c 1 11; \$T mknod -m 666 /diag/dev/null c 1 3; \$T mknod -m 666 /diag/dev/zero c 1 5
\$T mount -t proc proc /diag/proc
echo "watchdog: ns ready, chrooting"; \$T touch /diag-ready
# passed as a string: once init loads the policy the kernel domain may not read a file, and the
# shell must already hold all of it (mksh reads a script file as it goes)
exec \$T chroot /diag /system/bin/sh -c "\$(\$T cat /watchdog.sh)"
' &
n=0; while [ ! -e /diag-ready ] && [ \$n -lt 100 ]; do \$T sleep 0.1; n=\$((n+1)); done; echo "wrap: watchdog ready after \$n ticks"
\$T umount /pstore 2>/dev/null; \$T umount /sys; \$T umount /proc
echo "wrap: exec /init.boot"; exec /init.boot
EOF
chmod 755 "$W/root/wrap.sh"

# The watchdog runs in the `kernel` SELinux domain. Until init loads the policy it may do anything;
# after that it may execute NOTHING (no execute_no_trans on any type), read no tmpfs file or node
# and write no block device -- but it may write /proc/sysrq-trigger, and may read and write the
# pipes it already holds. So, armed, it must not exec: `sleep` is mksh's builtin (unconditional in
# R59, not toybox's), the deadline is $SECONDS, and the dmesg snapshots (toybox) are attempted only
# while toybox is still executable. An earlier version did `toybox sleep` per tick; enforcing, every
# sleep failed instantly, the tick counter ran out in 50 ms and sysrq fired at 19.7 s into a
# healthy boot. (`read -t` on a coprocess is not a sleep either: mksh closes the coprocess on the
# first timeout.)
cat > "$W/root/watchdog.sh" <<EOF
exec 0</dev/null 1>/dev/kmsg 2>/dev/kmsg
T=/system/bin/toybox
echo "watchdog: armed, dmesg every ${EVERY}s, reboot at ${TIMEOUT}s"
n=0; snap=1
while [ \$SECONDS -lt $TIMEOUT ]; do
  sleep $EVERY
  [ \$snap = 1 ] && [ -x \$T ] || { [ \$snap = 1 ] && echo "watchdog: toybox no longer executable (enforcing); snapshots off, console comes from ramoops"; snap=0; continue; }
  n=\$((n + 1))
  { echo "DIAGLOG v1 snapshot=\$n uptime=\$(\$T cat /proc/uptime)"; \$T dmesg; echo "===== DIAGLOG END ====="; } > /log.txt 2>&1
  if [ -e /dev/misc ]; then
    \$T dd if=/dev/zero of=/dev/misc bs=4096 seek=$((SEEK + 256)) count=256 conv=notrunc 2>/dev/null
    \$T dd if=/log.txt of=/dev/misc bs=4096 seek=$((SEEK + 256)) count=256 conv=notrunc 2>/dev/null; \$T sync
  fi
done
echo "watchdog: timeout at \${SECONDS}s, last snapshot \$n"
if [ \$snap = 1 ] && [ -e /dev/misc ]; then
  # bootloader_message: command[32] at 0 = boot-recovery, recovery[768] at 64 = recovery\\n
  \$T dd if=/dev/zero of=/dev/misc bs=2048 count=1 conv=notrunc
  \$T printf boot-recovery | \$T dd of=/dev/misc conv=notrunc
  \$T printf 'recovery\\n' | \$T dd of=/dev/misc bs=1 seek=64 conv=notrunc
  \$T sync
  echo "watchdog: saved \$(\$T wc -c < /log.txt) bytes to misc, BCB armed, rebooting"
else
  echo "watchdog: enforcing, cannot reach misc; the next boot of this image saves this console and goes to recovery"
fi
sleep 2
echo b > /proc/sysrq-trigger
EOF

( cd "$W/root" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet ) > "$W/new.cpio"
case "$COMP" in
  gzip) gzip -9 -n < "$W/new.cpio" > "$W/new.rd" ;;
  xz)   xz --check=crc32 -T0 < "$W/new.cpio" > "$W/new.rd" ;;   # the kernel's xz accepts crc32 only
  lz4)  lz4 -l -9 < "$W/new.cpio" > "$W/new.rd" ;;
esac

cmdline="$(sed -n "s/.*--cmdline '\(.*\)'$/\1/p" <<<"$kargs")"
add="androidboot.init_fatal_reboot_target=recovery rdinit=/wrap.sh"
[ "$PERM" = 1 ] && add="androidboot.selinux=permissive $add"
[ -n "$CADD" ] && add="$CADD $add"
kargs="${kargs//"$W/b/ramdisk"/"$W/new.rd"}"
kargs="$(sed "s|--cmdline '.*'$|--cmdline '$cmdline $add'|" <<<"$kargs")"
eval "$HB/mkbootimg" $kargs --output "\"$OUT\""
rm -rf "$W"
echo ">> $OUT ($(stat -c %s "$OUT") bytes), ramdisk $COMP, cmdline += '$add'"
if [ "$PERM" = 1 ]; then
  echo ">> flash it to boot, let it loop/hang once (~$((TIMEOUT + 30)) s), enter recovery, then: $(basename "$0") pull console.txt --misc-offset-mib $OFF"
else
  echo ">> flash it to boot; it resets at ~$((TIMEOUT + 10)) s, boots once more and goes to recovery with that console saved (no DIAGLOG slot enforcing); then: $(basename "$0") pull console.txt --misc-offset-mib $OFF"
fi
