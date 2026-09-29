#!/bin/bash
# gapps option, post-build hook -- prove the swapped-in Google apps can still install.
#
# Each swap is a presigned prebuilt. If the build rewrites the archive -- uncompressing JNI libs or
# dex, or zipaligning -- the APK Signature Scheme v2 signature no longer covers the file, and
# PackageManager rejects the package during the boot scan without logging anything. The build
# succeeds and the app is simply absent, taking the Lineage app it overrides with it: GoogleContacts
# overrides Contacts, so a failed swap leaves no contacts app at all and a dead dock tile.
#
# Measured here once: GoogleContacts 14,891,125 -> 19,776,651 bytes with its APK Sig Block gone.
set -uo pipefail

AOSP="${AOSP:-/aosp}"
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
OUT="$AOSP/out/target/product/${DEVICE_CODENAME:?DEVICE_CODENAME unset and device.conf not found}"
EXTRAS="$AOSP/vendor/extra/gapps-extras"

[ -d "$EXTRAS" ] || { echo "   gapps: nothing staged, skipping install check"; exit 0; }

bad=0 checked=0
for d in "$EXTRAS"/*/; do
  name="$(basename "$d")"
  src="$(find "$d" -maxdepth 1 -name '*.apk' -print -quit 2>/dev/null)"
  [ -n "$src" ] || continue
  ship="$(find "$OUT" -name "$(basename "$src")" -not -path '*/obj/*' -print -quit 2>/dev/null)"
  [ -n "$ship" ] || { echo "!! gapps: $name staged but not in the image"; bad=1; continue; }
  checked=$((checked + 1))
  cmp -s "$src" "$ship" || {
    echo "!! gapps: $name was rewritten by the build -- $(stat -c%s "$src") -> $(stat -c%s "$ship") bytes"
    bad=1
  }
done

if [ "$bad" -ne 0 ]; then
  echo "!! A rewritten presigned APK loses its v2 signature and PackageManager skips it at boot"
  echo "!! scan, silently. The app is absent, and so is the Lineage app it overrides."
  echo "!! Fix: android_app_import needs preprocessed: true (backport it if this Soong lacks it),"
  echo "!! or ship via BUILD_PREBUILT with LOCAL_SDK_VERSION so do_not_alter_apk copies it verbatim."
  exit 1
fi
echo "   gapps: $checked swapped app(s) shipped byte-identical -- signatures intact"

# The DocumentsUI rename is a source patch (README, "Two Files apps"); prove it is in the shipped
# APK. The previous overlay built and installed and never took, which is why this is checked.
APK="$(find "$OUT" -name DocumentsUI.apk -not -path '*/obj/*' -print -quit 2>/dev/null)"
AAPT2="$(find "$AOSP/out/host" -name aapt2 -type f -print -quit 2>/dev/null)"
if [ -n "$APK" ] && [ -n "$AAPT2" ]; then
  ref="$("$AAPT2" dump resources "$APK" 2>/dev/null | grep -A1 'string/launcher_label$' | tail -n1 | tr -d ' ()')"
  case "$ref" in
    @string/chip_title_documents) echo "   gapps: DocumentsUI launcher label -> Documents" ;;
    *) echo "!! gapps: DocumentsUI launcher_label is '$ref', not @string/chip_title_documents -- the rename patch did not ship"; exit 1 ;;
  esac
else
  echo "   gapps: DocumentsUI.apk or aapt2 not found; label check skipped"
fi
