#!/usr/bin/env bash
# sync-forge.sh — vendor forge/ into a device repo from rom-forge at a pinned ref.
#
#   ./forge/tools/sync-forge.sh              # sync to origin/main, pin to that commit
#   ./forge/tools/sync-forge.sh <ref>        # sync to a tag/branch/SHA
#   FORGE_URL=... ./forge/tools/sync-forge.sh   # another rom-forge (a fork); remembered in FORGE_REF
#
# Replaces `git subtree`. Subtree linkage lives in COMMIT MESSAGES (git-subtree-dir /
# git-subtree-split trailers), so squashing a repo's history destroys it and every squash would
# need a re-link. This keeps forge/ as ordinary vendored files — squash-proof — and records the
# upstream commit in forge/FORGE_REF so "which forge is this?" is one grep, not archaeology.
#
# Local edits to forge/ are NOT preserved: the sync is an exact mirror (rsync --delete), EXCEPT
# fetched prebuilt/*.apk artifacts, which are gitignored and would otherwise be wiped. Forge
# changes belong upstream in rom-forge first, then come back down through here.
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "${FORGE_SYNC_ORIG:-$0}")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

# The sync overwrites forge/ INCLUDING this script. bash reads scripts incrementally, so a running
# script that gets rewritten under itself can execute garbage — re-exec from a private copy first.
if [ "${_FORGE_SYNC_REEXEC:-}" != 1 ]; then
  _self_copy="$(mktemp)"; cp "$0" "$_self_copy"; chmod +x "$_self_copy"
  _FORGE_SYNC_REEXEC=1 FORGE_SYNC_ORIG="$0" exec "$_self_copy" "$@"
fi
trap 'rm -f "$0"' EXIT   # we are the temp copy; clean up on the way out

ORIG="${FORGE_SYNC_ORIG:?}"
DEVICE_REPO="$(cd "$(dirname "$ORIG")/../.." && pwd)"   # tools -> forge -> device repo root
FORGE_DIR="$DEVICE_REPO/forge"
# Default to wherever this forge/ came from, so a device repo synced from a fork keeps following
# the fork; the upstream URL is only the fallback for a FORGE_REF that records none.
FORGE_URL="${FORGE_URL:-$(sed -n 's/^url=//p' "$FORGE_DIR/FORGE_REF" 2>/dev/null | head -1)}"
FORGE_URL="${FORGE_URL:-https://github.com/TheDBP/rom-forge.git}"
REF="${1:-main}"

[ -d "$FORGE_DIR" ] || { echo "!! no forge/ at $FORGE_DIR — run from a device repo"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -f "$0"; rm -rf "$WORK"' EXIT
echo ">> fetching $FORGE_URL @ $REF"
git clone -q "$FORGE_URL" "$WORK/forge"
git -C "$WORK/forge" checkout -q "$REF"
SHA="$(git -C "$WORK/forge" rev-parse HEAD)"
SUBJ="$(git -C "$WORK/forge" log -1 --pretty=%s)"

# Sanity-check before destroying anything: a fetch that produced a non-forge tree must not land.
for f in bootstrap.sh docker/aosp.sh tools/apply-overlay.sh; do
  [ -f "$WORK/forge/$f" ] || { echo "!! $FORGE_URL@$REF has no $f — refusing to sync"; exit 1; }
done

# Fetched prebuilts (Magisk APK, F-Droid, Firefox) are gitignored, so they are not in upstream --
# a plain --delete mirror wipes them. That silently breaks a build in progress: bootstrap phase 0
# fetches Magisk, and a sync partway through leaves the post-build root step with nothing to bake,
# failing the run after the ROM has already compiled. Preserve them.
rsync -a --delete --exclude '.git' \
      --exclude 'prebuilt/Magisk-*.apk' \
      --exclude 'prebuilt/FDroid*.apk' \
      --exclude 'prebuilt/*.apk' \
      "$WORK/forge/" "$FORGE_DIR/"
cat > "$FORGE_DIR/FORGE_REF" <<EOF
# Pinned rom-forge commit vendored into forge/. Written by forge/tools/sync-forge.sh.
# Update with: ./forge/tools/sync-forge.sh [ref]
url=$FORGE_URL
ref=$REF
commit=$SHA
subject=$SUBJ
synced=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
echo ">> forge/ synced to ${SHA:0:12} ($SUBJ)"
echo "   pinned in forge/FORGE_REF — review with 'git status' and commit."
