#!/usr/bin/env bash
# publish-kernel-source.sh — publish the kernel source that actually built this ROM, as a normal
# kernel repo, so a GPL request (or an XDA moderator) can be answered with one link.
#
#   ./forge/tools/publish-kernel-source.sh [--push] [--tag NAME] [--url GIT_URL] [AOSP_ROOT]
#
# WHY THIS EXISTS
#
# You ship a modified kernel. Linking upstream's repo is not enough: the binary in your boot image
# is upstream PLUS this device's patch series, and GPLv2 asks for the *corresponding* source. Your
# patches are public in overlay/patches/, so upstream-link + patch-series is technically complete,
# but it is an argument you have to make, and people asking for source generally want a tree they
# can clone and build.
#
# WHAT IT DOES NOT DO, deliberately: it does not become a second place to edit the kernel. The patch
# series stays the only source of truth. This regenerates the published branch from
# upstream-base + patches every time, so the published tree cannot drift from what you build.
# If you edit the published repo directly, the next run overwrites it.
#
# The published branch is real upstream history with your commits on top, so anyone can
# `git log <base>..` or diff against upstream and see exactly what you changed. That is the point;
# a squashed snapshot or a tarball answers the letter and not the spirit.
#
# Set KERNEL_PUBLISH_URL in device.conf.local (it is a remote you can push to, so it does not belong
# in a tracked file), or pass --url.
set -uo pipefail

PUSH=0; TAG=""; URL=""; ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH=1; shift;;
    --tag)  TAG="$2"; shift 2;;
    --url)  URL="$2"; shift 2;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) ARG="$1"; shift;;
  esac
done

DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "$DEVICE_REPO/device.conf" ] || { echo "!! no device.conf beside forge/" >&2; exit 1; }
source "$DEVICE_REPO/device.conf"
[ -f "$DEVICE_REPO/device.conf.local" ] && source "$DEVICE_REPO/device.conf.local"
: "${BRANCH:?device.conf missing BRANCH}"
AOSP="${ARG:-${BUILD_ROOT:-$DEVICE_REPO/build_output}/src}"
URL="${URL:-${KERNEL_PUBLISH_URL:-}}"
export LC_ALL=C

# The kernel path comes from the device tree, not a guess. Which FILE declares it varies: ether uses
# BoardConfig.mk, bonito uses BoardConfigLineage.mk, and some trees split it further. Search the
# device directory rather than assuming a filename -- assuming one made this tool work on exactly the
# device it was written against and fail on the next.
DDIR="$AOSP/device/${DEVICE:?device.conf missing DEVICE}"
[ -d "$DDIR" ] || { echo "!! no device tree at $DDIR — is the tree synced?" >&2; exit 1; }
KSRC_LINE=$(grep -rhE '^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:?=' "$DDIR" --include='*.mk' 2>/dev/null | head -1)
KPATH=$(printf '%s' "$KSRC_LINE" | sed 's/^[[:space:]]*TARGET_KERNEL_SOURCE[[:space:]]*:\?=[[:space:]]*//' | tr -d ' ')
if [ -z "$KPATH" ]; then
  echo ">> $DDIR declares no TARGET_KERNEL_SOURCE: prebuilt kernel, nothing to publish"
  exit 0
fi
KDIR="$AOSP/$KPATH"
[ -d "$KDIR/.git" ] || { echo "!! $KDIR is not a git checkout" >&2; exit 1; }

# Upstream base: the ref repo syncs to. Not HEAD -- HEAD already has the patches applied, and
# republishing that would bake in whatever state the working tree happened to be in.
MREF=$(git -C "$KDIR" for-each-ref --format='%(refname:short)' refs/remotes/m/ 2>/dev/null | head -1)
BASE="${MREF:-${BASE_REF:-}}"
[ -n "$BASE" ] || { echo "!! cannot determine the upstream base ref for $KPATH" >&2; exit 1; }
BASE_SHA=$(git -C "$KDIR" rev-parse "$BASE" 2>/dev/null) || { echo "!! no such ref: $BASE" >&2; exit 1; }
UPSTREAM=$(git -C "$KDIR" remote get-url "$(git -C "$KDIR" remote | head -1)" 2>/dev/null)

