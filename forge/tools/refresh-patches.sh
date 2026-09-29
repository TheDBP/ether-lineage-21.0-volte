#!/bin/bash
# refresh-patches.sh — re-export overlay/patches/ from the local commits sitting on top of upstream
# in each patched project.
#
#   ./forge/tools/refresh-patches.sh [--dry-run] [--force] [--adopt] [AOSP_ROOT]
#
# --adopt also exports projects that have local commits but no patches yet. Without it they are
# only reported, and the script exits non-zero so a preflight notices.
#
# WHICH DIRECTION THIS GOES, because it only goes one way:
#
#   the synced tree  ---- refresh-patches.sh ---->  overlay/patches/
#   overlay/patches/ ---- apply-overlay.sh ------>  the synced tree
#
# You develop in the tree: that is where you can compile and boot what you changed. The device repo
# cannot store the tree -- it is tens of gigabytes of someone else's code -- so it stores only your
# delta, as patches, and re-creates the tree from upstream + those patches. `git format-patch` and
# `git am` are the two halves of that.
#
# The consequence people get bitten by: EDITING A FILE UNDER overlay/patches/ IS NOT DEVELOPMENT.
# The tree is the source of truth for this script; the next refresh overwrites whatever you typed
# there. To change what a patch contains, change the commit in the tree and refresh.
#
# WHY THIS SCRIPT USED TO BE DANGEROUS, and what now stops it:
#
# It deleted the existing patches and then ran format-patch. If the tree had no commits on top of
# BASE_REF -- which is exactly what `repo sync --force-sync` leaves behind -- format-patch wrote
# nothing, and the script deleted every patch in the repo, printed "refreshed: 0 patch(es)", and
# exited 0. An entire device port, gone, reported as success.
#
# Now: export to a temp directory first and only swap it in if the result is sane. Going from "some
# patches" to "no patches" is refused outright, and anything else that reduces the count has to be
# confirmed with --force.
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

DRY=0; FORCE=0; ADOPT=0; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --force)   FORCE=1; shift;;
    --adopt)   ADOPT=1; shift;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) ARG="$1"; shift;;
  esac
done

DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"   # tools -> forge -> device repo root
[ -f "$DEVICE_REPO/device.conf" ] && source "$DEVICE_REPO/device.conf"
: "${BASE_REF:?device.conf missing or BASE_REF unset}"
OVL="$DEVICE_REPO/overlay"
FORGE="$DEVICE_REPO/forge"
: "${BRANCH:?device.conf missing or BRANCH unset}"
AOSP="${ARG:-${BUILD_ROOT:-$DEVICE_REPO/build_output}/src}"

RC=0

