#!/usr/bin/env python3
"""
gen-legacy-aidl.py -- generate the org.codeaurora.ims.legacy AIDL from the stock 7.1 binary.

    gen-legacy-aidl.py <deodex-workdir> <out-aidl-dir> [iface ...]

These interfaces are one half of a binder contract whose other half is stock's compiled 2016 code.
AIDL numbers transactions by declaration order and marshals by parameter type, so both have to match
that binary exactly. Transcribing ~109 signatures by hand is where a silent, hardware-only failure
would come from -- so read them out of the smali instead: order from the $Stub's TRANSACTION_
constants, signatures from the interface's method descriptors.
"""
import os, re, sys

LEGACY_PKG = 'org.codeaurora.ims.legacy'

# Types that stay as they are. Everything under com/android/ims is ours and gets the renamed
# package; anything else must already exist on 13 or the generated AIDL will not compile.
PRIM = {'V': 'void', 'Z': 'boolean', 'B': 'byte', 'C': 'char', 'S': 'short',
        'I': 'int', 'J': 'long', 'F': 'float', 'D': 'double'}

def jtype(desc):
    """One smali type descriptor -> an AIDL type name."""
    arr = 0
    while desc.startswith('['):
        arr += 1
        desc = desc[1:]
    if desc in PRIM:
        base = PRIM[desc]
    elif desc.startswith('L') and desc.endswith(';'):
        cls = desc[1:-1]
        if cls.startswith('com/android/ims'):
            cls = LEGACY_PKG.replace('.', '/') + cls[len('com/android/ims'):]
        # Smali names a nested class Outer$Inner; AIDL writes it Outer.Inner, and only the OUTER
        # type is importable -- android.telecom.VideoProfile.aidl is what declares
        # "parcelable VideoProfile.CameraCapabilities".
        base = cls.replace('/', '.').replace('$', '.')
    else:
        raise ValueError('unhandled descriptor: ' + desc)
    return base + '[]' * arr

def shortname(t):
    """How the type is written in a signature: everything from the first capitalised segment on,
    so VideoProfile.CameraCapabilities survives while the package is dropped."""
    arr = '[]' * ((len(t) - len(t.replace('[]', ''))) // 2)
    base = t.replace('[]', '')
    parts = base.split('.')
    for i, seg in enumerate(parts):
        if seg[:1].isupper():
            return '.'.join(parts[i:]) + arr
    return base + arr

def outer(t):
    """Import target for a possibly-nested type: android.telecom.VideoProfile.CameraCapabilities
    imports as android.telecom.VideoProfile."""
    t = t.replace('[]', '')
    parts = t.split('.')
    for i, seg in enumerate(parts):
        if seg[:1].isupper():
            return '.'.join(parts[:i + 1])
    return t

def split_args(sig):
    """Split the argument section of a method descriptor into individual descriptors."""
    out, i = [], 0
    while i < len(sig):
        j = i
        while sig[j] == '[':
            j += 1
        if sig[j] == 'L':
            k = sig.index(';', j)
            out.append(sig[i:k + 1]); i = k + 1
        else:
            out.append(sig[i:j + 1]); i = j + 1
    return out

# AIDL needs a direction on anything that is not a primitive, a String, or another interface.
def direction(t, ifaces):
    simple = t.split('.')[-1]
    if t in PRIM.values() or t == 'String' or t == 'java.lang.String':
        return ''
    if simple in ifaces:
        return ''
    return 'in '

def locate(workdir, iface):
    """Most of these live in com/android/ims/internal, but ImsConfigListener sits one level up in
    com/android/ims. The output package has to follow, or the generated import will not resolve."""
    root = os.path.join(workdir, 'legacy', 'framework2', 'com', 'android', 'ims')
    for sub, pkg in (('internal', LEGACY_PKG + '.internal'), ('', LEGACY_PKG)):
        base = os.path.join(root, sub) if sub else root
        if os.path.exists(os.path.join(base, iface + '$Stub.smali')):
            return base, pkg
    raise SystemExit('!! missing smali for ' + iface)

def parse(workdir, iface):
    base, _ = locate(workdir, iface)
    stub = os.path.join(base, iface + '$Stub.smali')
    body = os.path.join(base, iface + '.smali')
    if not (os.path.exists(stub) and os.path.exists(body)):
        raise SystemExit('!! missing smali for ' + iface)
    order = {}
    for m in re.finditer(r'TRANSACTION_([A-Za-z0-9_]+):I = (0x[0-9a-f]+)', open(stub).read()):
        order[m.group(1)] = int(m.group(2), 16)
    sigs = {}
    for m in re.finditer(r'^\.method public abstract ([A-Za-z0-9_]+)\(([^)]*)\)(.+)$',
                         open(body).read(), re.M):
        sigs[m.group(1)] = (m.group(2), m.group(3))
    missing = set(order) - set(sigs)
    if missing:
        raise SystemExit('!! %s: transactions with no signature: %s' % (iface, sorted(missing)))
    return order, sigs

def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    workdir, outdir = sys.argv[1], sys.argv[2]
    ifaces = sys.argv[3:] or ['IImsCallSession', 'IImsCallSessionListener', 'IImsUt',
                              'IImsUtListener', 'IImsConfig', 'IImsEcbm', 'IImsEcbmListener',
                              'IImsMultiEndpoint', 'IImsVideoCallProvider',
                              'IImsExternalCallStateListener', 'IImsVideoCallCallback',
                              'ImsConfigListener']
    names = set(ifaces) | {'IImsService', 'IImsRegistrationListener'}
    os.makedirs(outdir, exist_ok=True)
    for iface in ifaces:
        order, sigs = parse(workdir, iface)
        _, pkg = locate(workdir, iface)
        lines, imports = [], set()
        for name in sorted(order, key=lambda k: order[k]):
            args, ret = sigs[name]
            rt = jtype(ret)
            ps = []
            for n, a in enumerate(split_args(args)):
                t = jtype(a)
                if '.' in t and not t.startswith('java.lang'):
                    imports.add(outer(t))
                ps.append('%s%s arg%d' % (direction(t, names), shortname(t), n))
            if '.' in rt and not rt.startswith('java.lang'):
                imports.add(outer(rt))
            lines.append('    %s %s(%s);' % (shortname(rt), name, ', '.join(ps)))
        sub = 'internal' if pkg.endswith('.internal') else ''
        dest = os.path.join(outdir, sub) if sub else outdir
        os.makedirs(dest, exist_ok=True)
        with open(os.path.join(dest, iface + '.aidl'), 'w') as f:
            f.write('package %s;\n\n' % pkg)
            for i in sorted(imports):
                f.write('import %s;\n' % i)
            f.write('\n/**\n * The 7.1 com.android.ims.internal.%s, renamed.\n'
                    ' *\n * GENERATED by gen-legacy-aidl.py from the stock 7.1 binary -- do not hand-edit.\n'
                    ' * Method order is transcribed from that binary\'s TRANSACTION_ constants and sets the\n'
                    ' * transaction codes; the far end cannot be recompiled to agree with a different order.\n */\n'
                    % iface)
            f.write('interface %s {\n' % iface)
            f.write('\n'.join(lines))
            f.write('\n}\n')
        print('  %-26s %2d methods' % (iface, len(order)))

main()