PDIR="$DEVICE_REPO/overlay/patches/$KPATH"
PATCHES=$(ls "$PDIR"/*.patch 2>/dev/null | sort)
NPATCH=$(printf '%s\n' $PATCHES | grep -c . || true)

echo ">> kernel   $KPATH"
echo "   upstream $UPSTREAM"
echo "   base     $BASE ($(echo "$BASE_SHA" | cut -c1-12))"
echo "   patches  $NPATCH from overlay/patches/$KPATH"

PUBBR="${BRANCH}"
WORK=$(git -C "$KDIR" rev-parse --git-dir >/dev/null 2>&1 && echo ok)
[ "$WORK" = ok ] || exit 1

# Build the publish branch in a detached worktree so the synced tree that the build uses is never
# touched. Editing it here would silently change what the next build compiles.
TMPWT="${BUILD_ROOT:-$DEVICE_REPO/build_output}/tmp/kpublish.$$"
mkdir -p "$(dirname "$TMPWT")"
cleanup() { git -C "$KDIR" worktree remove --force "$TMPWT" >/dev/null 2>&1; }
trap cleanup EXIT
git -C "$KDIR" worktree add --detach "$TMPWT" "$BASE_SHA" >/dev/null 2>&1 \
  || { echo "!! could not create a worktree at the base commit" >&2; exit 1; }

# `git am` needs a committer identity, and a fresh worktree inherits none if the machine has no
# global git config. Take the device repo's if it has one, otherwise a neutral placeholder: the
# AUTHOR of each commit comes from the patch either way, so this only affects the committer field.
GIT_ID_NAME=$(git -C "$DEVICE_REPO" config user.name 2>/dev/null || true)
GIT_ID_MAIL=$(git -C "$DEVICE_REPO" config user.email 2>/dev/null || true)
AM=(git -c "user.name=${GIT_ID_NAME:-rom-forge}" -c "user.email=${GIT_ID_MAIL:-rom-forge@localhost}")

rc=0
if [ "$NPATCH" -gt 0 ]; then
  echo ">> replaying the patch series"
  for p in $PATCHES; do
    if "${AM[@]}" -C "$TMPWT" am --keep-cr "$p" >/dev/null 2>&1; then
      echo "   applied $(basename "$p")"
    else
      "${AM[@]}" -C "$TMPWT" am --abort >/dev/null 2>&1
      echo "   !! FAILED $(basename "$p")" >&2
      echo "      The published tree must match what you build. Fix the series first." >&2
      rc=1; break
    fi
  done
fi
[ "$rc" -eq 0 ] || exit 1

HEAD_SHA=$(git -C "$TMPWT" rev-parse HEAD)
echo ">> built $PUBBR: $(echo "$BASE_SHA" | cut -c1-12) + $NPATCH patch(es) = $(echo "$HEAD_SHA" | cut -c1-12)"

if [ -z "$URL" ]; then
  echo ">> no publish URL (set KERNEL_PUBLISH_URL in device.conf.local, or pass --url)"
  echo "   nothing pushed; the branch exists only in this worktree and is about to be removed."
  exit 0
fi

if [ "$PUSH" -eq 0 ]; then
  echo ">> would push to $URL"
  echo "     $PUBBR  -> $(echo "$HEAD_SHA" | cut -c1-12)"
  [ -n "$TAG" ] && echo "     tag $TAG"
  echo "   re-run with --push to do it"
  exit 0
fi

echo ">> pushing $PUBBR to $URL"
git -C "$TMPWT" push --force "$URL" "HEAD:refs/heads/$PUBBR" 2>&1 | sed 's/^/   /'
# --force is correct here and only here: the branch is regenerated from base+patches every run, so
# it is an output, not a history anyone should be committing onto.
if [ -n "$TAG" ]; then
  git -C "$TMPWT" tag -f "$TAG" "$HEAD_SHA" >/dev/null 2>&1
  git -C "$TMPWT" push --force "$URL" "refs/tags/$TAG" 2>&1 | sed 's/^/   /'
fi
echo ">> done. Link that branch for GPL requests; it is upstream history plus this device's patches."
