#!/usr/bin/env python3
"""rc-fatal-services.py — which init services of a built image can take the device down, and whether they can start.

    rc-fatal-services.py <out>/target/product/<device> [--all]

Walks every .rc under system/, vendor/, odm/ and the flattened apex/*/etc/, and lists each service
marked `critical` (four deaths in the window -> reboot to bootloader/recovery) or `reboot_on_failure`
(one death -> that reboot target), with the rc file it comes from and whether its binary is in the
image. --all adds every other service whose binary is missing (init logs "cannot find" and moves on,
so these are silent feature losses, not loops).

Why this list and not logcat: these are the only services whose failure becomes a boot loop, and the
loop usually kills adbd before anything can be read. Knowing the ten or so names up front turns a
pstore/console dump into a search for "<name> exited" / "reboot,<target>", and gives you the set
to dry-run from recovery (see docs/debugging-a-boot-loop.md, "Looking ahead") before the flash.
Run check-dt-needed.py on the same tree: a fatal service whose binary has an unresolvable DT_NEEDED
is a guaranteed loop.
"""
import os, re, sys

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 1:
        print(__doc__); return 2
    root = args[0].rstrip('/'); show_all = '--all' in sys.argv
    rcs = []
    for base in ('system', 'vendor', 'odm', 'system_ext', 'product', 'apex'):
        for r, _, fs in os.walk(os.path.join(root, base)):
            rcs += [os.path.join(r, f) for f in fs if f.endswith('.rc')]
    svcs = []
    for p in sorted(set(rcs)):
        cur = None
        for line in open(p, errors='replace'):
            s = line.strip()
            if s.startswith('service '):
                parts = s.split()
                cur = dict(name=parts[1], path=parts[2] if len(parts) > 2 else '?', rc=os.path.relpath(p, root), fatal=[], disabled=False)
                svcs.append(cur)
            elif s.startswith(('on ', 'import ')) or not s or s.startswith('#'):
                if not (s.startswith('#')): cur = None
            elif cur is not None:
                if s.startswith(('critical', 'reboot_on_failure')): cur['fatal'].append(s)
                if s == 'disabled': cur['disabled'] = True
    def exists(path):
        path = path.lstrip('/')
        for pre in ('', 'system/'):
            if os.path.exists(os.path.join(root, pre + path)): return True
        if path.startswith('apex/'):   # /apex/<name>/bin/x lives under apex/<name>/ in the out tree
            return os.path.exists(os.path.join(root, path))
        return False
    fatal = [s for s in svcs if s['fatal']]
    print('>> %d services in %d rc files; %d can reboot the device:' % (len(svcs), len(set(rcs)), len(fatal)))
    bad = 0
    for s in sorted(fatal, key=lambda s: s['name']):
        ok = exists(s['path']) or s['path'] in ('/system/bin/false',)
        if not ok: bad += 1
        print('   %-28s %-48s %-38s %s%s' % (s['name'], s['path'], ' '.join(s['fatal'])[:38], 'MISSING-BINARY ' if not ok else '', s['rc']))
    if show_all:
        # a name defined twice (an apex rc with `override`, say) is fine when any definition resolves
        resolved = {s['name'] for s in svcs if exists(s['path'])}
        others = [s for s in svcs if not s['fatal'] and s['name'] not in resolved]
        print('\n>> %d non-fatal services whose binary is not in the image (init: "cannot find", feature silently absent):' % len(others))
        for s in sorted(others, key=lambda s: s['name']):
            print('   %-28s %-48s %s' % (s['name'], s['path'], s['rc']))
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
