#!/bin/bash
# amend-patch.sh — fold an edit you made in the synced tree into the patch that already owns the
# file, however deep in the series that patch sits, then re-export.
#
#   ./forge/tools/amend-patch.sh <project> <file> [<file>...] [--no-refresh] [AOSP_ROOT]
#
#   ./forge/tools/amend-patch.sh device/lge/msm8996-common ims/bridge/src/.../Adapter.java
#
# WHY THIS EXISTS
#
# The tree is the source of truth and `overlay/patches/` is generated output (GOTCHAS 18). Changing
# what a patch contains means changing the commit in the tree. That is easy for the newest commit
# and awkward for an older one, and the awkward case is the common one: the patch that owns a file is
# usually the patch that introduced it, which can be a dozen commits back.
#
# Hand-editing the patch file instead looks like it works. It does not: the tree still holds the old
# version until the next apply-overlay, the two drift (GOTCHAS 32), and the next refresh-patches.sh
# exports the tree and silently reverses the edit.
#
# `git rebase -i` is the usual answer and needs an editor, which a scripted or sandboxed environment
# often does not have. `--fixup` plus `--autosquash` under `GIT_SEQUENCE_EDITOR=true` does the same
# thing with no editor and no commit left over.
#
# WHAT IT REFUSES TO DO
#
# It will not run if the named files are unchanged (nothing to fold, and a silent success there is
# how a lost edit goes unnoticed), if the base does not resolve or is not an ancestor of HEAD, or if
# the rebase stops on a conflict. On a conflict it leaves the rebase in place to be finished by hand
# rather than aborting work you cannot easily redo.
set -uo pipefail

DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
: "${BASE_REF:?device.conf missing or BASE_REF unset}"

REFRESH=1; PROJ=""; AOSP=""; FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-refresh) REFRESH=0 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "!! unknown argument: $1" >&2; exit 2 ;;
    *)
      if [ -z "$PROJ" ]; then PROJ="$1"
      elif [ -d "$1" ] && [ -d "$1/.repo" ]; then AOSP="$1"
      else FILES+=("$1"); fi ;;
  esac
  shift
done
[ -n "$PROJ" ] && [ "${#FILES[@]}" -gt 0 ] || {
  echo "usage: amend-patch.sh <project> <file> [<file>...] [--no-refresh] [AOSP_ROOT]" >&2; exit 2; }

AOSP="${AOSP:-${BUILD_ROOT:-$DEVICE_REPO/build_output}/src}"
D="$AOSP/$PROJ"
git -C "$D" rev-parse --git-dir >/dev/null 2>&1 || { echo "!! $PROJ is not a synced git project" >&2; exit 2; }

# A vendored project was git-inited by apply-overlay.sh, so its root commit is its upstream.
BASE="$BASE_REF"
for _vp in ${VENDORED_PROJECTS:-}; do
  [ "${_vp#*:}" = "$PROJ" ] || continue
  BASE="$(git -C "$D" rev-list --max-parents=0 HEAD)"
  break
done
git -C "$D" rev-parse --verify -q "$BASE^{commit}" >/dev/null || {
  echo "!! base '$BASE' does not resolve in $PROJ" >&2; exit 1; }
git -C "$D" merge-base --is-ancestor "$BASE" HEAD 2>/dev/null || {
  echo "!! '$BASE' is not an ancestor of HEAD; re-apply the overlay first" >&2; exit 1; }

# Nothing staged or modified means nothing to fold. Exiting 0 here would read as success.
DIRTY=$(git -C "$D" status --porcelain -- "${FILES[@]}" | wc -l)
[ "$DIRTY" -gt 0 ] || { echo "!! none of the named files differ from the commit; nothing to fold" >&2; exit 1; }

# --autosquash acts on EVERY commit whose subject starts with fixup! or squash!, not just the one
# written here. Upstream history is full of them (one LineageOS device tree carries four), and if any
# sits inside the rebased range the autosquash silently folds and reorders it, which shows up later
# as a patch that lost a change nobody removed. Below BASE they are harmless, so only the local range
# is checked.
STRAY=$(git -C "$D" log --format=%s "$BASE..HEAD" | grep -cE '^(fixup|squash)!' || true)
[ "$STRAY" = 0 ] || {
  echo "!! $STRAY commit(s) in $BASE..HEAD already have a fixup!/squash! subject." >&2
  echo "   --autosquash would fold those too. Resolve them first, or amend by hand." >&2
  exit 1; }

# The commit that owns the file is the last one in the series that touched it.
OWNER=$(git -C "$D" log --format=%H -1 "$BASE..HEAD" -- "${FILES[@]}")
[ -n "$OWNER" ] || { echo "!! no commit in $BASE..HEAD touches those files; this would be a new patch, not an amend" >&2; exit 1; }
SUBJ=$(git -C "$D" log --format=%s -1 "$OWNER")
DEPTH=$(git -C "$D" rev-list --count "$OWNER..HEAD")
echo ">> folding into: ${OWNER:0:9} $SUBJ"
echo "   $DEPTH commit(s) back in the series, base $BASE"

# A synced project has no identity configured, and both the fixup and the rebase need one. Match
# what apply-overlay.sh uses for vendored projects; nothing here is ever pushed, and refresh-patches
# re-exports the patch with whatever authorship the original commit already had.
GI=(-c user.name=rom-forge -c user.email=rom-forge@localhost)

BEFORE=$(git -C "$D" rev-list --count "$BASE..HEAD")
git -C "$D" add -- "${FILES[@]}"
git "${GI[@]}" -C "$D" commit -q --fixup="$OWNER" || { echo "!! fixup commit failed" >&2; exit 1; }

if ! GIT_SEQUENCE_EDITOR=true git "${GI[@]}" -C "$D" rebase -q --autosquash "$BASE"; then
  echo "!! the rebase stopped, most likely a conflict. The fixup commit is in place." >&2
  echo "   finish it with: git -C $D rebase --continue   (or --abort to back out)" >&2
  exit 1
fi

AFTER=$(git -C "$D" rev-list --count "$BASE..HEAD")
[ "$AFTER" -eq "$BEFORE" ] || {
  echo "!! series went from $BEFORE to $AFTER commits; the fixup did not fold. Inspect $PROJ by hand." >&2
  exit 1; }
echo ">> folded, series still $AFTER commit(s)"

if [ "$REFRESH" = 1 ]; then
  echo ">> re-exporting overlay/patches/"
  "$(dirname "$0")/refresh-patches.sh" "$AOSP"
else
  echo ">> skipped the refresh; overlay/patches/ still holds the old version"
fi
