#!/usr/bin/env bash
# dedup-shared-inputs.sh — collapse identical large build INPUTS across device repos to hardlinks.
#
#   dedup-shared-inputs.sh [--dry-run] [--min-size BYTES] [DIR ...]
#
# WHY
#
# The same proprietary input gets dropped into several device repos: a stock ROM for the oem option, a
# GApps zip, a Magisk APK. Each copy is a gigabyte or more and they are byte-identical, because they
# are downloads, not products. Five copies of one 1.2 GB stock ROM is 6 GB of one file.
#
# Hardlinks cost nothing and there is no "original": the data survives while any one link remains, so
# a copy kept outside the repos survives every repo being deleted. That is the point -- link the
# keeper you care about, then the throwaway copies are free.
#
# WHAT IT REFUSES TO TOUCH, and why that matters more than what it does
#
# Never anything under .repo/, build_output/, src/out/ or .git/. Those trees are repo- and
# build-managed:
#
#   - `repo sync` REPLACES files rather than editing them, so a link inside a synced tree breaks at
#     the next sync and the saving silently evaporates. Deduping there is a treadmill.
#   - anything that writes in place would corrupt every tree sharing the inode at once.
#   - repo already has the supported mechanism (--reference / --dissociate). Hand-linking inside a
#     repo-managed tree fights it.
#
# So this is for inputs you placed by hand, at repo roots. 50 GB of duplicated prebuilts inside synced
# trees is real, and is not this tool's business. Dot-directories are skipped too when scanning
# defaults -- throwaway scratch is for deleting, not linking. Name one explicitly to override.
#
# SAFETY
#
#   - groups by size, then compares sha256 -- never links on size alone
#   - refuses to cross filesystems (a hardlink cannot, and the error is confusing)
#   - re-reads the hash after linking and restores from a sibling copy if it somehow differs
#   - idempotent: already-linked files are reported and skipped
set -uo pipefail

DRY=0; MIN=$((50*1024*1024)); DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --min-size) MIN="${2:?--min-size needs bytes}"; shift 2;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) DIRS+=("$1"); shift;;
  esac
done

# Default: every sibling of the forge checkout that looks like a device repo, plus the parent itself
# so a keeper directory (Robin/, archive/) is included.
if [ ${#DIRS[@]} -eq 0 ]; then
  # forge/ is normally vendored inside a device repo, so ../.. is that repo and its parent holds the
  # siblings. Run from the canonical rom-forge checkout there is no device.conf there, and ../.. is
  # already the directory holding every repo -- going up again lands outside the workspace.
  _up2="$(cd "$(dirname "$0")/../.." && pwd)"
  if [ -f "$_up2/device.conf" ]; then PARENT="$(dirname "$_up2")"; else PARENT="$_up2"; fi
  # Skip dot-directories: .scratch and friends hold throwaway working data, and linking two copies
  # of something you are about to delete is churn, not a saving.
  while IFS= read -r d; do DIRS+=("$d"); done \
    < <(find "$PARENT" -maxdepth 1 -mindepth 1 -type d -not -name '.*' | sort)
fi
[ ${#DIRS[@]} -gt 0 ] || { echo "!! nothing to scan" >&2; exit 1; }

echo ">> scanning ${#DIRS[@]} director$([ ${#DIRS[@]} = 1 ] && echo y || echo ies) for files >= $((MIN/1024/1024)) MB"
[ "$DRY" = 1 ] && echo "   --dry-run: nothing will be linked"

python3 - "$DRY" "$MIN" "${DIRS[@]}" <<'PY'
import os, sys, hashlib, collections
dry = sys.argv[1] == "1"; minsz = int(sys.argv[2]); dirs = sys.argv[3:]
SKIP = ('/.repo/', '/build_output/', '/src/out/', '/.git/', '/out/')

def skip(p):
    q = p.replace(os.sep, '/') + '/'
    return any(s in q for s in SKIP)

bysize = collections.defaultdict(list)
for root in dirs:
    for dp, dns, fns in os.walk(root):
        if skip(dp):
            dns[:] = []; continue
        dns[:] = [d for d in dns if not skip(os.path.join(dp, d))]
        for f in fns:
            fp = os.path.join(dp, f)
            try: st = os.stat(fp)
            except OSError: continue
            if st.st_size >= minsz:
                bysize[st.st_size].append((fp, st.st_ino, st.st_dev))

def sha(p):
    d = hashlib.sha256()
    with open(p, 'rb') as fh:
        for b in iter(lambda: fh.read(1 << 22), b''): d.update(b)
    return d.hexdigest()

saved = already = 0
for size in sorted(bysize, reverse=True):
    ents = bysize[size]
    if len({i for _, i, _ in ents}) < 2:
        if len(ents) > 1: already += 1
        continue
    first = {}
    for fp, ino, dev in ents:
        first.setdefault(ino, (fp, dev))
    groups = collections.defaultdict(list)
    for ino, (fp, dev) in first.items():
        groups[sha(fp)].append((fp, ino, dev))
    for dig, members in groups.items():
        if len(members) < 2: continue
        keep, keep_ino, keep_dev = members[0]
        print("   %s  %d bytes x %d copies" % (dig[:12], size, len(members)))
        print("      keep %s" % keep)
        for fp, ino, dev in members[1:]:
            if dev != keep_dev:
                print("      SKIP %s (different filesystem)" % fp); continue
            if dry:
                print("      link %s" % fp); saved += size; continue
            bak = fp + ".dedup-bak"
            try:
                os.rename(fp, bak)
                os.link(keep, fp)
                if sha(fp) != dig:
                    os.unlink(fp); os.rename(bak, fp)
                    print("      REVERTED %s (hash mismatch after link)" % fp); continue
                os.unlink(bak)
                print("      linked %s" % fp); saved += size
            except OSError as e:
                if os.path.exists(bak) and not os.path.exists(fp): os.rename(bak, fp)
                print("      FAILED %s: %s" % (fp, e))
print(">> %s %.2f GB across the duplicates found; %d group(s) already linked"
      % ("would reclaim" if dry else "reclaimed", saved/1e9, already))
PY
