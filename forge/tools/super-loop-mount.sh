#!/usr/bin/env bash
# super-loop-mount.sh — mount a dynamic (logical) partition from recovery without device-mapper.
#
#   super-loop-mount.sh --list                       partitions, extents, byte offsets
#   super-loop-mount.sh <partition> <mountpoint> [ro|rw]      e.g. system_b /mnt/sysb rw
#
# Lineage recovery has no dmctl/lptools and no /dev/block/mapper. The metadata at the head of
# `super` says where each logical partition's extent sits, so: pull the first 4 MiB, `lpdump` it on
# the host, then `losetup -o OFFSET -S SIZE` on the raw super device and mount the loop. Rebuilt
# ext4 images have no shared_blocks, so rw works — edit the inactive slot's /system/etc/init in
# place, then unmount (toybox umount detaches the loop).
#
# Super device: ro.boot.super_partition + slot suffix if that node exists (Pixel 3a: system_b),
# else `super`. Metadata slot: 0 for a per-slot super, else from the suffix. SUPER_DEV / LP_SLOT
# override. Multi-extent partitions cannot be one loop device; --list shows them.
# Needs lpdump on the host: HOST_BIN or */out/host/linux-x86/bin under $ANDROID_SRC or
# ./build_output/src. Work files go to ./.super-loop-mount/.
set -u
ADB=(adb); [ "${1:-}" = -s ] && { ADB=(adb -s "$2"); shift 2; }
[ $# -ge 1 ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SRC="${ANDROID_SRC:-$PWD/build_output/src}"; HB="${HOST_BIN:-$SRC/out/host/linux-x86/bin}"
[ -x "$HB/lpdump" ] || { echo "!! no lpdump in $HB (set HOST_BIN)" >&2; exit 1; }
W="$PWD/.super-loop-mount"; mkdir -p "$W"

"${ADB[@]}" root >/dev/null 2>&1; sleep 1; "${ADB[@]}" wait-for-any-any
suffix="$("${ADB[@]}" shell getprop ro.boot.slot_suffix | tr -d '\r')"
superp="$("${ADB[@]}" shell getprop ro.boot.super_partition | tr -d '\r')"
DEV="${SUPER_DEV:-}"
if [ -z "$DEV" ]; then
  for cand in "${superp:+$superp$suffix}" "${superp}" super; do
    [ -n "$cand" ] || continue
    if "${ADB[@]}" shell "[ -e /dev/block/by-name/$cand ]" 2>/dev/null; then DEV="/dev/block/by-name/$cand"; break; fi
  done
fi
[ -n "$DEV" ] || { echo "!! cannot find the super device (set SUPER_DEV)" >&2; exit 1; }
if [ -z "${LP_SLOT:-}" ]; then
  case "$DEV" in *_a|*_b) LP_SLOT=0 ;; *) LP_SLOT=0; [ "$suffix" = _b ] && LP_SLOT=1 ;; esac
fi
"${ADB[@]}" exec-out "dd if=$DEV bs=1M count=4 2>/dev/null" > "$W/super-head.bin"
"$HB/lpdump" -s "$LP_SLOT" "$W/super-head.bin" > "$W/lpdump.txt" 2>&1 || { cat "$W/lpdump.txt" >&2; exit 1; }

# name -> "first..last linear blockdev sector" lines
extents() { awk -v n="$1" '
  /^  Name: /       { cur=$2 }
  /^    [0-9]+ \.\. [0-9]+ linear / { if (cur==n) print $1, $3, $5, $6 }' "$W/lpdump.txt"; }

if [ "$1" = --list ]; then
  echo "super: $DEV (metadata slot $LP_SLOT)"
  awk '/^  Name: /{n=$2} /^    [0-9]+ \.\. [0-9]+ linear /{printf "  %-16s %-10s off=%-12d size=%d\n", n, $5, $6*512, ($3-$1+1)*512}' "$W/lpdump.txt"
  exit 0
fi
P="$1"; MNT="$2"; MODE="${3:-ro}"
mapfile -t ex < <(extents "$P")
[ ${#ex[@]} -eq 1 ] || { echo "!! $P has ${#ex[@]} extent(s); need exactly one (see --list)" >&2; exit 1; }
read -r first last bdev sector <<<"${ex[0]}"
off=$((sector * 512)); size=$(( (last - first + 1) * 512 ))
loop="$("${ADB[@]}" shell "mkdir -p $MNT; losetup -f -s -o $off -S $size /dev/block/by-name/$bdev" | tr -d '\r')"
[ -n "$loop" ] || loop="$("${ADB[@]}" shell "losetup -a" | tr -d '\r' | awk -v o="$off" -F: '$0 ~ o {print $1; exit}')"
[ -n "$loop" ] || { echo "!! losetup gave no device" >&2; exit 1; }
"${ADB[@]}" shell "mount -t ext4 -o $MODE $loop $MNT && echo mounted $P on $MNT via $loop \($MODE, offset $off, $size bytes\) || { losetup -d $loop; exit 1; }"
