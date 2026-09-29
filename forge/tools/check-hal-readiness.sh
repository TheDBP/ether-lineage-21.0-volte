#!/bin/bash
# check-hal-readiness.sh — find HAL problems BEFORE the build-flash-boot cycle.
#
#   ./tools/check-hal-readiness.sh <SRC> <DEVICE_PATH> [CODENAME]
#
#   SRC          a synced tree (built or not — more checks run if out/ exists)
#   DEVICE_PATH  e.g. device/nextbit/ether
#
# Why this exists: the ether 18.1 -> 20.0 port lost two full build-flash-boot cycles (~50 min each)
# to HAL problems that were visible on disk the whole time. A device manifest declared
# vendor.qti.hardware.cryptfshw, an interface lineage-20.0 deleted outright, and nothing complained
# until the build did. Separately, the framework's hard dependency on IDevicesFactory was knowable
# in advance -- we found it only when system_server blocked and the watchdog killed it.
#
# WHAT THIS CANNOT DO: it will not catch a HAL that exists, is declared, satisfies VINTF, and then
# SIGABRTs at runtime. The audio HAL on ether died with 'Binder threadpool cannot be shrunk after
# starting', which no static check can see. What this does is narrow the search: it tells you which
# HALs are load-bearing and which are declared-but-absent, so a boot hang has a shortlist.
#
# KNOWN FALSE POSITIVES -- verify a hit before acting on it:
#  * The impl inventory only scans vendor bin/lib dirs. A HAL served from /system (many AIDL
#    ones, e.g. wifi supplicant/hostapd) will be reported MISSING when it is fine.
#  * Matching is by substring on the interface name, so an oddly-named binary can be missed.
#  * 'framework-required but undeclared' reads every compatibility_matrix.N.xml present,
#    including levels this device does not target.
# The first version of this script also missed VINTF fragments entirely and wrongly reported
# power and health as undeclared on ether. Fragments are now parsed; the lesson stands --
# confirm on disk before you change a manifest.
set -o pipefail

SRC="${1:?usage: check-hal-readiness.sh <SRC> <DEVICE_PATH> [CODENAME]}"
DEV="${2:?usage: check-hal-readiness.sh <SRC> <DEVICE_PATH> [CODENAME]}"
CODENAME="${3:-$(basename "$DEV")}"
OUT="$SRC/out/target/product/$CODENAME"

[ -d "$SRC/$DEV" ] || { echo "!! no device tree at $SRC/$DEV" >&2; exit 1; }
echo "=== HAL readiness: $DEV (codename $CODENAME)"
[ -d "$OUT" ] && echo "    built output: $OUT" || echo "    no out/ yet — static checks only"
echo

python3 - "$SRC" "$DEV" "$OUT" <<'PY'
import os, re, sys, glob
import xml.etree.ElementTree as ET

src, dev, out = sys.argv[1], sys.argv[2], sys.argv[3]

def parse_manifest(p):
    """-> list of (name, version, [interfaces], transport)"""
    hals = []
    try:
        root = ET.parse(p).getroot()
    except Exception as e:
        return hals
    for hal in root.iter('hal'):
        name = (hal.findtext('name') or '').strip()
        transport = (hal.findtext('transport') or '').strip()
        fmt = hal.get('format', 'hidl')
        vers = [v.text.strip() for v in hal.findall('version') if v.text]
        # AIDL puts the version on the interface instead
        ifaces = [i.findtext('name', '').strip() for i in hal.findall('interface')]
        if name:
            hals.append((name, vers, ifaces, transport, fmt))
    return hals

def parse_matrix(p):
    """-> list of (name, optional?)  from a framework compatibility matrix"""
    req = []
    try:
        root = ET.parse(p).getroot()
    except Exception:
        return req
    for hal in root.iter('hal'):
        name = (hal.findtext('name') or '').strip()
        opt = hal.get('optional', 'true').lower() == 'true'
        if name:
            req.append((name, opt))
    return req

# --- device manifest: prefer the built one, fall back to the device tree ---
cand = [os.path.join(out, 'system/vendor/etc/vintf/manifest.xml'),
        os.path.join(out, 'vendor/etc/vintf/manifest.xml'),
        os.path.join(src, dev, 'manifest.xml')]
dm = next((c for c in cand if os.path.exists(c)), None)
if not dm:
    print("  !! no device manifest found"); sys.exit(0)
print(f"  device manifest: {dm.replace(src+'/','')}")
declared = parse_manifest(dm)

# VINTF FRAGMENTS. A service can ship its own manifest snippet (LOCAL_VINTF_FRAGMENTS) which is
# merged at runtime, so manifest.xml alone under-reports. Missing this produced false positives on
# ether: power and health looked undeclared but were declared by power.xml and
# android.hardware.health@2.1.xml in the fragment dir.
frag_dirs = [os.path.join(os.path.dirname(dm), 'manifest'),
             os.path.join(out, 'system/vendor/etc/vintf/manifest'),
             os.path.join(out, 'vendor/etc/vintf/manifest')]
