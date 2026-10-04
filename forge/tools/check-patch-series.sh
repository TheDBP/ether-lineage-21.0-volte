#!/usr/bin/env bash
# check-patch-series.sh — find patches that undo earlier patches in the same series.
#
#   check-patch-series.sh [DEVICE_REPO] [--quiet]
#
# A patch series is not a history. It is a description of how the tree differs from upstream, and it
# is replayed from scratch every time the tree is synced. So a patch that adds a line and a later
# patch that removes it are not "two steps of the work" -- they are one change, written twice, where
# a reader has to hold both in their head to know what the tree actually contains.
#
# It happens naturally and it is invisible without a check like this:
#
#   - a value is tuned, then retuned (a dimension set to one number, then another)
#   - something is added, found not to work, and removed (dead config nobody notices is dead)
#   - a feature is staged across commits -- stubs first, implementation later -- which reads fine as
#     history and badly as a series
#   - a flag is set true, then set false by a later patch, so the series says both
#
# Detection: for every line an earlier patch ADDS, see whether a later patch REMOVES it. Short and
# whitespace-only lines are skipped, since braces and blank lines move around constantly and mean
# nothing. The result is advisory -- collapsing a series is a rebase, not something to do
# automatically -- but it should be seen every time the patches are regenerated.
#
# COLLAPSING A PAIR, AND THE ONLY VERIFICATION WORTH TRUSTING
#
# Record the project's tree object, reset to the vendored base, replay the series with the fold
# applied, and compare. It must be IDENTICAL -- a fold that looks obvious can still change
# behaviour, and this is the only check that catches it:
#
#   git -C <project> rev-parse HEAD^{tree}      # before
#   git -C <project> reset --hard <base>
#   git am <series, with the fold applied>
#   git -C <project> rev-parse HEAD^{tree}      # must match
#
# Then refresh-patches.sh --force -- it refuses to drop patches without it -- and re-run this check.
#
# Traps. Each produces a silently wrong patch rather than an error:
#
#   - Patches exported --no-signature have no "-- " trailer, so the file's final newline lives inside
#     the last diff section. Strip that section and the patch ends without a newline, which git apply
#     reports as "corrupt patch at line N".
#   - Strip whole per-file sections, never individual hunks, or the @@ counts need recomputing.
#   - Retargeting a hunk's context is safe only while the context LINE COUNT stays the same.
#   - Editing a line a patch ADDS turns it into context for every later patch that quotes it, which
#     then fails to apply. Grep the whole series for the line before changing it.
#   - A change that deliberately alters the tree cannot use the hash check. Verify the invariant
#     instead (the set of list entries, the expanded variable) and build before trusting it.
#   - Reordering is not free either. Two patches that both APPEND to one file -- a module block, a
#     list entry, an rc service -- encode their order in that file's content, so swapping them
#     changes the file and therefore the tree. Applying cleanly is not the test; the hash is. Such a
#     pair cannot be reordered without accepting a content change, so leave them in order.
set -uo pipefail

ARG=""; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARG="$1"; shift ;;
  esac
done
DEVICE_REPO="${ARG:-$(cd "$(dirname "$0")/../.." && pwd)}"
PDIR="$DEVICE_REPO/overlay/patches"
[ -d "$PDIR" ] || { echo "!! no overlay/patches under $DEVICE_REPO" >&2; exit 1; }
export LC_ALL=C

python3 - "$PDIR" "$QUIET" <<'PY'
import os, sys, glob, re

# A makefile/shell list opener -- "PRODUCT_COPY_FILES += \\" -- carries no content of its own; the
# entries on the following lines do. Two patches that add and remove unrelated blocks of the same
# list both touch an opener, and that is not an undo.
OPENER = re.compile(r'^[A-Za-z_][A-Za-z0-9_.$(){}-]*\s*[:+?]?=\s*\\$')

pdir, quiet = sys.argv[1], sys.argv[2] == "1"
total_pairs = 0
report = []

for root, dirs, files in os.walk(pdir):
    pats = sorted(f for f in files if f.endswith('.patch'))
    if len(pats) < 2:
        continue
    project = os.path.relpath(root, pdir)
    # Keyed by (file, body), not body alone: two patches touching DIFFERENT files that happen to share
    # a line are not a pair. Bodies are stripped, so indentation does not distinguish them, and short
    # JSON/XML lines recur across sibling config files constantly.
    added = {}      # (file, body) -> first patch that added it
    undo = {}       # (later, earlier) -> [(file, body)]
    for p in pats:
        num = p[:4]
        cur = None
        with open(os.path.join(root, p), encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                if raw.startswith('+++ '):
                    cur = raw[4:].strip()
                    if cur.startswith('b/'):
                        cur = cur[2:]
                    continue
                if raw.startswith(('---', '@@', 'diff --git')):
                    continue
                body = raw[1:].strip()
                # short lines are punctuation and noise: braces, blank lines, "endif"
                if len(body) < 12 or OPENER.match(body):
                    continue
                key = (cur, body)
                if raw.startswith('+'):
                    added.setdefault(key, num)
                elif raw.startswith('-'):
                    first = added.get(key)
                    if first is not None and first != num:
                        undo.setdefault((num, first), []).append(key)
    if undo:
        report.append((project, undo))
        total_pairs += len(undo)

if not report:
    if not quiet:
        print(">> patch series: no patch undoes an earlier one")
    sys.exit(0)

print(">> patch series: %d patch pair(s) where a later patch undoes an earlier one" % total_pairs)
for project, undo in report:
    print("   %s" % project)
    for (later, earlier), bodies in sorted(undo.items()):
        files = sorted({f for f, _b in bodies if f})
        where = files[0] if len(files) == 1 else '%d files' % len(files)
        print("     %s undoes %s  (%d line(s) in %s)" % (later, earlier, len(bodies), where))
        for f, b in bodies[:2]:
            print("         %s" % (b[:96] + ('…' if len(b) > 96 else '')))
print()
print("   A series is replayed from scratch, so this is one change written twice. Collapse the pair")
print("   into a single patch describing the end state: reset the project to before the earlier")
print("   commit, replay with the correction folded in, and confirm the resulting tree is identical")
print("   to the one you started with before regenerating the patches.")
sys.exit(0)
PY
