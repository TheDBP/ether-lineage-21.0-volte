#!/usr/bin/env python3
"""apply-method-redirects.py -- rewrite framework-API-drift call sites in a smali tree from a rules file.

  apply-method-redirects.py <redirects.txt> <smali-dir>

Rules, one per line, `old|new` (`#` comments). Three forms:

  Lpkg/Cls;->old(Sig)Ret|Lpkg/Cls;->new(Sig)Ret
      literal swap, same signature -- a method the platform renamed (getSlotId -> getSlotIndex).
      Any literal text works (whole instructions, resource-id constants), as before.

  Lpkg/Cls;->m(Sig)Ret|static Lcompat/Cls;->m(Lpkg/Cls;Sig)Ret
      instance -> static: every `invoke-virtual|interface[/range] {regs}, old` becomes
      `invoke-static[/range] {regs}, new`. The register list is untouched: the receiver register that
      was `this` is now the first argument, so the replacement takes the receiver as its first param
      and the same arguments after it. For @hide methods the platform REMOVED (TelephonyManager.
      getPcscfAddress) -- a literal swap has nothing to point at; the compat static reimplements it.

  Lpkg/Cls;->m(Sig)Ret|drop
      delete the call (and a following move-result*): for void methods that no longer exist and
      whose effect the port does not need. Only for `V` returns -- refuse otherwise (callers read the
      result register).

Idempotent: re-running changes nothing. Prints every file touched per rule and refuses a rule that
matches nothing (a stale rule hides a regression -- remove it instead of carrying it).
"""
import os, re, sys

def main():
    if len(sys.argv) != 3:
        print(__doc__); sys.exit(2)
    rules_path, root = sys.argv[1], sys.argv[2]
    rules = []
    for ln in open(rules_path):
        ln = ln.rstrip('\n')
        if not ln.strip() or ln.lstrip().startswith('#'): continue
        if '|' not in ln: print(f"!! bad rule (no |): {ln}"); sys.exit(2)
        old, new = ln.split('|', 1)
        rules.append((old, new))
    files = [os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs if f.endswith('.smali')]
    rc = 0
    for old, new in rules:
        hit = 0
        if new.startswith('static '):
            tgt = new[len('static '):]
            pat = re.compile(r'invoke-(?:virtual|interface)(/range)?(\s+\{[^}]*\},\s*)' + re.escape(old))
            def sub(m): return f'invoke-static{m.group(1) or ""}{m.group(2)}{tgt}'
            already = re.compile(r'invoke-static(?:/range)?\s+\{[^}]*\},\s*' + re.escape(tgt))
        elif new == 'drop':
            if not old.endswith(')V'): print(f"!! drop is only for void methods: {old}"); sys.exit(2)
            pat = re.compile(r'^[ \t]*invoke-\w+(?:/range)?\s+\{[^}]*\},\s*' + re.escape(old) + r'[ \t]*\n(?:[ \t]*move-result[^\n]*\n)?', re.M)
            sub = ''; already = None
        else:
            pat = re.compile(re.escape(old)); sub = new.replace('\\', '\\\\'); already = re.compile(re.escape(new))
        for f in files:
            t = open(f, errors='surrogateescape').read()
            n = len(pat.findall(t))
            if n:
                open(f, 'w', errors='surrogateescape').write(pat.sub(sub, t)); hit += n
                print(f"   {os.path.relpath(f, root)}: {n}x {old.split('->')[-1] if '->' in old else old}")
            elif already is not None and already.search(t):
                hit += 1   # idempotent re-run: already rewritten
        if not hit:
            print(f"!! rule matched nothing: {old}"); rc = 1
    sys.exit(rc)

if __name__ == '__main__':
    main()
