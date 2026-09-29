#!/bin/bash
# post-patch.sh -- runs AFTER the device's patch series has been applied.
#
# MindTheGapps ships GmsCore only inside com.google.android.gmssystem.prodvic.apex, and Android
# 15+ builds APEX payloads as EROFS. A kernel without CONFIG_EROFS_FS cannot mount that: apexd
# reports "Mounting failed ... No such device" and the apex never activates, so Play Services is
# simply absent while every other GApps component installs normally. The visible symptom is
# SetupWizard stuck on "Just a sec" forever with GSF-provider crashes -- nothing that points at a
# filesystem. Measured on a Pixel 3a XL (4.9) 2026-09-23.
#
# APEX_EROFS_UNSUPPORTED=true in device.conf turns the repack on. Explicit, never probed: the
# kernel this build produces is not necessarily the one running, and guessing wrong silently ships
# a ROM whose Google half does not exist.
set -o pipefail
AOSP="${1:-/aosp}"
[ "${APEX_EROFS_UNSUPPORTED:-false}" = true ] || exit 0

_forge="${FORGE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
_gapps="$AOSP/vendor/gapps"
[ -d "$_gapps" ] || exit 0    # gapps tree not synced; require.sh reports that

# KEYS_DIR is a host path; inside the container the keys are bind-mounted here, read-only.
_keys="$AOSP/vendor/lineage-priv/keys"
[ -d "$_keys" ] || { echo "!! gapps: APEX_EROFS_UNSUPPORTED needs signing keys, but $_keys is not mounted." >&2
                     echo "!! Set KEYS_DIR in device.conf.local -- a test-key build cannot repack the apex." >&2; exit 1; }

echo "   gapps: APEX_EROFS_UNSUPPORTED -- repacking EROFS apex payloads as ext4"
"$_forge/tools/repack-erofs-apex.sh" "$_gapps" --aosp "$AOSP" --keys "$_keys" || exit 1
