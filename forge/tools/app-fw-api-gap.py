#!/usr/bin/env python3
# app-fw-api-gap.py -- preflight a ported app against a target framework: list the framework methods
# and classes the app's dex references that the target does NOT have. These are the NoSuchMethodError
# and NoClassDefFoundError it will throw at runtime -- found statically, in one pass, instead of one
# reboot each. For bringing an old OEM app (an IMS stack, a settings app) onto a newer Android.
#
#   app-fw-api-gap.py --app <app-smali-dir> --fw <framework.jar|dir|smali-dir>[,<more>...] [--pkg android,javax,...]
#
# Build the target method/class DB from the jars you pass to --fw. ACCURACY DEPENDS ON COMPLETENESS:
# pass EVERY jar that holds the APIs the app calls, or you get false "missing" hits. On modern Android
# that means framework.jar (all of classes.dex..classesN.dex -- it is multidex; a partial disassemble
# is the classic mistake) PLUS the mainline apex javalibs the API moved into (telephony, etc.) and the
# other /system/framework/*.jar. Point --fw at the built out/target/product/<d>/system/framework and
# the apex /javalib, or pull them off the device.
#
#   app-fw-api-gap.py --app smali-ims4 --fw out/target/product/vs995/system/framework
#
# A .jar/.dex is disassembled (all dexes) with baksmali; a dir is searched for .jar/.dex and also used
# directly if it already contains .smali. --pkg limits which reference packages are checked (default
# android,javax -- the core framework, where drift concentrates; com/android/internal is noisier).
#
# Reports two lists: methods whose CLASS is in the DB but the method is not (real NoSuchMethod), and
# referenced classes in the --pkg namespaces absent from the DB (NoClassDef -- but a class the app
# itself defines, or one in a jar you did not pass, is a false positive, so eyeball these).
#
# Needs baksmali.jar (BUILD_ROOT/.../extract-tools/common/smali, or $BAKSMALI). Keep output in .scratch.
import argparse, os, re, subprocess, sys, tempfile, glob

def baksmali_jar(jar, outdir, bk):
    subprocess.run(['java', '-jar', bk, 'd', jar, '-o', outdir], stderr=subprocess.DEVNULL, check=False)

def collect_db(fw_args, bk, work):
    methods, classes, supers = set(), set(), {}
    smali_dirs = []
    for arg in fw_args:
        if os.path.isdir(arg) and not glob.glob(os.path.join(arg, '*.jar')) and not glob.glob(os.path.join(arg, '*.dex')) \
           and any(f.endswith('.smali') for _, _, fs in os.walk(arg) for f in fs):
            smali_dirs.append(arg); continue
        targets = [arg] if os.path.isfile(arg) else \
                  glob.glob(os.path.join(arg, '*.jar')) + glob.glob(os.path.join(arg, '*.dex'))
        for t in targets:
            d = os.path.join(work, os.path.basename(t) + '.smali')
            baksmali_jar(t, d, bk); smali_dirs.append(d)
    for base in smali_dirs:
        for dp, _, fns in os.walk(base):
            for fn in fns:
                if not fn.endswith('.smali'): continue
                cls = 'L' + os.path.relpath(os.path.join(dp, fn), base)[:-6] + ';'
                classes.add(cls)
                for l in open(os.path.join(dp, fn), errors='ignore'):
                    m = re.match(r'\.method .*?([A-Za-z0-9_<>$]+\([^)]*\)\S+)\s*$', l)
                    if m: methods.add(cls + '->' + m.group(1))
                    elif l.startswith('.super '): supers[cls] = l.split()[1].strip()
    return methods, classes, supers

# Walk C and its ancestors (in the DB) for method `sig`. Returns:
#   'ok'    - found on C or an ancestor
#   'miss'  - the full ancestry is in the DB and none define it (a real NoSuchMethod)
#   'unknown' - the chain leaves the DB (ancestor not disassembled: java.lang.Object, a mainline
#               class, ...) so we cannot be sure -- do NOT flag, to avoid false positives.
def resolve(cls, sig, methods, classes, supers):
    seen = set()
    while cls and cls not in seen:
        seen.add(cls)
        if cls + '->' + sig in methods: return 'ok'
        if cls not in classes: return 'unknown'   # ancestor we do not have
        cls = supers.get(cls)
    return 'miss'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--app', required=True, help='app smali dir (baksmali of its classes.dex)')
    ap.add_argument('--fw', required=True, help='comma-separated framework jars/dirs to build the DB from')
    ap.add_argument('--pkg', default='android,javax', help='reference package prefixes to check')
    a = ap.parse_args()
    bk = os.environ.get('BAKSMALI')
    if not bk:
        c = os.path.join(os.environ.get('BUILD_ROOT', os.path.join(os.path.dirname(__file__), '..', '..', 'build_output')),
                         'src/prebuilts/extract-tools/common/smali/baksmali.jar')
        bk = c if os.path.exists(c) else None
    if not bk or not os.path.exists(bk): sys.exit('!! baksmali.jar not found; set BAKSMALI=')
    pkgs = tuple('L' + p.strip().replace('.', '/') for p in a.pkg.split(','))

    with tempfile.TemporaryDirectory(prefix='app-fw-gap.', dir=os.path.dirname(os.path.abspath(a.app))) as work:
        meth, cls, sup = collect_db(a.fw.split(','), bk, work)
    print(f'target DB: {len(meth)} methods, {len(cls)} classes', file=sys.stderr)

    local = set()
    for dp, _, fns in os.walk(a.app):
        for fn in fns:
            if fn.endswith('.smali'): local.add('L' + os.path.relpath(os.path.join(dp, fn), a.app)[:-6] + ';')

    inv = re.compile(rb'(L[A-Za-z0-9_/$]+;->[A-Za-z0-9_<>$]+\([^)]*\)\S+)')
    clsref = re.compile(rb'(L[A-Za-z0-9_/$]+;)')
    badm, badc = {}, {}
    for dp, _, fns in os.walk(a.app):
        for fn in fns:
            if not fn.endswith('.smali'): continue
            rel = os.path.relpath(os.path.join(dp, fn), a.app)[:-6]
            data = open(os.path.join(dp, fn), 'rb').read()
            for m in re.finditer(inv, data):
                ref = m.group(1).decode()
                if not ref.startswith(pkgs): continue
                c, sig = ref.split('->')
                if c in cls and resolve(c, sig, meth, cls, sup) == 'miss':
                    badm.setdefault(ref, set()).add(rel)
            for m in re.finditer(clsref, data):
                c = m.group(1).decode()
                if not c.startswith(pkgs): continue
                base = c.split('$')[0]; base = base if base.endswith(';') else base + ';'
                if base not in cls and base not in local: badc.setdefault(base, set()).add(rel)

    print(f"\n=== NoSuchMethod risks (class present, method absent): {len(badm)}")
    for r in sorted(badm): print(f"  {r}   [{len(badm[r])} file(s)]")
    print(f"\n=== NoClassDef risks ({a.pkg} class referenced, absent from DB -- verify your --fw is complete): {len(badc)}")
    for c in sorted(badc): print(f"  {c}")

if __name__ == '__main__':
    main()