# Counting with `ls glob | wc -l` looks harmless and is not: with `set -o pipefail` a glob that
# matches nothing makes ls exit 2, the pipeline inherits it, and `set -e` kills the script. Since
# ls's stderr is discarded, that happens in total silence -- which is exactly how this script
# managed to do nothing at all and still look like it had run. Pure bash, cannot fail.
count_patches() {
  local f n=0
  for f in "$1"/*.patch; do [ -e "$f" ] && n=$((n+1)); done
  printf '%s' "$n"
}
refresh() {
  local proj="$1"
  local d="$AOSP/$proj" dst="$OVL/patches/$proj"
  # Not synced: leave whatever patches are on disk alone. A project you have not checked out tells
  # you nothing about what its patches should be.
  # Not `-d .git`: under `repo` a project's .git is a symlink, and in a worktree it is a file.
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { echo "skip $proj (not synced)"; return 0; }

  local old; old=$(count_patches "$dst")

  # A vendored project (VENDORED_PROJECTS) was never synced: apply-overlay.sh copies it out of the
  # device repo and git-inits it with one commit. That root commit is its upstream; BASE_REF does
  # not exist there and never will.
  local base="$BASE_REF" _vp
  for _vp in ${VENDORED_PROJECTS:-}; do
    [ "${_vp#*:}" = "$proj" ] || continue
    base="$(git -C "$d" rev-list --max-parents=0 HEAD)"
    [ "$(printf '%s\n' "$base" | wc -l)" -eq 1 ] || {
      echo "!! $proj: vendored, but its history has more than one root -- skipping ($old patch(es) left alone)" >&2
      RC=1; return 0; }
    break
  done

  # The base has to exist here and has to be behind HEAD, or "base..HEAD" is meaningless and will
  # quietly produce the wrong set rather than an error.
  if ! git -C "$d" rev-parse --verify -q "$base^{commit}" >/dev/null; then
    echo "!! $proj: BASE_REF '$base' does not resolve in this project -- skipping ($old patch(es) left alone)" >&2
    RC=1; return 0
  fi
  if ! git -C "$d" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    echo "!! $proj: '$base' is not an ancestor of HEAD -- the tree is not upstream+your commits." >&2
    echo "   skipping ($old patch(es) left alone). Re-apply the overlay before refreshing." >&2
    RC=1; return 0
  fi

  # Uncommitted edits are invisible to format-patch. Saying so is the difference between "my change
  # did not get exported" and an hour of confusion.
  if [ -n "$(git -C "$d" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "   note: $proj has uncommitted changes -- they will NOT be exported (commit them first)"
  fi

  # Commits that came from an option's patch series are not this device's to export: bootstrap
  # applies those to the same project before the device patches, so a plain base..HEAD would copy
  # e.g. teal-skin's frameworks/base commit into overlay/patches/ as if the device owned it, and the
  # next bootstrap would apply it twice. Matched by patch-id, which ignores hashes and line numbers.
  local optids="" f
  for f in "$FORGE"/options/*/patches/"$BRANCH"/"$proj"/*.patch; do
    [ -e "$f" ] || continue
    optids+="$(git patch-id --stable < "$f" | cut -d' ' -f1)"$'\n'
  done
  local shas="" sha id
  for sha in $(git -C "$d" rev-list --reverse "$base"..HEAD); do
    id="$(git -C "$d" show --format= "$sha" | git patch-id --stable | cut -d' ' -f1)"
    if [ -n "$id" ] && printf '%s' "$optids" | grep -qx "$id"; then
      echo "   (not exporting \"$(git -C "$d" log -1 --format=%s "$sha" | cut -c1-60)\" -- an option's patch)"
      continue
    fi
    shas+="$sha "
  done

  # --zero-commit: bootstrap re-applies the series with git am on every run, so the commit hashes
  # in "From <sha>" change every build and every patch file would show as modified for nothing.
  # --no-signature for the same reason as --zero-commit: the trailing "-- \n<git version>" changes
  # whenever the build host's git is upgraded, and every patch in the repo then shows as modified.
  local tmp; tmp="$(mktemp -d)"
  local n=1
  for sha in $shas; do
    ( cd "$d" && git format-patch -N --zero-commit --no-signature -1 --start-number "$n" "$sha" -o "$tmp" ) >/dev/null
    n=$((n+1))
  done
  # Change-Id belongs to Gerrit, not to a patch series carried in this repo. Committing one means
  # the next upstream cherry-pick of the same change collides with it.
  sed -i '/^Change-Id: /d' "$tmp"/*.patch 2>/dev/null || true
  local new; new=$(count_patches "$tmp")

  # The failure this script was built to have. Refuse it even with --force: there is no situation
  # where deleting every patch is what you meant, and if it is, `git rm` says so out loud.
  if [ "$new" -eq 0 ] && [ "$old" -gt 0 ]; then
    echo "!! $proj: the tree has NO commits on top of $base, but the repo has $old patch(es)." >&2
    echo "   Refusing to delete them. This is what a tree reset by 'repo sync --force-sync' looks" >&2
    echo "   like -- re-apply the overlay first. Nothing was changed." >&2
    rm -rf "$tmp"; RC=1; return 0
  fi
  if [ "$new" -lt "$old" ] && [ "$FORCE" != 1 ]; then
    echo "!! $proj: $old patch(es) on disk, tree would produce $new. Refusing to drop patches." >&2
    echo "   If you really squashed or removed commits, re-run with --force. Nothing was changed." >&2
    rm -rf "$tmp"; RC=1; return 0
  fi

  if [ "$DRY" = 1 ]; then
    echo "would refresh $proj: $old -> $new patch(es)"
    for f in "$tmp"/*.patch; do [ -e "$f" ] || continue; f="$(basename "$f")"
      if [ ! -f "$dst/$f" ]; then echo "   + $f"
      elif ! cmp -s "$tmp/$f" "$dst/$f"; then echo "   ~ $f"; fi
    done
    for f in "$dst"/*.patch; do [ -e "$f" ] || continue; f="$(basename "$f")"
      [ -f "$tmp/$f" ] || echo "   - $f"
    done
    rm -rf "$tmp"; return 0
  fi

  mkdir -p "$dst"
  rm -f "$dst"/*.patch
  mv "$tmp"/*.patch "$dst"/ 2>/dev/null || true
  rm -rf "$tmp"
  echo "refreshed $proj: $old -> $new patch(es)"
}

# PATCHED_PROJECTS plus whatever already has patches on disk -- the same union bootstrap.sh resets,
# so a project that was patched without being added to device.conf still gets refreshed instead of
# silently keeping a stale export.
PROJECTS="${PATCHED_PROJECTS:-}"
[ -d "$OVL/patches" ] && PROJECTS="$PROJECTS $(cd "$OVL/patches" && find . -name '*.patch' -printf '%h\n' | sed 's#^\./##' | sort -u)"
for proj in $(printf '%s\n' $PROJECTS | sort -u); do
  refresh "$proj"
done
# Normalised to single-space separation for the membership test below. $PROJECTS is newline
# separated (find output), and `case " $PROJECTS " in *" $p "*)` never matches across a newline,
# which silently reports every already-patched project as unbacked.
PROJECTS_FLAT=" $(printf '%s\n' $PROJECTS | sort -u | tr '\n' ' ') "

# Patches live in TWO places, and a scan that knows about only one raises false alarms that look
# exactly like lost work. overlay/patches/ holds device patches; forge/options/<opt>/patches/<branch>/
# holds option patches, applied conditionally from COMMON_OPTIONS/PRESET. A project patched solely by
# an enabled option has commits in the tree and nothing under overlay/patches -- which is correct,
# not drift. Exporting it to overlay/patches duplicates the option and the two then fight on the
# next bootstrap.
OPT_PROJECTS=""
if [ -d "$FORGE/options" ] && [ -n "${BRANCH:-}" ]; then
  OPT_PROJECTS="$(cd "$FORGE/options" 2>/dev/null && \
    find . -path "*/patches/$BRANCH/*" -name '*.patch' -printf '%h\n' 2>/dev/null \
    | sed "s#^\./[^/]*/patches/$BRANCH/##" | sort -u)"
fi
OPT_FLAT=" $(printf '%s\n' $OPT_PROJECTS | sort -u | tr '\n' ' ') "

# Anything with local commits but NO patches yet is invisible to the union above, because that union
# is seeded from patches that already exist. That is not hypothetical: on ether, Trebuchet,
# lineage-sdk and SetupWizard carried ten commits for three weeks with no patch directory, and a
# fresh bootstrap would have silently dropped every one of them. So sweep for unbacked work and say
# so loudly; --adopt exports it.
#
# Compare against refs/remotes/m/<branch>, not @{u}: repo projects have no upstream set, so
# `git log @{u}..HEAD` reports nothing at all and the scan passes while finding nothing.
echo ">> scanning for projects with local commits but no patches"
UNBACKED=""
while read -r gitdir; do
  proj="${gitdir%/.git}"; proj="${proj#./}"
  case "$PROJECTS_FLAT" in *" $proj "*) continue ;; esac
  case "$OPT_FLAT"      in *" $proj "*) continue ;; esac
  mref=$(git -C "$AOSP/$proj" for-each-ref --format='%(refname:short)' refs/remotes/m/ 2>/dev/null | head -1)
  [ -n "$mref" ] || continue
  n=$(git -C "$AOSP/$proj" log --oneline "$mref..HEAD" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || continue
  UNBACKED="$UNBACKED $proj"
  echo "   !! $proj has $n local commit(s) and no patches"
  git -C "$AOSP/$proj" log --oneline "$mref..HEAD" 2>/dev/null | sed 's/^/        /'
done <<EOF
$(cd "$AOSP" 2>/dev/null && find . -maxdepth 5 -name .git 2>/dev/null)
EOF
if [ -n "$UNBACKED" ]; then
  if [ "${ADOPT:-0}" = "1" ]; then
    for proj in $UNBACKED; do refresh "$proj"; done
  else
    echo "   run with --adopt to export these, or they will be lost on the next clean bootstrap" >&2
    RC=1
  fi
else
  echo "   none"
fi
[ "$RC" -eq 0 ] || echo "!! one or more projects were skipped -- see above. Nothing was lost." >&2
exit $RC
