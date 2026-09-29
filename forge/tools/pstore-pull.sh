#!/usr/bin/env bash
# pstore-pull.sh — pull every pstore record from a phone in recovery, plus (optionally) the raw
# ramoops region behind it.
#
#   pstore-pull.sh <outdir> [--raw /dev/access-ramoops] [-s SERIAL]
#
# Needs `adb root` to work (Lineage recovery, or a userdebug boot). Mounts pstore if recovery did
# not. With --raw, dumps the given block/char device and unrolls every persistent_ram zone it finds
# (signature "DBGC") into <outdir>/raw-zone-N.txt — for when the kernel did not expose the region
# as pstore (a different dtbo, a region it only maps via an access node) or you want the ring after
# pstore already consumed it.
#
# What you will and will not find, on a device whose bootloader hard-resets on every reboot:
# console-ramoops-0 only if the region survived (see dtbo-ramoops-alt.py); dmesg-ramoops-N only
# after a kernel panic; pmsg-ramoops-0 wraps in seconds during a loop (docs/debugging-a-boot-loop.md).
set -u
OUT=""; RAW=""; SER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) RAW="$2"; shift 2 ;;
    -s) SER="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) OUT="$1"; shift ;;
  esac
done
[ -n "$OUT" ] || { echo "usage: pstore-pull.sh <outdir> [--raw DEV] [-s SERIAL]" >&2; exit 1; }
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")
mkdir -p "$OUT"

"${ADB[@]}" root >/dev/null 2>&1; sleep 1
"${ADB[@]}" wait-for-any-any
"${ADB[@]}" shell 'mount | grep -q " /sys/fs/pstore " || mount -t pstore pstore /sys/fs/pstore' >/dev/null 2>&1
files="$("${ADB[@]}" shell 'ls /sys/fs/pstore/ 2>/dev/null' | tr -d '\r')"
if [ -z "$files" ]; then
  echo "pstore: empty"
else
  for f in $files; do
    "${ADB[@]}" exec-out cat "/sys/fs/pstore/$f" > "$OUT/$f"
    printf '%-24s %8d bytes  %s\n' "$f" "$(stat -c %s "$OUT/$f")" \
      "$(grep -a -m1 -oE 'Linux version [^ ]+' "$OUT/$f" || true)"
    case "$f" in pmsg-*)   # last boot's logcat + tombstones, see pmsg-decode.py
      python3 "$(dirname "$0")/pmsg-decode.py" "$OUT/$f" "$OUT/$f.txt" && echo "  -> $f.txt";;
    esac
  done
fi

if [ -n "$RAW" ]; then
  "${ADB[@]}" exec-out "dd if=$RAW bs=1M 2>/dev/null" > "$OUT/raw.bin"
  echo "raw: $RAW -> $OUT/raw.bin ($(stat -c %s "$OUT/raw.bin") bytes)"
  python3 - "$OUT" <<'PY'
import struct, sys, os
out = sys.argv[1]; d = open(os.path.join(out, 'raw.bin'), 'rb').read()
SIG = 0x43474244  # "DBGC", persistent_ram_buffer.sig (fs/pstore/ram_core.c)
n = 0; p = 0
while p + 12 <= len(d):
    sig, start, size = struct.unpack_from('<III', d, p)
    if sig == SIG and size and start <= size <= len(d) - p - 12:
        data = d[p + 12:p + 12 + size]
        text = data[start:] + data[:start]           # unroll the ring
        name = os.path.join(out, 'raw-zone-%d.txt' % n)
        open(name, 'wb').write(text)
        kind = 'console?' if b'Linux version' in text[:4096] else ''
        print('  zone %d @0x%x: %d bytes used %s-> %s' % (n, p, size, kind, name))
        n += 1; p += 12 + size; p = (p + 3) & ~3
    else:
        p += 4
if not n: print('  no persistent_ram zones found (wrong device, or region not initialised)')
PY
fi
