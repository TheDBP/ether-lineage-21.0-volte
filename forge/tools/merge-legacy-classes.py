#!/usr/bin/env python3
# merge-legacy-classes.py -- make an old OEM app self-contained on a newer Android by renaming the
# removed framework package it depends on and merging that package's (clean) smali into the app's own.
#
#   merge-legacy-classes.py --app <app-smali-dir> --legacy <clean-legacy-smali-dir>[,<dir2>...]
#                           --old com/android/ims --new com/lge/imslegacy --out <merged-smali-dir>
#
# Why: a 2016 OEM app built against, say, com.android.ims (deleted/incompatible on the new release)
# cannot just run -- and it cannot keep the original package name either, because the new platform may
# still ship an INCOMPATIBLE com.android.ims. So rename every com.android.ims reference in the app to a
# private package, merge the renamed legacy classes in, and the app carries its own copy and needs no
# uses-library. (This is the Robin/ether IMS approach, generalized.)
#
# Two rules the rename respects, pulling opposite ways:
#   * type descriptors and AIDL descriptor strings MUST be renamed (an interface advertising the old
#     descriptor would do a binder call across an incompatible signature);
#   * broadcast action strings etc. must NOT be (they are wire contracts with other processes).
# The rule that separates them: rewrite a quoted string only when it EXACTLY names a legacy class.
#
# --legacy dirs must already be CLEAN smali (deodex-jar.sh, or AIDL regenerated via gen-legacy-aidl.py
# then compiled -- interface $Stub/$Proxy almost never deodex cleanly, regenerate those). Everything
# in them under --old is renamed and merged. Also redirects the @hide System.arraycopy type-specialized
# overloads (arraycopy([BI[BII)V and friends) to the public generic one -- a 2016 app calling the
# specialized form dies with IllegalAccessError on first call under hidden-API enforcement.
#
# Output is smali: assemble with smali.jar, drop into the apk, strip META-INF, ship via
# android_app_import certificate:platform (keeps the OEM sharedUserId valid). Keep output under .scratch.
import argparse, os, re, shutil, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--app', required=True, help='app smali dir (baksmali of its classes.dex)')
    ap.add_argument('--legacy', required=True, help='comma-separated clean legacy smali dirs')
    ap.add_argument('--old', required=True, help='old package path, e.g. com/android/ims')
    ap.add_argument('--new', required=True, help='new package path, e.g. com/lge/imslegacy')
    ap.add_argument('--out', required=True, help='output merged smali dir')
    a = ap.parse_args()
    OLD_P, NEW_P = a.old, a.new
    OLD_D, NEW_D = OLD_P.replace('/', '.'), NEW_P.replace('/', '.')

    # index legacy classes under OLD_P across all --legacy dirs
    idx = {}
    for base in a.legacy.split(','):
        for dp, _, fns in os.walk(base):
            for fn in fns:
                if fn.endswith('.smali'):
                    c = os.path.relpath(os.path.join(dp, fn), base)[:-6]
                    if c.startswith(OLD_P):
                        idx.setdefault(c, os.path.join(dp, fn))
    dotted = {c.replace('/', '.') for c in idx}
    print(f'legacy index: {len(idx)} classes under {OLD_P}')

    type_re = re.compile(r'L' + re.escape(OLD_P) + r'([A-Za-z0-9_/$]*);')
    str_re = re.compile(r'"([^"]*)"')
    def rewrite(txt):
        txt = type_re.sub(lambda m: 'L' + NEW_P + m.group(1) + ';', txt)
        return str_re.sub(lambda m: '"' + NEW_D + m.group(1)[len(OLD_D):] + '"' if m.group(1) in dotted else m.group(0), txt)

    shutil.rmtree(a.out, ignore_errors=True)
    shutil.copytree(a.app, a.out)
    for dp, _, fns in os.walk(a.out):
        for fn in fns:
            if fn.endswith('.smali'):
                p = os.path.join(dp, fn); t = open(p).read(); open(p, 'w').write(rewrite(t))
    for c, src in idx.items():
        d = os.path.join(a.out, NEW_P + c[len(OLD_P):] + '.smali')
        os.makedirs(os.path.dirname(d), exist_ok=True); open(d, 'w').write(rewrite(open(src).read()))

    spec = re.compile(r'Ljava/lang/System;->arraycopy\(\[[A-Z]I\[[A-Z]II\)V')
    nfix = 0
    for dp, _, fns in os.walk(a.out):
        for fn in fns:
            if fn.endswith('.smali'):
                p = os.path.join(dp, fn); t = open(p).read()
                if spec.search(t):
                    open(p, 'w').write(spec.sub('Ljava/lang/System;->arraycopy(Ljava/lang/Object;ILjava/lang/Object;II)V', t)); nfix += 1

    bad = [os.path.join(dp, fn) for dp, _, fns in os.walk(a.out) for fn in fns
           if fn.endswith('.smali') and ('L' + OLD_P) in open(os.path.join(dp, fn)).read()]
    print(f'merged {len(idx)} legacy classes; arraycopy-fixed {nfix} files; still referencing {OLD_P}: {len(bad)}')
    if bad:
        for b in bad[:10]: print('  STILL:', b)
        sys.exit(1)
    print('OK rename+merge clean ->', a.out)

if __name__ == '__main__':
    main()
