#!/usr/bin/env python3
# gen-verify-stubs.py -- emit minimal smali "verify stubs" for framework/vendor classes a ported app
# references but the target ROM lacks. The classes an OEM app expects in the boot classpath (LG's
# com.lge.* additions, vendor telephony extensions, ...) throw NoClassDefFoundError on a clean AOSP
# build. When the real classes are unavailable (or only matter for a service that does not exist on the
# new ROM), a stub that merely makes the dex VERIFY -- the right shape, the referenced members, safe
# default bodies -- lets the app load and run its lazy paths degrade gracefully (null service -> the
# app's own null-checks / try-catch). NOT for classes the app subclasses meaningfully or whose behavior
# it depends on at the point of use -- bundle the real (deodexed) class for those.
#
#   gen-verify-stubs.py --app <app-smali-dir> --out <extra-smali-dir> CLASS [CLASS ...]
#     CLASS as dotted (com.lge.lgdata.LGDataFeature) or slashed (com/lge/lgdata/LGDataFeature)
#
# For each class it scans the app smali for every referenced member and the invoke kind, then emits:
#   * invoke-interface seen, or an $Stub is referenced  -> interface (+ an abstract $Stub extends Binder
#     with asInterface()->null, the AIDL service-not-present path) with the called methods abstract;
#   * otherwise                                          -> a concrete class: default ctor, referenced
#     fields, and the called methods with safe-default bodies (a static factory returning the class's
#     own type yields a new instance so callers do not NPE; anything else returns null/0/void).
# Idempotent per file; skips a member set that is empty (bare type reference -> empty class/interface).
import argparse, os, re, sys

def slash(c): return c.replace('.', '/')

def scan(app, cls):
    methods, fields, invoke_kinds, has_stub, has_proxy = {}, {}, set(), False, False
    mre = re.compile(r'invoke-(interface|virtual|static|direct|super)(?:/range)?\s*\{[^}]*\},\s*L'+re.escape(cls)+r';->([^(]+)(\([^)]*\)\S+)')
    fre = re.compile(r'(s|i)(?:get|put)(?:-\w+)?\s+[vp0-9, ]*L'+re.escape(cls)+r';->([^:]+):(\S+)')
    stubre = re.compile(r'L'+re.escape(cls)+r'\$Stub;')
    proxre = re.compile(r'L'+re.escape(cls)+r'\$Stub\$Proxy;')
    for dp,_,fns in os.walk(app):
        for fn in fns:
            if not fn.endswith('.smali'): continue
            t = open(os.path.join(dp,fn), errors='ignore').read()
            for m in mre.finditer(t):
                kind, name, sig = m.group(1), m.group(2), m.group(3)
                methods[name+sig] = (name, sig, kind=='static'); invoke_kinds.add(kind)
            for m in fre.finditer(t):
                fields[m.group(2)] = (m.group(2), m.group(3), m.group(1)=='s')
            if stubre.search(t): has_stub = True
            if proxre.search(t): has_proxy = True
    return methods, fields, invoke_kinds, has_stub, has_proxy

def default_body(ret, selfcls, is_static_factory):
    # returns (registers_locals, body_lines)
    if ret == 'V':
        return 1, ['    return-void']
    if ret == selfcls and is_static_factory:   # getInstance()-style: hand back a live instance
        return 2, [f'    new-instance v0, {ret}', f'    invoke-direct {{v0}}, {ret}-><init>()V', '    return-object v0']
    if ret in ('Z','B','S','C','I'):
        return 1, ['    const/4 v0, 0x0', '    return v0']
    if ret == 'J':
        return 2, ['    const-wide/16 v0, 0x0', '    return-wide v0']
    if ret == 'F':
        return 1, ['    const/4 v0, 0x0', '    return v0']
    if ret == 'D':
        return 2, ['    const-wide/16 v0, 0x0', '    return-wide v0']
    return 1, ['    const/4 v0, 0x0', '    return-object v0']   # object/array

def param_words(sig):
    # count register words of the params in a smali signature "(...)ret": J/D take two, refs/prims one.
    inner = sig[sig.index('(')+1:sig.index(')')]
    words, i = 0, 0
    while i < len(inner):
        c = inner[i]
        if c == '[':
            i += 1; continue                 # array marker; the element type that follows is one ref word
        if c == 'L':
            i = inner.index(';', i) + 1; words += 1; continue
        words += 2 if c in 'JD' else 1; i += 1
    return words

def ctor():
    return ['.method public constructor <init>()V', '    .registers 1',
            '    invoke-direct {p0}, Ljava/lang/Object;-><init>()V', '    return-void', '.end method']

