#!/usr/bin/env python3
"""stub-smali-method.py -- replace the body of named methods in a smali tree with a constant return,
to neutralise OEM code that depends on something the target platform does not have.

  stub-smali-method.py <smali-dir> <rules-file> [--dry-run]

Rules, one per line, `<class>-><method><sig><ret>|<value>` (`#` comments, blank lines ignored):

  Lcom/lge/ims/service/eab/EABContactHelper;->CheckLastCallCapability()Ljava/lang/String;|null
  Lcom/oem/Foo;->isFancyThingSupported()Z|false
  Lcom/oem/Foo;->doFancyThing(I)V|void

Values: `void`, `null`, `false`/`0`, `true`/`1`, `empty-string`.

Why not a verify stub or a call-site redirect: `gen-verify-stubs.py` invents a class the app
references but the ROM lacks, and `apply-method-redirects.py` repoints a call at a different
method. Neither helps when the class and method both exist and are *correct* -- they just reach for
a platform feature the OEM added and AOSP never had. The V20 case: after every call LG's EAB
(RCS presence) agent queries CallLog for `duration_video`, an LG-only column, the provider throws
IllegalArgumentException on its own thread with no catch, and because the app is persistent the whole
IMS process dies and restarts unable to re-register -- one working call per boot. Stubbing the one
method that touches it costs a feature that was already unusable.

Pick the return value from the CALLER, not from the signature: read the call site and choose the
value whose branch is the harmless one. Above, the caller does `if-eqz v2, :cond_87`, so null is
already its "nothing to do" path. A plausible-looking value that takes the other branch is worse
than the crash, because it fails silently.

Keeps `.annotation` and `.param` blocks (a dropped Throws annotation changes reflection and can
break callers), rewrites the body as `.locals 1` plus the return so register counts stay valid for
any signature, and is idempotent. Exits non-zero if a rule matches nothing, so a renamed method in
a later firmware is a build failure rather than a silent no-op.
"""
import os, re, sys

RET = {
    'void':         ('.locals 0', ['return-void']),
    'null':         ('.locals 1', ['const/4 v0, 0x0', 'return-object v0']),
    'false':        ('.locals 1', ['const/4 v0, 0x0', 'return v0']),
    '0':            ('.locals 1', ['const/4 v0, 0x0', 'return v0']),
    'true':         ('.locals 1', ['const/4 v0, 0x1', 'return v0']),
    '1':            ('.locals 1', ['const/4 v0, 0x1', 'return v0']),
    'empty-string': ('.locals 1', ['const-string v0, ""', 'return-object v0']),
}


def stub(path, method_sig, value, dry):
    src = open(path).read()
    # .method <modifiers> <name>(<args>)<ret>
    m = re.search(r'^\.method[^\n]*\s' + re.escape(method_sig) + r'\s*$', src, re.M)
    if not m:
        return False
    end = src.index('.end method', m.end())
    body = src[m.end():end]
    keep = []
    for blk in re.finditer(r'^[ \t]*\.(?:annotation|param)\b.*?(?:^[ \t]*\.end (?:annotation|param)[ \t]*$|$)',
                           body, re.M | re.S):
        keep.append(blk.group(0).rstrip())
    locals_line, insns = RET[value]
    new = '\n' + '\n'.join(keep + ['']) if keep else '\n'
    new += '    ' + locals_line + '\n\n'
    new += ''.join('    %s\n' % i for i in insns)
    if dry:
        print('   would stub %s -> %s in %s' % (method_sig, value, os.path.relpath(path)))
        return True
    open(path, 'w').write(src[:m.end()] + new + src[end:])
    print('   stubbed %s -> %s' % (method_sig, value))
    return True


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry = '--dry-run' in sys.argv
    if len(args) != 2:
        print(__doc__); sys.exit(2)
    root, rules_file = args
    if not os.path.isdir(root):
        sys.exit('!! no such smali dir: ' + root)
    missing = 0
    for raw in open(rules_file):
        line = raw.split('#')[0].strip()
        if not line:
            continue
        if '|' not in line:
            sys.exit('!! malformed rule (need <class>-><method>|<value>): ' + line)
        target, value = line.rsplit('|', 1)
        value = value.strip()
        if value not in RET:
            sys.exit('!! unknown return value %r (want: %s)' % (value, ', '.join(RET)))
        if '->' not in target:
            sys.exit('!! malformed rule: ' + line)
        cls, method_sig = target.split('->', 1)
        rel = cls.strip().lstrip('L').rstrip(';') + '.smali'
        path = os.path.join(root, rel)
        if not os.path.exists(path):
            print('!! no such class: %s' % rel); missing += 1; continue
        if not stub(path, method_sig.strip(), value, dry):
            print('!! %s has no method %s' % (rel, method_sig.strip())); missing += 1
    if missing:
        print('!! %d rule(s) matched nothing -- the app changed, fix the rules' % missing)
        sys.exit(1)


if __name__ == '__main__':
    main()
