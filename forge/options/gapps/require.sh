#!/bin/bash
# require.sh -- checked BEFORE the build when WITH_GAPPS=true.
#
# extract-gapps-apps.sh stages the Google app replacements, and it runs only from bootstrap.sh's
# sync phase. A rebuild after a device retarget -- or any direct _build_rom.sh call -- would
# otherwise ship a WITH_GAPPS ROM whose stock apps were never swapped. Play Store and GMS still
# work, because those come from the vendor/gapps manifest repo, so the result looks correct and
# nothing warns: silently wrong contents, which is the failure this whole guard exists for.
set -o pipefail
_REPO="${DEVICE_REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
[ -f "$_REPO/device.conf" ] && . "$_REPO/device.conf"
EXTRAS="/aosp/vendor/extra/gapps-extras"
# WITH_GAPPS_EXTRAS=false is the deliberate "MindTheGapps only" build: Play Store and GMS, none
# of the Google app swaps. Said out loud on every build, because the difference is invisible in
# the image name and only shows up in which dialer you get.
if [ "${WITH_GAPPS_EXTRAS:-true}" != true ]; then
  echo "   gapps: MindTheGapps only (WITH_GAPPS_EXTRAS=false) -- Play Store and GMS, Lineage's own apps"
  exit 0
fi
if ! ls -d "$EXTRAS"/*/ >/dev/null 2>&1; then
  echo "!! gapps: $EXTRAS is missing or empty." >&2
  echo "!! The Google app swaps (Calculator/Calendar/Clock/Contacts/Files/Messages/Phone) would be" >&2
  echo "!! silently skipped, shipping Lineage's apps under a GApps tag. Refusing to build." >&2
  echo "!! Run: forge/tools/extract-gapps-apps.sh <GApps.zip|URL> /aosp" >&2
  echo "!! (bootstrap.sh does this during sync; a direct _build_rom.sh call does not)." >&2
  exit 1
fi
echo "   gapps: $(ls -d "$EXTRAS"/*/ 2>/dev/null | wc -l) app(s) staged in $EXTRAS"