def emit_interface(cls, methods):
    L = [f'.class public interface abstract L{cls};', '.super Ljava/lang/Object;',
         '.implements Landroid/os/IInterface;', '']
    for name,sig,_ in sorted(methods.values()):
        L += [f'.method public abstract {name}{sig}', '.end method', '']
    return '\n'.join(L)+'\n'

def emit_stub(cls):
    s = cls+'$Stub'
    return '\n'.join([
        f'.class public abstract L{s};', '.super Landroid/os/Binder;', f'.implements L{cls};', '',
        '.method public constructor <init>()V', '    .registers 1',
        '    invoke-direct {p0}, Landroid/os/Binder;-><init>()V', '    return-void', '.end method', '',
        # service absent on this ROM -> asInterface hands back null; the app null-checks it.
        f'.method public static asInterface(Landroid/os/IBinder;)L{cls};', '    .registers 2',
        '    const/4 v0, 0x0', '    return-object v0', '.end method', ''])+'\n'

def emit_class(cls, methods, fields):
    L = [f'.class public L{cls};', '.super Ljava/lang/Object;', '']
    selftyped = []   # static fields whose type is the class itself == enum-constant pattern
    for name,typ,st in sorted(fields.values()):
        L.append(f'.field public {"static " if st else ""}{name}:{typ}')
        if st and typ == f'L{cls};': selftyped.append(name)
    L += ['']
    if selftyped:   # enum-like: initialize each self-typed constant to a live instance so reads/compares are non-null
        cl = ['.method static constructor <clinit>()V', f'    .registers 1']
        for nm in selftyped:
            cl += [f'    new-instance v0, L{cls};', f'    invoke-direct {{v0}}, L{cls};-><init>()V',
                   f'    sput-object v0, L{cls};->{nm}:L{cls};']
        cl += ['    return-void', '.end method']
        L += cl + ['']
    L += ctor(); L += ['']
    for name,sig,st in sorted(methods.values()):
        if name == '<init>': continue
        ret = sig.split(')')[1]
        locals_, body = default_body(ret, f'L{cls};', st and ret==f'L{cls};')
        total = locals_ + param_words(sig) + (0 if st else 1)   # locals + param words + this
        L += [f'.method public {"static " if st else ""}{name}{sig}', f'    .registers {total}'] + body + ['.end method','']
    return '\n'.join(L)+'\n'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--app', required=True); ap.add_argument('--out', required=True)
    ap.add_argument('classes', nargs='+')
    a = ap.parse_args()
    for raw in a.classes:
        cls = slash(raw).lstrip('L').rstrip(';')
        methods, fields, kinds, has_stub, has_proxy = scan(a.app, cls)
        is_iface = has_stub or ('interface' in kinds)
        d = os.path.join(a.out, os.path.dirname(cls)); os.makedirs(d, exist_ok=True)
        base = os.path.join(a.out, cls)
        if is_iface:
            open(base+'.smali','w').write(emit_interface(cls, methods))
            if has_stub: open(base+'$Stub.smali','w').write(emit_stub(cls))
            print(f'  iface {cls}  ({len(methods)} methods{" +$Stub" if has_stub else ""})')
        else:
            open(base+'.smali','w').write(emit_class(cls, methods, fields))
            print(f'  class {cls}  ({len(methods)} methods, {len(fields)} fields)')
            # Enum-like (self-typed constants + a scalar accessor / int factory): every constant here
            # returns the SAME code (0), so a `x.getCode() == EMERGENCY.getCode()` gate is always true
            # and a `fromInt(n) == CONST` identity compare always false. That silently redirects the
            # app's control flow (LG Ims4: isLteEmergencyOnly() became constant-true -> IMS APN blocked
            # forever). Copy the real names/ordinals/codes from the stock deodex for these.
            selftyped = [n for n,(n_,t,st) in fields.items() if st and t == f'L{cls};']
            scalar = [n for n,(n_,sig,st) in methods.items() if not st and sig.split(')')[1] in 'IJZ' and sig.startswith('()')]
            factory = [n for n,(n_,sig,st) in methods.items() if st and sig.split(')')[1] == f'L{cls};' and sig.startswith('(I)')]
            if selftyped and (scalar or factory):
                print(f'    !! enum-like {cls}: constants {sorted(selftyped)} with {sorted(set(scalar+factory))} -- '
                      f'all codes stub to 0; make the codes faithful or compares misfire', file=sys.stderr)
        if has_proxy: print(f'    !! $Stub$Proxy referenced for {cls} -- app may need a real proxy', file=sys.stderr)

if __name__ == '__main__': main()
