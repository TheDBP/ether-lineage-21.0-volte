#!/bin/bash
# post-patch.sh -- stage the reworked OEM IMS stack, after the device patches are applied.
#
# After, not before: the rework script and everything it needs live in the device tree that those
# patches create. Running earlier finds nothing and, because the staging is wildcard-shaped on most
# devices, says nothing -- the same silent-success failure fetch.sh hit with F-Droid.
#
# Idempotent by marker: staging is minutes of deodex and dex rewriting, so a tree that already has
# it skips. Delete the marker to force a re-stage.
set -o pipefail
AOSP="${1:?usage: post-patch.sh <aosp-root>}"
[ -f "${DEVICE_REPO:?DEVICE_REPO unset}/device.conf" ] || { echo "   !! volte: no device.conf at $DEVICE_REPO"; exit 1; }
eval "$( . "$DEVICE_REPO/device.conf" >/dev/null 2>&1
         printf 'MARKER=%q\nSCRIPT=%q\nGLOB=%q\n' \
           "${VOLTE_STAGED_MARKER:-}" "${VOLTE_STAGE_SCRIPT:-}" "${VOLTE_STOCK_GLOB:-}" )"

if [ -n "$MARKER" ] && [ -e "$AOSP/$MARKER" ]; then
  echo "   volte: already staged ($MARKER) -- skipping"; exit 0
fi
if [ -z "$SCRIPT" ]; then
  # Some devices stage from their own device.mk instead (the Robin does). Nothing to do here; the
  # option's require.sh still checks the result, so this is not a silent pass.
  echo "   volte: no VOLTE_STAGE_SCRIPT -- device stages its own IMS artifacts"; exit 0
fi
[ -x "$DEVICE_REPO/$SCRIPT" ] || { echo "   !! volte: VOLTE_STAGE_SCRIPT '$SCRIPT' is not executable in $DEVICE_REPO"; exit 1; }

# Find the stock input the script needs. Looked for in the device repo root and the build root --
# the two places a large proprietary file can sit without being inside a git tree.
SRC=""
if [ -n "$GLOB" ]; then
  for c in "$DEVICE_REPO"/$GLOB "$DEVICE_REPO/build_output"/$GLOB; do
    [ -e "$c" ] && { SRC="$c"; break; }
  done
  [ -n "$SRC" ] || { echo "   !! volte: no $GLOB in $DEVICE_REPO -- cannot stage the IMS stack"; exit 1; }
fi
echo "   volte: staging the IMS stack from $(basename "${SRC:-<device-supplied>}") -- first build only, minutes"
"$DEVICE_REPO/$SCRIPT" "$SRC" "$AOSP" || { echo "   !! volte: $SCRIPT failed"; exit 1; }
[ -z "$MARKER" ] || [ -e "$AOSP/$MARKER" ] || { echo "   !! volte: $SCRIPT reported success but $MARKER is absent"; exit 1; }
echo "   volte: staged"
