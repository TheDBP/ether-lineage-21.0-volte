#!/usr/bin/env bash
# fetch-nextcloud.sh — download the Nextcloud bundle for the nextcloud option: the build F-Droid
# currently suggests of each app, verified against a pinned signing certificate (see
# lib-fdroid.sh). Runs in-container (network + aapt2/JDK/zipalign from the tree).
#   ./fetch-nextcloud.sh [AOSP_ROOT]
# FDROID_PINS="com.nextcloud.talk2=240000094 ..." holds any of them to one build.
# NEXTCLOUD_MODULES="NextcloudFiles NextcloudTalk NextPush" fetches a subset (the nextcloud-core
# option) and removes the rest from DEST, so a per-APK guard in the patch ships exactly the subset
# even in a tree that had the whole bundle before. NEXTCLOUD_LABEL names the option in messages.
#
# Each APK ships byte for byte, so what its author packed decides how it is wired, per fetch:
#   - native libraries compressed or unaligned in the APK (NC Passwords today; any of them after some
#     release) -> lib/arm64-v8a/*.so unpacked to <App>/lib/arm64-v8a/ beside it, which the branch's
#     module installs as app/<App>/lib/arm64/. PackageManager does not extract native libraries for
#     a bundled app, so without this the app dies at launch in UnsatisfiedLinkError.
#   - on Soong branches (22.2+; the patch's .gitignore lists /Android.bp) the module file is
#     WRITTEN here, Android.bp, gitignored: skip_preprocessed_apk_checks has to be set on exactly
#     the APKs Soong's check fails, and Soong refuses it on one that passes, so a static file cannot
#     be right across releases. 20.0's Android.mk needs no per-app knowledge (a wildcard on the
#     unpacked libraries) and comes from the patch.
set -euo pipefail

AOSP="${1:-/aosp}"; export AOSP
DEST="${FEATURE_DEST:-$AOSP/vendor/lineage/prebuilts/nextcloud}"
. "$(dirname "${BASH_SOURCE[0]}")/lib-fdroid.sh"

# module name | package | signer certificate sha256 (apksigner verify --print-certs, Signer #1)
# Files and Talk are Nextcloud GmbH's reproducible builds under Nextcloud's own key; the others are
# their authors' keys, as F-Droid publishes them. Read on 2026-09-17.
NEXTCLOUD_APPS='
NextcloudFiles  com.nextcloud.client                  5709576f9d6c6a7687dd5d56b269d1fa5e379702b91bc83f39fd7b7c597c1b83
NextcloudTalk   com.nextcloud.talk2                   5709576f9d6c6a7687dd5d56b269d1fa5e379702b91bc83f39fd7b7c597c1b83
NextPush        org.unifiedpush.distributor.nextpush  be6b681667944be91a62bc0f05200c5fcb9bc776a3a90b5b67ee0b9b9b063db4
NextcloudDeck   it.niedermann.nextcloud.deck          ea929cafc33a6ca77392809f53b1daf80992c4a83f4d11433200174493aebe93
NCPasswords     de.jbservices.nc_passwords_app        1c15bcadd013d7c0632f5a63604008f73d340e25de1b676fb22ca51287fffe1e
NextcloudNotes  it.niedermann.owncloud.notes          3e80f32df2c89e4cdd3a32f1002178d8d4f21b9da89f8add6abae29fd3c95c0b
DAVx5           at.bitfire.davdroid                   8b48e676a6864967791783c1d8d0fc0dd6d2ce33e1fb36787793ecd086d44707
Tasks           org.tasks                             a038a055bf43b2659cbaf862808afd5e447d4d0e2749a10391910009cbd8dcfa
'

LABEL="${NEXTCLOUD_LABEL:-nextcloud}"
# The rows this run fetches: all of them, or NEXTCLOUD_MODULES. An unknown name in the filter is an
# error, not a silently smaller bundle.
nextcloud_rows() {
  if [ -z "${NEXTCLOUD_MODULES:-}" ]; then printf '%s\n' "$NEXTCLOUD_APPS" | awk 'NF==3'; return; fi
  local m
  for m in $NEXTCLOUD_MODULES; do
    printf '%s\n' "$NEXTCLOUD_APPS" | awk -v m="$m" 'NF==3 && $1==m' | grep . \
      || { echo "!! $LABEL: NEXTCLOUD_MODULES names $m, which is not in the bundle" >&2; return 1; }
  done
}
# Called with no arguments from anything that only wants the module list (require.sh, post-build.sh).
nextcloud_modules() { nextcloud_rows | awk '{print $1}'; }
[ "${NEXTCLOUD_LIST_ONLY:-0}" = 1 ] && { nextcloud_modules; exit $?; }
nextcloud_rows >/dev/null || exit 1

mkdir -p "$DEST"
# Apps the bundle has but this run does not: gone from DEST, or the per-APK guard would ship them.
printf '%s\n' "$NEXTCLOUD_APPS" | awk 'NF==3 {print $1}' | while read -r mod; do
  case " $(nextcloud_modules | tr '\n' ' ') " in *" $mod "*) continue ;; esac
  [ -e "$DEST/$mod.apk" ] || [ -d "$DEST/$mod" ] || continue
  rm -rf "$DEST/$mod.apk" "$DEST/$mod.apk.download" "${DEST:?}/$mod"
  echo "   $LABEL: removed $mod (not in this bundle)"
done

fail=0
unpacked=""
while read -r mod pkg signer; do
  [ -n "$mod" ] || continue
  fdroid_stage "$pkg" "$DEST/$mod.apk" "$signer" "$mod" "$DEST/$mod" || { fail=1; continue; }
  [ "$FDROID_UNPACKED" = yes ] && unpacked="$unpacked $mod"
done <<EOF
$(nextcloud_rows)
EOF
[ "$fail" = 0 ] || { echo "!! $LABEL: one or more apps failed to fetch — see above" >&2; exit 1; }

if fdroid_bp_wanted "$DEST"; then
  fdroid_bp_begin "$DEST/Android.bp" fetch-nextcloud.sh
  while read -r mod pkg signer; do
    [ -n "$mod" ] || continue
    case " $unpacked " in *" $mod "*) u=yes ;; *) u=no ;; esac
    fdroid_bp_module "$DEST/Android.bp" "$mod" "$mod.apk" "$pkg" "$u"
  done <<EOF
$(nextcloud_rows)
EOF
  echo "   $LABEL: wrote $DEST/Android.bp (${unpacked:- no app} with unpacked libraries)"
fi
echo "   $LABEL: $(nextcloud_modules | wc -l) apps in $DEST ($(du -sh "$DEST" | cut -f1))"
