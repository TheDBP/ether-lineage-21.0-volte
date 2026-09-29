#!/usr/bin/env python3
"""pmsg-decode.py — decode a pstore pmsg record into readable logcat text.

  pmsg-decode.py <pmsg-ramoops-N> [out.txt]

Decode a pstore pmsg record (the /dev/pmsg0 ring liblog writes every log line into) to
threadtime-style text. This is the last boot's logcat, including debuggerd tombstone output
(tag DEBUG) — the way to read a userspace crash from a boot that never brought up adb.
`logcat -L` does the same on a booted device; recovery has no logcat.

Record layout (packed, little-endian, from system/logging/liblog/include/private/android_logger.h):
  android_pmsg_log_header_t: u8 magic 'l', u16 len, u16 uid, u16 pid
  android_log_header_t:      u8 id, u16 tid, u32 sec, u32 nsec
  payload (main/system/radio/crash buffers): u8 prio, tag\\0, msg\\0
"""
import struct
import sys

PRIO = {2: 'V', 3: 'D', 4: 'I', 5: 'W', 6: 'E', 7: 'F', 8: 'S'}
TEXT_BUFS = {0, 1, 3, 4}  # main radio system crash


def records(data):
    i, skipped = 0, 0
    while i + 18 <= len(data):
        if data[i] != 0x6c:  # 'l'
            i += 1
            skipped += 1
            continue
        ln, uid, pid = struct.unpack_from('<HHH', data, i + 1)
        lid, tid, sec, nsec = struct.unpack_from('<BHII', data, i + 7)
        if ln < 18 or i + ln > len(data) or lid > 8:
            i += 1
            skipped += 1
            continue
        yield sec, nsec, uid, pid, tid, lid, data[i + 18:i + ln]
        i += ln
    if skipped:
        print(f'pmsg-decode: skipped {skipped} bytes', file=sys.stderr)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = open(sys.argv[1], 'rb').read()
    out = open(sys.argv[2], 'w') if len(sys.argv) > 2 else sys.stdout
    n = 0
    for sec, nsec, uid, pid, tid, lid, p in records(data):
        n += 1
        if lid in TEXT_BUFS and p:
            parts = p[1:].split(b'\0')
            tag = parts[0].decode('utf-8', 'replace')
            msg = (parts[1] if len(parts) > 1 else b'').decode('utf-8', 'replace').rstrip()
            out.write(f'{sec:>8}.{nsec // 1000000:03d} {pid:>5} {tid:>5} {PRIO.get(p[0], p[0])} {tag}: {msg}\n')
        else:
            out.write(f'{sec:>8}.{nsec // 1000000:03d} {pid:>5} {tid:>5} [buf{lid}] {p[:60]!r}\n')
    print(f'pmsg-decode: {n} records', file=sys.stderr)


if __name__ == '__main__':
    main()
