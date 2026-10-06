#!/usr/bin/env python3
"""gen-option-index.py -- render the options table into any README that asks for one, from
forge/options/ on disk, so it cannot drift from the options that actually exist.

  gen-option-index.py [--check] <README.md> [...]      --check: exit 1 if any file is stale

Why: six repos each hand-maintained a copy of this table and all six had drifted -- different
subsets of the options, and a "branches with patches" column that told people the whole
look-and-behaviour set was unavailable on lineage-24.0 months after it landed. The data is already
machine-readable (option.conf, patches/<branch>/), so nobody should be retyping it.

A file opts in by carrying markers; everything between them is replaced:

    <!-- options:start -->          every option, with a "branches with patches" column
    <!-- options:end -->

    <!-- options:start device -->   only the options usable on THIS repo's branch, no branch column
    <!-- options:end -->

`device` reads BRANCH from the device.conf beside the README and keeps an option when its COMPAT
admits that branch and it either needs no patches or has them for it. The branch is read rather
than written into the marker so a branch bump cannot leave the two disagreeing.

Descriptions come from DESC in option.conf. Two kinds of caveat get appended:

  NOTE= in option.conf          true of the option everywhere ("never hand out an image with this")
  options-notes.conf in the     true of the option ON THIS DEVICE ("no LG pack exists"), as
  device repo, `option = text`  `option = text` lines. These are NOT derivable from the forge and
                                are the reason this tool merges rather than overwrites.
"""
import os, re, sys

MARK = re.compile(r'^(?P<open><!--\s*options:start(?P<mode>[^>]*?)-->)\s*$.*?^(?P<close><!--\s*options:end\s*-->)\s*$',
                  re.M | re.S)


def _conf(path):
    """KEY=value / KEY="value" out of an option.conf. Not shell: only the fields we document."""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return out


def _branch_key(b):
    try:
        return [int(x) for x in b.split('.')]
    except ValueError:
        return [999]


def scan(forge):
    """Every option on disk: its description, caveat, branch coverage and compatibility."""
    odir = os.path.join(forge, 'options')
    opts = {}
    for name in sorted(os.listdir(odir)):
        conf = os.path.join(odir, name, 'option.conf')
        if not os.path.isfile(conf):
            continue
        c = _conf(conf)
        # The same list apply-overlay.sh checks: an option with no patches for a branch is still
        # usable there if it contributes anything else. fdroid patches vendor/lineage on 22.2 but on
        # 20.0 only needs to fetch the APK, and it ships in that build.
        parts = ('fetch.sh', 'product.mk', 'build-env', 'assets.list', 'tree', 'require.sh',
                 'post-patch.sh', 'post-build.sh', 'local_manifests')
        other = any(os.path.exists(os.path.join(odir, name, p)) for p in parts)
        pdir = os.path.join(odir, name, 'patches')
        branches = sorted((d.replace('lineage-', '') for d in os.listdir(pdir)
                           if d.startswith('lineage-')), key=_branch_key) if os.path.isdir(pdir) else []
        opts[name] = {
            'desc': c.get('DESC', '').replace('--', '—'),
            'note': c.get('NOTE', '').replace('--', '—'),
            'requires': c.get('REQUIRES', ''),
            # Absent COMPAT means all: apply-overlay.sh reads it as "${COMPAT:-all}".
            'compat': c.get('COMPAT', 'all'),
            'branches': branches,
            'other': other,
        }
    return opts


def usable_on(o, branch):
    """Would apply-overlay.sh stage this option on that branch?

    Not "does it have patches for it". Only COMPAT excludes an option outright; missing patches
    for a branch are fatal just when the option has no other way to contribute there, which is
    exactly the condition apply-overlay.sh errors on.
    """
    if o['compat'] != 'all':
        allowed = {p.split('=', 1)[1] for p in o['compat'].split(',') if p.startswith('branch=')}
        if branch not in allowed:
            return False
    if not o['branches'] or branch.replace('lineage-', '') in o['branches']:
        return True
    return o['other']


def cell(name, o, notes):
    """The description cell: generic text, then the caveats, each a sentence of its own."""
    parts = [o['desc'].rstrip(' .')]
    if o['requires']:
        parts.append('Pulls in ' + ', '.join('`%s`' % r for r in re.split(r'[,\s]+', o['requires']) if r))
    if o['note']:
        parts.append(o['note'].rstrip(' .'))
    if name in notes:
        parts.append(notes[name].rstrip(' .'))
    return '. '.join(p for p in parts if p) + '.'


def table(opts, notes, branch):
    if branch:
        names = [n for n in opts if usable_on(opts[n], branch)]
        rows = ['| option | what it does |', '|---|---|']
        rows += ['| `%s` | %s |' % (n, cell(n, opts[n], notes)) for n in names]
    else:
        rows = ['| option | what it does | branches with patches |', '|---|---|---|']
        for n in opts:
            b = ', '.join(opts[n]['branches']) if opts[n]['branches'] else 'any'
            rows.append('| `%s` | %s | %s |' % (n, cell(n, opts[n], notes), b))
    return '\n'.join(rows)


def render(path, opts):
    src = open(path, encoding='utf-8').read()
    m = MARK.search(src)
    if not m:
        return None, 'no options:start/end markers'
    repo = os.path.dirname(os.path.abspath(path))
    branch = None
    if 'device' in m.group('mode'):
        dc = _conf(os.path.join(repo, 'device.conf'))
        branch = dc.get('BRANCH')
        if not branch:
            return None, 'marker says device, but device.conf has no BRANCH'
    notes = {}
    npath = os.path.join(repo, 'options-notes.conf')
    if os.path.isfile(npath):
        for line in open(npath, encoding='utf-8'):
            line = line.split('#', 1)[0].strip()
            if '=' in line:
                k, v = line.split('=', 1)
                notes[k.strip()] = v.strip().replace('--', '—')
    unknown = sorted(set(notes) - set(opts))
    if unknown:
        return None, 'options-notes.conf names options that do not exist: ' + ', '.join(unknown)
    body = '%s\n\n%s\n\n%s' % (m.group('open'), table(opts, notes, branch), m.group('close'))
    return src[:m.start()] + body + src[m.end():], None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    check = '--check' in sys.argv
    if not args:
        print(__doc__)
        sys.exit(2)
    forge = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    opts = scan(forge)
    stale = 0
    for path in args:
        if not os.path.isfile(path):
            print('!! no such file: %s' % path, file=sys.stderr)
            sys.exit(2)
        new, err = render(path, opts)
        if err:
            # No markers is not an error: a repo opts in by adding them.
            if err.startswith('no options'):
                continue
            print('!! %s: %s' % (path, err), file=sys.stderr)
            sys.exit(2)
        if new == open(path, encoding='utf-8').read():
            continue
        stale += 1
        if check:
            print('!! %s: options table is stale -- run gen-option-index.py %s' % (path, path), file=sys.stderr)
        else:
            open(path, 'w', encoding='utf-8').write(new)
            print('   rewrote options table in %s' % path)
    if check and stale:
        sys.exit(1)


if __name__ == '__main__':
    main()
