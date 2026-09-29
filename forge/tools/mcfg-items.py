#!/usr/bin/env python3
"""mcfg-items.py — list the EFS items a Qualcomm MCFG provisions, with their values.

  mcfg-items.py mcfg_sw.mbn              # every EFS item: path, size, value
  mcfg-items.py mcfg_sw.mbn --extract D  # also write each value to D/<flattened path>

WHY

An MCFG is not firmware. It is a container of NV/EFS item values -- a carrier's modem
configuration. So when a feature works on one device and not another with the same modem, the
difference is usually in here, and it can be read without flashing anything.

That matters because the alternative is replacing a modem partition, and on these platforms that
partition is one filesystem holding the modem AND the audio DSP, the Wi-Fi firmware, keymaster and
widevine. Cross-flashing it takes out four subsystems to change one. Pulling the items out of the
MCFG and writing just the ones that differ (see diag-efs.sh) changes exactly what you meant to.

LAYOUT

Derived by anchoring on items whose value was already known on a live device, not from a spec --
IMS_enable and wlan_offload_config both matched, which is what makes the rest believable:

  u32 total       size including this field, so next item = start + total
  u8  type        0x01 = NV id item, 0x02 = EFS file item
  u8  0x19  u16 0  u16 0x0001
  u16 name_len    includes the NUL
  char name[name_len]
  u16 0x0002
  u16 data_len
  u8  attr        0x07 on every item seen
  u8  value[data_len - 1]

The payload sits inside an ELF wrapper; find it by the "MCFG" magic rather than by parsing the ELF.
"""
import os
import re
import struct
import sys


def items(path):
    d = open(path, 'rb').read()
    h = d.index(b'MCFG')
    fmt, cfg, n = struct.unpack_from('<HHI', d, h + 4)
    out = []
    p = h + 0x18
    for _ in range(n):
        if p + 4 > len(d):
            break
        total = struct.unpack_from('<I', d, p)[0]
        if total < 8 or p + total > len(d):
            break
        if d[p + 4] == 2:
            q = p + 10
            if q + 2 <= len(d):
                nl = struct.unpack_from('<H', d, q)[0]
                q += 2
                if q + nl + 4 <= len(d):
                    raw = d[q:q + nl].rstrip(b'\x00')
                    q += nl + 2
                    dl = struct.unpack_from('<H', d, q)[0]
                    q += 2
                    name = raw.decode('ascii', 'replace')
                    # A misparse shows up as a name full of binary; skip rather than emit rubbish.
                    if re.fullmatch(r'[ -~]+', name or ''):
                        out.append((name, d[q + 1:q + dl]))
        p += total
    return fmt, cfg, n, out


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    path = sys.argv[1]
    dest = None
    if '--extract' in sys.argv:
        dest = sys.argv[sys.argv.index('--extract') + 1]
        os.makedirs(dest, exist_ok=True)

    fmt, cfg, n, rows = items(path)
    print("format=%d config_type=%d declared_items=%d efs_items=%d" % (fmt, cfg, n, len(rows)))
    for name, val in rows:
        dec = ' = %d' % int.from_bytes(val, 'little') if 1 <= len(val) <= 4 else ''
        printable = all(32 <= b < 127 or b in (10, 13) for b in val) and len(val) > 4
        shown = '<text>' if printable else (val.hex() if len(val) <= 12 else val[:12].hex() + '..')
        print("%-58s %5d  %-26s%s" % (name, len(val), shown, dec))
        if dest:
            with open(os.path.join(dest, name.strip('/').replace('/', '__')), 'wb') as fh:
                fh.write(val)
    if dest:
        print(">> wrote %d item values to %s" % (len(rows), dest))
    return 0


if __name__ == '__main__':
    sys.exit(main())
