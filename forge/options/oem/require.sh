#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_OEM=true.
#
# The extractor runs only during bootstrap's sync phase. A rebuild, or a direct _build_rom.sh call,
# would otherwise produce a ROM tagged as carrying the manufacturer's assets while carrying none --
# every install rule in product.mk is wildcard-guarded, so nothing errors and nothing warns.
set -o pipefail
OEM=/aosp/vendor/extra/oem-assets
_n=$(find "$OEM" -type f \( -name '*.ogg' -o -name '*.png' -o -name 'bootanimation.zip' \) 2>/dev/null | wc -l)
if [ "$_n" -eq 0 ]; then
  echo "!! oem: nothing staged in $OEM." >&2
  echo "!! A WITH_OEM build would ship no reclaimed assets at all, silently, because every install" >&2
  echo "!! rule is wildcard-guarded. Refusing to build." >&2
  echo "!! Run the extractor for your pack (see OEM_ASSET_PACK in device.conf), or build without oem." >&2
  exit 1
fi
echo "   oem: $_n asset file(s) staged in $OEM"