nfrag = 0
for fd in frag_dirs:
    if os.path.isdir(fd):
        for f in sorted(glob.glob(os.path.join(fd, '*.xml'))):
            extra = parse_manifest(f)
            if extra:
                declared += extra; nfrag += 1
        break
print(f"  declares {len(declared)} HALs ({nfrag} from VINTF fragments)\n")

# --- inventory what actually got built ---
bins, libs = set(), set()
for d in ['system/vendor/bin/hw', 'vendor/bin/hw']:
    p = os.path.join(out, d)
    if os.path.isdir(p): bins |= set(os.listdir(p))
for d in ['system/vendor/lib64/hw', 'system/vendor/lib/hw', 'vendor/lib64/hw', 'vendor/lib/hw']:
    p = os.path.join(out, d)
    if os.path.isdir(p): libs |= set(os.listdir(p))

# --- CHECK 1: declared but no implementation on disk ---
print("  --- declared HALs with no implementation ---")
missing = []
if bins or libs:
    for name, vers, ifaces, transport, fmt in declared:
        if fmt == 'aidl':
            hit = any(name in b for b in bins)
        else:
            vs = vers or ['']
            hit = any(name in b for b in bins) or any(name in l for l in libs)
            if not hit:
                hit = any(f"{name}@{v}" in b for v in vs for b in bins) or \
                      any(f"{name}@{v}" in l for v in vs for l in libs)
        if not hit:
            missing.append((name, ','.join(vers) or '-', transport or fmt))
    if missing:
        for n, v, t in missing:
            print(f"    MISSING  {n} @{v} ({t})")
        print(f"    -> {len(missing)} declared with nothing to serve them. Each is a getService()")
        print("       that blocks or a VINTF failure. Remove from manifest.xml or provide the impl.")
    else:
        print("    none — every declared HAL has a binary or passthrough .so")
else:
    print("    (skipped — no built output to compare against)")

# --- CHECK 2: framework MANDATORY HALs the device does not declare ---
print("\n  --- framework-required HALs the device does not declare ---")
mats = glob.glob(os.path.join(out, 'system/etc/vintf/compatibility_matrix*.xml'))
declared_names = {n for n, *_ in declared}
if mats:
    hard = {}
    for m in mats:
        for n, opt in parse_matrix(m):
            if not opt:
                hard.setdefault(n, os.path.basename(m))
    gaps = [(n, f) for n, f in hard.items() if n not in declared_names]
    if gaps:
        for n, f in sorted(gaps):
            print(f"    REQUIRED {n}   (mandatory in {f})")
        print(f"    -> {len(gaps)} mandatory HAL(s) undeclared. These are the ones that block")
        print("       system_server: it waits on getService() and the watchdog kills it.")
    else:
        print("    none — all mandatory framework HALs are declared")
else:
    print("    (no compatibility matrix in out/ — build further to enable this check)")

# --- CHECK 3: which declared HALs are load-bearing ---
print("\n  --- declared HALs that the framework treats as MANDATORY (critical path) ---")
if mats:
    hardnames = set()
    for m in mats:
        hardnames |= {n for n, opt in parse_matrix(m) if not opt}
    crit = sorted(n for n in declared_names if n in hardnames)
    if crit:
        for n in crit:
            print(f"    critical  {n}")
        print("    -> if the boot hangs, suspect these first: a crash here blocks system_server.")
    else:
        print("    none flagged mandatory")
PY

# --- CHECK 4: AOSP's own checker, if the build got far enough ---
echo
echo "  --- checkvintf (AOSP's own compatibility check) ---"
CV="$SRC/out/host/linux-x86/bin/checkvintf"
DM="$OUT/system/vendor/etc/vintf/manifest.xml"
FM=$(ls "$OUT"/system/etc/vintf/compatibility_matrix*.xml 2>/dev/null | head -1)
if [ -x "$CV" ] && [ -d "$OUT/system" ]; then
  VEN="$OUT/system/vendor"; [ -d "$OUT/vendor" ] && VEN="$OUT/vendor"
  "$CV" --check-compat --dirmap /system:"$OUT/system" --dirmap /vendor:"$VEN" \
        --dirmap /odm:"$OUT/odm" --dirmap /product:"$OUT/product" \
        --dirmap /system_ext:"$OUT/system_ext" 2>&1 | head -20 | sed 's/^/    /' || true
else
  echo "    (skipped — need out/host/.../checkvintf and a built system image)"
fi

echo
echo "  NOTE: if PRODUCT_ENFORCE_VINTF_MANIFEST_OVERRIDE is true in device.mk, the build is NOT"
echo "  enforcing any of this. That flag is often set during bring-up and then forgotten."
grep -rn 'PRODUCT_ENFORCE_VINTF_MANIFEST_OVERRIDE' "$SRC/$DEV"/*.mk 2>/dev/null | sed 's/^/    /'
