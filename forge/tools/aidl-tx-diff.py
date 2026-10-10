#!/usr/bin/env python3
"""aidl-tx-diff.py -- compare the binder transaction tables of a stock framework's AIDL $Stub classes
(smali) with a directory of .aidl files (or a second smali tree), interface by interface.

  aidl-tx-diff.py <stub-smali-dir> <aidl-dir | smali-dir> [-v]
  aidl-tx-diff.py smali-fw/com/android/ims/internal  device/.../ims/bridge/aidl/com/lge/imslegacy/internal
  aidl-tx-diff.py smali-fw-lg/com/android/ims/internal  smali-fw-qti/com/android/ims/internal

Why: a bridge to an OEM's legacy IMS (or any removed @hide AIDL) is one half of a binder contract
whose other half is compiled into the OEM's binary. AIDL numbers transactions by declaration order,
so an interface that *looks* the same but has one method inserted (7.1 added IImsService.
addRegistrationListener at transaction 6 -- every later call on a 7.0 device lands on the wrong
method) fails only on hardware, silently. This answers whether another bridge's AIDL is reusable as is, in a
second, and is the build-time guard that the committed .aidl still matches the stock binary.

Left side: a package directory holding I*.smali and I*$Stub.smali (from oat-to-smali.sh /
deodex-jar.sh; TRANSACTION_ constants survive quickening). Right side: a directory of I*.aidl
(declaration order = transaction order, parameter count from the signature) or another smali
package directory. Compares, per transaction code, the method name and the parameter count.
Interfaces present on only one side are listed, not counted as failures (OEM *Ex extensions the
framework never calls are expected). Exit 1 if any shared interface differs.
"""
import glob, os, re, sys

def smali_params(desc):
    n = 0; i = 0
    while i < len(desc):
        c = desc[i]
        if c == '[': i += 1; continue
        if c == 'L': i = desc.index(';', i) + 1
        else: i += 1
        n += 1
    return n

def from_smali(d):
    out = {}
    for stub in sorted(glob.glob(os.path.join(d, 'I*$Stub.smali'))):
        iface = os.path.basename(stub)[:-len('$Stub.smali')]
        tx = {}
        for m in re.finditer(r'TRANSACTION_([A-Za-z0-9_]+):I = (0x[0-9a-f]+)', open(stub).read()):
            tx[int(m.group(2), 16)] = m.group(1)
        meth = {}
        ipath = os.path.join(d, iface + '.smali')
        if os.path.exists(ipath):
            for m in re.finditer(r'\.method public abstract ([A-Za-z0-9_$]+)\(([^)]*)\)', open(ipath).read()):
                meth.setdefault(m.group(1), smali_params(m.group(2)))
        out[iface] = {k: (v, meth.get(v)) for k, v in tx.items()}
    return out

def from_aidl(d):
    out = {}
    for p in sorted(glob.glob(os.path.join(d, 'I*.aidl'))):
        body = open(p).read()
        body = re.sub(r'/\*.*?\*/', '', body, flags=re.S); body = re.sub(r'//.*', '', body)
        if '{' not in body: continue
        inner = body[body.index('{') + 1:body.rindex('}')]
        tx = {}
        for stmt in inner.split(';'):
            m = re.search(r'([A-Za-z0-9_$]+)\s*\(([^)]*)\)', stmt)
            if not m: continue
            args = m.group(2).strip()
            tx[len(tx) + 1] = (m.group(1), 0 if not args else args.count(',') + 1)
        out[os.path.basename(p)[:-5]] = tx
    return out

def main():
    a = [x for x in sys.argv[1:] if not x.startswith('-')]; verbose = '-v' in sys.argv
    if len(a) != 2: print(__doc__); sys.exit(2)
    L = from_smali(a[0])
    R = from_smali(a[1]) if glob.glob(os.path.join(a[1], 'I*$Stub.smali')) else from_aidl(a[1])
    if not L: print(f'!! no I*$Stub.smali in {a[0]}'); sys.exit(2)
    if not R: print(f'!! no I*.aidl or I*$Stub.smali in {a[1]}'); sys.exit(2)
    bad = 0
    for iface in sorted(set(L) | set(R)):
        if iface not in R: print(f'   {iface}: {len(L[iface])} tx -- only on the left (OEM extension?)'); continue
        if iface not in L: print(f'   {iface}: {len(R[iface])} tx -- only on the right'); continue
        l, r = L[iface], R[iface]
        diffs = []
        for k in sorted(set(l) | set(r)):
            ln, lp = l.get(k, (None, None)); rn, rp = r.get(k, (None, None))
            if ln != rn or (lp is not None and rp is not None and lp != rp):
                diffs.append(f'      tx {k}: left {ln}/{lp} right {rn}/{rp}')
        tag = 'OK ' if not diffs else '!! '
        print(f'{tag}{iface}: left {len(l)} tx, right {len(r)} tx, {len(diffs)} difference(s)')
        if diffs: bad += 1
        for s in (diffs if not verbose else diffs or [f'      {k}: {l[k][0]}' for k in sorted(l)]): print(s)
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
