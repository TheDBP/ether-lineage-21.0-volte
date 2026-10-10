#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_VOLTE=true.
#
# A VoLTE build whose IMS artifacts are missing is the expensive failure: the device tree's IMS
# packages are gated on WITH_VOLTE, so the gate being on while nothing was staged means either a
# build that dies at Soong hours in, or -- if the device guarded its install rules -- an image
# tagged for VoLTE that cannot place a call. Find it at minute 0 instead.
set -o pipefail
AOSP="${AOSP:-/aosp}"
[ -f "${DEVICE_REPO:?DEVICE_REPO unset}/device.conf" ] || { echo "!! volte: no device.conf at $DEVICE_REPO" >&2; exit 1; }
# A subshell: device.conf is a config file, not something to leak into the build environment.
MARKER="$( . "$DEVICE_REPO/device.conf" >/dev/null 2>&1; printf '%s' "${VOLTE_STAGED_MARKER:-}" )"
if [ -z "$MARKER" ]; then
  echo "!! volte: this device sets no VOLTE_STAGED_MARKER in device.conf, so there is no way to" >&2
  echo "!! tell a staged IMS stack from a missing one. Refusing to build." >&2
  exit 1
fi
if [ ! -e "$AOSP/$MARKER" ]; then
  echo "!! volte: nothing staged -- $AOSP/$MARKER does not exist." >&2
  echo "!! The IMS stack is rebuilt from the phone's own stock firmware; see the device repo's" >&2
  echo "!! VoLTE/IMS doc for what to supply and where to put it." >&2
  echo "!! Refusing to build an image that claims VoLTE and would not have it." >&2
  exit 1
fi
echo "   volte: IMS stack staged ($MARKER)"
