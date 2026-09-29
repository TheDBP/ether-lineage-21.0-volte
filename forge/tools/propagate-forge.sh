#!/usr/bin/env bash
# propagate-forge.sh — push an engine change out to every device repo, now.
#
#   ./tools/propagate-forge.sh                 # sync every device repo beside this one
#   ./tools/propagate-forge.sh --dry-run       # show what would change
#   ./tools/propagate-forge.sh ~/a ~/b         # only these
#   ./tools/propagate-forge.sh --no-push       # commit locally, do not push
#
# Why: forge/ is VENDORED into each device repo rather than submoduled, so a fix here does not
# reach them until someone runs sync-forge.sh there. That gap is how a device ends up debugging a
# problem that was fixed upstream weeks ago. Run this straight after committing to rom-forge and
# every device repo moves together.
#
# Finds device repos by looking for a sibling directory containing both device.conf and
# forge/FORGE_REF. Skips anything with uncommitted changes -- it will not paper over your work.
set -o pipefail
cd "$(dirname "$0")/.."
FORGE="$PWD"

DRY=0; PUSH=1; TARGETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --no-push) PUSH=0; shift;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) TARGETS+=("$1"); shift;;
  esac
done

HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
HEAD_SUB=$(git log -1 --pretty=%s 2>/dev/null)
echo "engine at $(echo "$HEAD_SHA" | cut -c1-12) — $HEAD_SUB"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "!! rom-forge has uncommitted changes — commit them first, or device repos get a half state" >&2
  exit 1
fi
if [ "$PUSH" = 1 ] && [ -n "$(git log '@{u}..HEAD' --oneline 2>/dev/null)" ]; then
  echo "!! rom-forge has unpushed commits — push them first, or sync-forge.sh will fetch the old engine" >&2
  exit 1
fi

# The tool index is generated, so it can silently fall behind the tools it describes. Check it here
# rather than trusting anyone to remember: this is the gate every engine change passes through on
# its way to the device repos, so an index that lies cannot get past it.
if ! "$(dirname "$0")/gen-tool-index.py" --check >/dev/null 2>&1; then
  echo "!! the tool index is out of date" >&2
  "$(dirname "$0")/gen-tool-index.py" --check 2>&1 | sed 's/^/   /' >&2
  exit 1
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  for d in "$FORGE/../"*/; do
    [ -f "$d/device.conf" ] && [ -f "$d/forge/FORGE_REF" ] && TARGETS+=("$d")
  done
fi
[ ${#TARGETS[@]} -eq 0 ] && { echo "no device repos found beside $FORGE"; exit 0; }

echo
ok=0; skip=0; fail=0
for d in "${TARGETS[@]}"; do
  name=$(basename "$(cd "$d" && pwd)")
  cur=$(grep -m1 '^commit=' "$d/forge/FORGE_REF" 2>/dev/null | cut -d= -f2)
  if [ "$cur" = "$HEAD_SHA" ]; then
    printf "  %-24s already current\n" "$name"; skip=$((skip+1)); continue
  fi
  # `-d .git` is wrong: in a git WORKTREE .git is a file pointing at the real gitdir, and under
  # `repo` it is a symlink. Ask git instead of guessing at the filesystem layout.
  if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    printf "  %-24s SKIP — not a git repo\n" "$name"; skip=$((skip+1)); continue
  fi
  # Untracked files count. This used to filter out '?? ' entries, which meant a NEW file outside
  # forge/ -- a device patch that had just been written, say -- sailed past the guard and was then
  # swept into the "forge sync" commit by the `git add -A` below. The work was not lost, but it was
  # recorded under a message that says the opposite of what happened, which is its own kind of lost.
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | grep -v '^?? forge/' | grep -v '^.. forge/' || true)
  if [ -n "$dirty" ]; then
    printf "  %-24s SKIP — uncommitted or untracked changes outside forge/\n" "$name"; skip=$((skip+1)); continue
  fi
  if [ "$DRY" = 1 ]; then
    printf "  %-24s would sync %s -> %s\n" "$name" "$(echo "$cur" | cut -c1-12)" "$(echo "$HEAD_SHA" | cut -c1-12)"
    ok=$((ok+1)); continue
  fi
  # Catch the branch up to its remote before committing on top of it. Without this, a repo whose
  # local branch is behind origin -- which happens whenever a branch was pushed from a worktree or
  # another clone -- gets the sync commit built on a stale base, and the push is then rejected as a
  # non-fast-forward after the work is already committed. Fast-forward only: if the branch has local
  # commits of its own that the remote lacks, leave it alone and let the push decide.
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$br" ] && [ "$br" != HEAD ] && git -C "$d" fetch -q origin "$br" 2>/dev/null; then
    if git -C "$d" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null &&
       ! git -C "$d" merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
      if git -C "$d" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
        printf "  %-24s fast-forwarded to origin/%s first\n" "$name" "$br"
      else
        printf "  %-24s FAILED — behind origin/%s and cannot fast-forward\n" "$name" "$br"
        fail=$((fail+1)); continue
      fi
    fi
  fi
  if ! ( cd "$d" && ./forge/tools/sync-forge.sh >/dev/null 2>&1 ); then
    printf "  %-24s FAILED — sync-forge.sh errored\n" "$name"; fail=$((fail+1)); continue
  fi
  if [ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    printf "  %-24s no change after sync\n" "$name"; skip=$((skip+1)); continue
  fi
  git -C "$d" add -A
  # -c user.*: a freshly-cloned repo has no local identity and git refuses to commit. Without
  # this the commit fails, and (before the exit check below) the script still claimed success.
  if ! git -C "$d" \
        -c user.name="${GIT_AUTHOR_NAME:-rom-forge}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-rom-forge@users.noreply.github.com}" \
        commit -q -m "forge sync: $(echo "$HEAD_SHA" | cut -c1-12)

$HEAD_SUB

Propagated from rom-forge by propagate-forge.sh so every device repo moves together
rather than each device drifting until someone notices." 2>/dev/null; then
    printf "  %-24s FAILED — commit rejected\n" "$name"; fail=$((fail+1)); continue
  fi
  br=$(git -C "$d" rev-parse --abbrev-ref HEAD)
  landed=$(grep -m1 '^commit=' "$d/forge/FORGE_REF" 2>/dev/null | cut -d= -f2)
  if [ "$landed" != "$HEAD_SHA" ]; then
    printf "  %-24s FAILED — FORGE_REF is %s, expected %s\n" "$name" \
      "$(echo "$landed" | cut -c1-12)" "$(echo "$HEAD_SHA" | cut -c1-12)"
    fail=$((fail+1)); continue
  fi
  if [ "$PUSH" = 1 ]; then
    if git -C "$d" push -q origin "$br" 2>/dev/null; then
      printf "  %-24s synced + pushed (%s)\n" "$name" "$br"
    else
      printf "  %-24s synced, PUSH FAILED (%s)\n" "$name" "$br"; fail=$((fail+1)); continue
    fi
  else
    printf "  %-24s synced, not pushed (%s)\n" "$name" "$br"
  fi
  ok=$((ok+1))
done

echo
echo "  $ok updated, $skip skipped, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
