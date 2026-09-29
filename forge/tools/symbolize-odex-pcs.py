#!/usr/bin/env python3
# Turn the bare "pc 0000000002430 70c  /system/framework/oat/arm64/services.odex" frames of an
# ANR/tombstone native dump into Java method names.
#
# Dex-preopted framework code (services.odex etc.) is built with NoDebugInfo, so debuggerd cannot
# name the frame and prints only the file offset. oatdump knows the method table; its code_offset
# values are relative to the oatdata symbol, which sits at file offset 0x1000 in every odex seen so
# far (check: readelf -s FILE.odex | grep oatdata). Override with OATDATA=0x... if it differs.
#
#   out/host/linux-x86/bin/oatdump --oat-file=$OUT/system/framework/oat/arm64/services.odex \
#       --dex-file=$OUT/system/framework/services.jar --no-disassemble --no-dump:vmap > services-oatdump.txt
#   tools/symbolize-odex-pcs.py services-oatdump.txt 243070c 1c4d758 ...
#
# oatdump must come from the same tree as the odex (oat format versions are not compatible across
# branches; `m oatdump` builds the host binary in ~3 min). Confirm the BuildId in the dump matches
# the odex first.
import bisect, os, re, sys

if len(sys.argv) < 3:
    sys.exit(f"usage: {sys.argv[0]} <oatdump-listing> <pc-hex>...")
OATDATA = int(os.environ.get("OATDATA", "0x1000"), 16)
dump, pcs = sys.argv[1], [int(x, 16) for x in sys.argv[2:]]

meths, cur = [], None
for line in open(dump, errors="replace"):
    m = re.match(r"^  \d+: (\S.*) \(dex_method_idx=\d+\)", line)
    if m:
        cur = m.group(1)
        continue
    m = re.match(r"^    CODE: \(code_offset=0x([0-9a-f]+) size=(\d+)\)", line)
    if m and cur:
        meths.append((int(m.group(1), 16), int(m.group(2)), cur))
meths.sort()
starts = [m[0] for m in meths]

for pc in pcs:
    off = pc - OATDATA
    i = bisect.bisect_right(starts, off) - 1
    if i >= 0 and off < meths[i][0] + meths[i][1] + 16:  # +16: return address may sit just past the end
        print(f"{pc:#x}  {meths[i][2]}+{off - meths[i][0]:#x}")
    else:
        print(f"{pc:#x}  ?")
