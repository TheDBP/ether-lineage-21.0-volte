#!/bin/bash
# extract-nextbit-oem-assets.sh — reclaim the Nextbit Robin OEM assets (system sounds, wallpapers,
# boot animation) from a Nextbit Robin stock ROM and bake them into the tree being built.
#
#   ./extract-nextbit-oem-assets.sh <Ether_Stock_ROM.zip> [AOSP_ROOT]
#
# SCOPE: this handles exactly one asset pack -- the Nextbit Robin (ether) stock ROM, Android 7.
# It is not a general OEM extractor and will not work on other manufacturers' firmware. Modern OEM
# ROMs ship a payload.bin rather than a flat zip, put system in a dynamic super.img, and scatter
# assets across /product and /system_ext; none of that is handled here. Generic extraction is being
# developed separately: https://github.com/TheDBP/extract-oem-assets
#
# WHICH DEVICE IS BEING BUILT DOES NOT MATTER. The constraint is the *input*: any build may opt into
# this pack by setting OEM_ASSET_PACK=nextbit-robin, which is how the Pixel build borrows the Robin
# boot animation. The script verifies the zip really is a Nextbit ROM and refuses otherwise, so
# pointing it at a Pixel factory image fails loudly instead of silently baking nothing.
#
# The assets are PROPRIETARY (Nextbit), extracted from YOUR copy of the stock ROM. They are
# gitignored and never committed. AOSP_ROOT defaults to /aosp. Idempotent.

set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

ZIP="${1:?usage: extract-nextbit-oem-assets.sh <stock-rom.zip|URL> [AOSP_ROOT]}"
AOSP="${2:-/aosp}"
_SELF_REPO="$(cd "$(dirname "$0")/../.." && pwd)"; [ -f "$_SELF_REPO/device.conf" ] && source "$_SELF_REPO/device.conf"
: "${DEVICE:?device.conf missing or DEVICE unset}"
DEV="$AOSP/device/$DEVICE"

# Prefix for reclaimed ui/ sounds whose filename is already taken by LineageOS. Those names are
# functional rather than titular -- Effect_Tick is "the click" -- so the stock file is a rival
# implementation of the same slot, not a duplicate, and it needs a name of its own to sit beside
# the Lineage one instead of losing to it.
#
# Named for the PACK, not the device being built. The sounds are Nextbit's, and any device may
# select this pack (the Pixel build already borrows the Robin boot animation), so a device-derived
# prefix would be wrong on every build but one.
OEM_SOUND_PREFIX="${OEM_SOUND_PREFIX:-nextbit-}"
# Everything this script stages goes under vendor/extra, not the device tree, so the oem option is
# the same on every device and needs no device patch to install it. DEV is still used for the
# "is this device synced" sanity check and nothing else.
OEM="$AOSP/vendor/extra/oem-assets"
OEM_REL="vendor/extra/oem-assets"
OEM_OVL="$AOSP/vendor/extra/overlay/oem-assets"
OEM_OVL_REL="vendor/extra/overlay/oem-assets"
# DEV is the tree being built, which may be any device -- see the scope note at the top.

[ -d "$DEV" ] || { echo "!! $DEVICE device tree not found under $AOSP"; exit 1; }
command -v unzip >/dev/null || { echo "!! unzip not installed"; exit 1; }

# image converter for the Backgrounds thumbnails (ImageMagick 'convert', else ffmpeg)
CONVERT=""; command -v convert >/dev/null && CONVERT=convert
FFMPEG=""; command -v ffmpeg >/dev/null && FFMPEG=ffmpeg

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# $1 may be a local path OR an http(s) URL — if a URL, fetch it here (in-container) so nothing
# platform-specific runs on the host.
case "$ZIP" in
  http://*|https://*)
    echo ">> downloading stock ROM (in-container)"
    curl -fSL -o "$TMP/stock.zip" "$ZIP" || { echo "!! stock ROM download failed: $ZIP" >&2; exit 1; }
    ZIP="$TMP/stock.zip" ;;
esac
[ -f "$ZIP" ] || { echo "!! stock ROM not found: $ZIP" >&2; exit 1; }

# --- verify the input really is a Nextbit Robin stock ROM -------------------
# Gating on the *input* rather than on the device being built: any build may opt
# into this pack (the Pixel borrows the Robin boot animation), but pointing it at
# another manufacturer's firmware would silently bake nothing useful. A Nextbit
# ROM carries its own build fingerprint in system/build.prop.
if ! unzip -p "$ZIP" 'system/build.prop' 2>/dev/null | grep -qiE 'ro\.product\.(brand|manufacturer)=(nextbit|Nextbit)|ro\.product\.device=ether'; then
  echo "!! $(basename "$ZIP") does not look like a Nextbit Robin stock ROM."
  echo "!! This script handles exactly one asset pack (nextbit-robin, Android 7)."
  echo "!! Generic OEM extraction is a separate project: https://github.com/TheDBP/extract-oem-assets"
  exit 1
fi
echo "   verified: Nextbit Robin stock ROM"

# --- 1. system sounds (Robin-UNIQUE only) ---
# The stock Nextbit ROM bundles the whole classic AOSP ringtone/notification set on top of its
# own; baking all of it duplicates what LineageOS already ships. So bake ONLY the sounds unique
# to Robin: drop any stock file whose CONTENT (sha256) or BASENAME already exists in the Lineage
# audio set. The genuinely Nextbit-exclusive ones (Fillmore, BayBridgeLights, ...) survive.
echo ">> extracting system sounds (Robin-unique only)"
unzip -qo "$ZIP" 'system/media/audio/*' -d "$TMP"
if [ -d "$TMP/system/media/audio" ]; then
  ref_sha="$TMP/los_sha.txt"; ref_name="$TMP/los_name.txt"; : > "$ref_sha"; : > "$ref_name"
  for d in "$AOSP/frameworks/base/data/sounds" "$AOSP/vendor/lineage/prebuilt/common/media/audio"; do
    [ -d "$d" ] || continue
    find "$d" -name '*.ogg' -print0 | xargs -0 -r sha256sum 2>/dev/null | awk '{print $1}' >> "$ref_sha"
    find "$d" -name '*.ogg' -printf '%f\n' 2>/dev/null >> "$ref_name"
  done
  sort -u "$ref_sha" -o "$ref_sha"; sort -u "$ref_name" -o "$ref_name"

  rm -rf "$OEM/sounds/media/audio"; mkdir -p "$OEM/sounds/media/audio"
  kept=0; skipped=0; renamed=0; ns_names=""
  while IFS= read -r -d '' f; do
    rel="${f#"$TMP"/system/media/audio/}"
    # Content match means a real duplicate wherever it lives. A name match only means duplicate
    # for ringtones/notifications/alarms, where the filename is the tune's title and the same
    # title re-encoded is still the same tune. Under ui/ the name is a FUNCTION -- Effect_Tick is
    # "the click", ChargingStarted is "the charging sound" -- so a stock file sharing the name is
    # the manufacturer's own version of that sound, which is the whole point of this option.
    # Dropping those by name cost the Robin its entire UI set: click, keypresses, lock/unlock,
    # camera shutter and charging, 15 files, while its uniquely named ones came through.
    if grep -qxF "$(sha256sum "$f" | awk '{print $1}')" "$ref_sha"; then
      skipped=$((skipped+1)); continue          # identical content -> a real duplicate
    fi
    case "$rel" in
      ui/*)
        # Keep it, but namespace it if the name is taken. Installing a second Effect_Tick.ogg
        # would not work anyway: the framework resolves ui sounds under /product before /system,
        # Lineage fills /product, and the build keeps the first destination it sees for any
        # duplicate. A name of our own sidesteps both, leaves the Lineage sound installed and
        # selectable, and gives the overlay that selects ours something to point at.
        if grep -qxF "$(basename "$f")" "$ref_name"; then
          ns_names="$ns_names $(basename "$f")"
          rel="$(dirname "$rel")/$OEM_SOUND_PREFIX$(basename "$f")"
          renamed=$((renamed+1))
        fi
        ;;
      *) if grep -qxF "$(basename "$f")" "$ref_name"; then
           skipped=$((skipped+1)); continue     # same title -> the same tune re-encoded
         fi ;;
    esac
    mkdir -p "$OEM/sounds/media/audio/$(dirname "$rel")"
    cp -a "$f" "$OEM/sounds/media/audio/$rel"; kept=$((kept+1))
  done < <(find "$TMP/system/media/audio" -name '*.ogg' -print0)
  echo "   sounds: kept $kept ($renamed of them namespaced $OEM_SOUND_PREFIX*), skipped $skipped already-in-Lineage (of $((kept+skipped)))"
  [ "$kept" -gt 0 ] || echo "   !! kept 0 sounds — check the Lineage reference dirs exist under $AOSP"

  # Point the sound-effect table at the namespaced files. SoundEffectsHelper reads this table from
  # com.android.internal.R.xml.audio_assets, so a device overlay is what selects a different file;
  # copying the .ogg in is not enough on its own.
  #
  # The overlay REPLACES the stock resource, so it is derived from the stock file rather than
  # written from a template: every asset id the branch declares is preserved and only the file=
  # names we actually reclaimed are rewritten. A hand-written table would silently drop whatever
  # ids a future branch adds.
  _aa_src="$AOSP/frameworks/base/core/res/res/xml/audio_assets.xml"
  if [ -n "${ns_names// /}" ] && [ -f "$_aa_src" ]; then
    _aa_out="$OEM_OVL/frameworks/base/core/res/res/xml/audio_assets.xml"
    mkdir -p "$(dirname "$_aa_out")"; cp -f "$_aa_src" "$_aa_out"
    _aa_n=0
    for _n in $ns_names; do
      grep -q "file=\"$_n\"" "$_aa_out" || continue   # this branch's table does not use it
      sed -i "s|file=\"$_n\"|file=\"$OEM_SOUND_PREFIX$_n\"|g" "$_aa_out"
      _aa_n=$((_aa_n+1))
    done
    if [ "$_aa_n" -gt 0 ]; then
      echo "   sound effects: $_aa_n file(s) repointed to $OEM_SOUND_PREFIX* in the audio_assets overlay"
    else
      rm -f "$_aa_out"   # nothing we reclaimed is in the table; do not replace it for no reason
    fi
  fi

  # Lock, Unlock, Dock, Undock and the charging sound are not sound effects: SettingsProvider seeds
  # them into Settings.Global from string defaults holding an ABSOLUTE path, so they are repointed
  # by overriding those strings rather than by name lookup, and can point straight at /system.
  #
  # Which resource names to touch is read out of the stock file rather than hardcoded -- one
  # filename can back several settings (Dock.ogg is both the desk and the car dock sound), and a
  # branch may add more. Unlike the audio_assets file resource, a values/ overlay merges per
  # resource name, so only the overridden strings belong here.
  _sp_src="$AOSP/frameworks/base/packages/SettingsProvider/res/values/defaults.xml"
  if [ -n "${ns_names// /}" ] && [ -f "$_sp_src" ]; then
    _sp_out="$OEM_OVL/frameworks/base/packages/SettingsProvider/res/values/defaults.xml"
    _sp_body=""; _sp_n=0
    for _n in $ns_names; do
      while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        _sp_body="$_sp_body
$(printf '%s' "$_l" | sed "s|>[^<]*/$_n<|>/system/media/audio/ui/$OEM_SOUND_PREFIX$_n<|")"
        _sp_n=$((_sp_n+1))
      done < <(grep -E "<string name=\"[^\"]+\"[^>]*>[^<]*/$_n</string>" "$_sp_src" || true)
    done

    # The pack has no wired charging sound at all: ChargingStarted.ogg postdates Android 7. It does
    # carry a WirelessChargingStarted.ogg, because AOSP ships that one on every build whether or not
    # the hardware has a coil -- and the Robin has none, nor does the Pixel 3a XL that also takes
    # this pack. So the setting it would normally feed can never fire, and the reclaimed file would
    # be installed and never heard. Point the wired setting at it as well; that is the only way the
    # asset ever plays, and a device that does have wireless charging simply gets the same sound for
    # both. Skipped if the pack ever turns out to have its own ChargingStarted.ogg.
    _wcs="WirelessChargingStarted.ogg"
    case " $ns_names " in
      *" $_wcs "*)
        if [ ! -f "$TMP/system/media/audio/ui/ChargingStarted.ogg" ]; then
          _cl="$(grep -E '<string name="def_charging_started_sound"[^>]*>' "$_sp_src" || true)"
          if [ -n "$_cl" ]; then
            _sp_body="$_sp_body
$(printf '%s' "$_cl" | sed "s|>[^<]*<|>/system/media/audio/ui/$OEM_SOUND_PREFIX$_wcs<|")"
            _sp_n=$((_sp_n+1))
            echo "   + wired charging repointed to the pack's wireless sound (it ships no ChargingStarted.ogg)"
          fi
        fi
        ;;
    esac
    if [ "$_sp_n" -gt 0 ]; then
      mkdir -p "$(dirname "$_sp_out")"
      { echo '<?xml version="1.0" encoding="utf-8"?>'
        echo "<!-- Generated by $(basename "$0"): the manufacturer's own versions of these sounds,"
        echo "     reclaimed from its stock ROM and installed under /system with a $OEM_SOUND_PREFIX prefix"
        echo "     so they sit beside the LineageOS ones rather than replacing them. -->"
        echo '<resources>'
        printf '%s\n' "$_sp_body"
        echo '</resources>'
      } > "$_sp_out"
      echo "   sound settings: $_sp_n default(s) repointed to $OEM_SOUND_PREFIX* in the SettingsProvider overlay"
    fi
  fi
else
  echo "   !! no system/media/audio in the zip"
fi

# --- 2. wallpapers (inside NextbitWallpapers.apk) ---
echo ">> extracting OEM wallpapers"
unzip -qo "$ZIP" 'system/app/NextbitWallpapers/NextbitWallpapers.apk' -d "$TMP" || true
WPAPK="$TMP/system/app/NextbitWallpapers/NextbitWallpapers.apk"
BG="$OEM_OVL/packages/apps/Backgrounds/res"
if [ -f "$WPAPK" ]; then
  mkdir -p "$OEM/wallpaper" "$BG/drawable-nodpi" "$BG/values"
  unzip -qo "$WPAPK" 'res/drawable-nodpi-v4/*.png' -d "$TMP/wp" || true
  names=()
  for f in "$TMP"/wp/res/drawable-nodpi-v4/*.png; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; case "$base" in *_small.png) continue;; esac
    stem="robin_${base%.png}"
    cp -f "$f" "$OEM/wallpaper/$stem.png"          # (a) raw file (the wallpaper patch -> /product/media/wallpaper)
    # (b) Backgrounds picker: full JPG + 1/4 _small thumbnail
    if [ -n "$CONVERT" ]; then
      convert "$f" "$BG/drawable-nodpi/$stem.jpg"
      convert "$f" -resize 25% "$BG/drawable-nodpi/${stem}_small.jpg"
    elif [ -n "$FFMPEG" ]; then
      ffmpeg -y -loglevel error -i "$f" "$BG/drawable-nodpi/$stem.jpg"
      ffmpeg -y -loglevel error -i "$f" -vf "scale=iw/4:ih/4" "$BG/drawable-nodpi/${stem}_small.jpg"
    fi
    names+=("$stem")
  done
  echo "   wallpapers: ${#names[@]} images -> oem-wallpaper/ + Backgrounds overlay"

  # The original Robin home-screen scene lives in the stock framework-res.apk under the GENERIC name
  # default_wallpaper (so it's not in NextbitWallpapers.apk) — pull it in too, as "robin_scene".
  unzip -qo "$ZIP" 'system/framework/framework-res.apk' -d "$TMP/fw" 2>/dev/null || true
  DW=""; FWRES="$TMP/fw/system/framework/framework-res.apk"
  [ -f "$FWRES" ] && unzip -qo "$FWRES" 'res/drawable-nodpi-v4/default_wallpaper.png' -d "$TMP/fwdw" 2>/dev/null \
    && DW="$TMP/fwdw/res/drawable-nodpi-v4/default_wallpaper.png"
  if [ -f "${DW:-}" ]; then
    cp -f "$DW" "$OEM/wallpaper/robin_scene.png"
    if [ -n "$CONVERT" ]; then
      convert "$DW" "$BG/drawable-nodpi/robin_scene.jpg"
      convert "$DW" -resize 25% "$BG/drawable-nodpi/robin_scene_small.jpg"
      names+=("robin_scene"); echo "   + robin_scene (original Robin default wallpaper) -> picker"
    elif [ -n "$FFMPEG" ]; then
      ffmpeg -y -loglevel error -i "$DW" "$BG/drawable-nodpi/robin_scene.jpg"
      ffmpeg -y -loglevel error -i "$DW" -vf "scale=iw/4:ih/4" "$BG/drawable-nodpi/robin_scene_small.jpg"
      names+=("robin_scene"); echo "   + robin_scene (original Robin default wallpaper) -> picker"
    fi
  fi

  # Also expose the teal-shag DEFAULT wallpaper in the picker (the committed skin default), so it can
  # be re-selected after changing wallpaper. Source = what the teal-wallpaper option staged under
  # vendor/extra (apply-overlay runs first), else the device tree's own file. Added to the same
  # partner 'wallpapers' array.
  SHAG="$AOSP/vendor/extra/wallpaper/default_wallpaper.jpg"
  [ -f "$SHAG" ] || SHAG="$DEV/overlay/frameworks/base/core/res/res/drawable-nodpi/default_wallpaper.jpg"
  if [ -f "$SHAG" ] && [ -n "$CONVERT" ]; then
    convert "$SHAG" "$BG/drawable-nodpi/teal_shag.jpg"
    convert "$SHAG" -resize 25% "$BG/drawable-nodpi/teal_shag_small.jpg"
    names+=("teal_shag"); echo "   + teal_shag default -> picker"
  elif [ -f "$SHAG" ] && [ -n "$FFMPEG" ]; then
    ffmpeg -y -loglevel error -i "$SHAG" "$BG/drawable-nodpi/teal_shag.jpg"
    ffmpeg -y -loglevel error -i "$SHAG" -vf "scale=iw/4:ih/4" "$BG/drawable-nodpi/teal_shag_small.jpg"
    names+=("teal_shag"); echo "   + teal_shag default -> picker"
  fi

  # Override the Backgrounds picker array. The app reads "partner_wallpapers"; it has no array called
# "wallpapers" at all. Writing the latter produced a resource nothing consults, which is how the
# Robin wallpapers ended up compiled INTO Backgrounds.apk and still never appeared in the picker.
#
# The stock entries are read from the app rather than hardcoded. They used to be a fixed
# abstract_*/nature_*/urban_* list from an older LineageOS; on 20.0 not one of those names matches a
# drawable the app ships, so overriding with them would also have deleted every stock wallpaper from
# the picker. res_1080p and res_1440p carry identical names (only the images differ), so either is a
# valid source for the list.
if [ -n "$CONVERT$FFMPEG" ] && [ "${#names[@]}" -gt 0 ]; then
  _src=""
  for _c in "$AOSP/packages/apps/Backgrounds/res_1080p/values/arrays.xml" \
            "$AOSP/packages/apps/Backgrounds/res_1440p/values/arrays.xml" \
            "$AOSP/packages/apps/Backgrounds/res/values/arrays.xml"; do
    [ -f "$_c" ] && { _src="$_c"; break; }
  done
  _stock=""
  [ -n "$_src" ] && _stock=$(sed -n '/name="partner_wallpapers"/,/<\/array>/p' "$_src" \
      | grep -oE '<item>[^<]*' | sed 's|<item>||')
  if [ -z "$_stock" ]; then
    echo "!! oem: could not read partner_wallpapers from the Backgrounds app" >&2
    echo "!!      (looked in packages/apps/Backgrounds/res_1080p, res_1440p, res)" >&2
    echo "!!      Refusing to write the array from a guess: this overlay REPLACES the stock one," >&2
    echo "!!      so a wrong list removes every stock wallpaper from the picker." >&2
    exit 1
  fi
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">'
    echo '    <array name="partner_wallpapers" translatable="false">'
    for w in $_stock "${names[@]}"; do
      echo "        <item>$w</item>"
    done
    echo '    </array>'
    echo '</resources>'
  } > "$BG/values/arrays.xml"
  echo "   Backgrounds picker: partner_wallpapers = $(echo $_stock | wc -w) stock + ${#names[@]} Robin entries"
  else
    echo ""
    echo "   ##################################################################"
    echo "   ## !! NO IMAGE CONVERTER (ImageMagick 'convert' / ffmpeg) ON HOST"
    echo "   ## !! Backgrounds-picker wallpapers SKIPPED — the Robin wallpapers"
    echo "   ## !! will NOT appear in the wallpaper picker in this build."
    echo "   ## !! Fix:  sudo apt-get install -y imagemagick   then rebuild."
    echo "   ##################################################################"
    echo ""
  fi
else
  echo "   !! NextbitWallpapers.apk not found in the zip"
fi

# --- 3. nav-bar icons: NOT EXTRACTED ------------------------------------------------------------
# The Robin's three nav icons used to be pulled out of the stock SystemUI.apk. They are not any
# more, and on purpose.
#
# The stock art is 49x49 and ships at xxhdpi only -- ~16.3dp, off Android's 24dp icon grid, with
# no other density in the APK. Any device that isn't xxhdpi upscales a tiny bitmap, and even the
# Robin downscales it (it reports density 420, so the 480-bucket asset is resampled by 0.875).
# The PNGs are also flat white with an alpha channel, so they cannot be tinted and stay white
# regardless of the nav bar's theme.
#
# They turned out to be one annulus cut three ways, which redraws exactly as vectors. The
# replacements are the nav-icons build option (forge/options/nav-icons): scalable, tintable, drawn
# from scratch rather than lifted from someone's firmware.

# Panel size from the device tree: TARGET_SCREEN_WIDTH/HEIGHT, the device's own lineage_<codename>.mk
# first (bonito's dir also holds sargo's, a different height), then anything under device/<vendor>
# (the V20 declares it in v20-common). Prints "W H" portrait -- ether declares them landscape -- or
# nothing if the tree does not say.
_panel_size() {
  local f w="" h=""
  for f in "$DEV/lineage_${DEVICE_CODENAME:-${DEVICE##*/}}.mk" "$DEV"/*.mk "$AOSP/device/${DEVICE%%/*}"/*/*.mk; do
    [ -f "$f" ] || continue
    w="$(sed -n -E 's/^[[:space:]]*TARGET_SCREEN_WIDTH[[:space:]]*:?=[[:space:]]*([0-9]+).*/\1/p' "$f" | tail -n1)"
    h="$(sed -n -E 's/^[[:space:]]*TARGET_SCREEN_HEIGHT[[:space:]]*:?=[[:space:]]*([0-9]+).*/\1/p' "$f" | tail -n1)"
    [ -n "$w" ] && [ -n "$h" ] && break
  done
  [ -n "$w" ] && [ -n "$h" ] || return 0
  if [ "$w" -gt "$h" ]; then echo "$h $w"; else echo "$w $h"; fi
}

# --- 4. boot animation (the original Robin bootanimation.zip) ---
echo ">> extracting OEM boot animation"
unzip -qo "$ZIP" 'system/media/bootanimation.zip' -d "$TMP" || true
SBA="$TMP/system/media/bootanimation.zip"
if [ -f "$SBA" ]; then
  mkdir -p "$OEM" "$TMP/ba"
  unzip -qo "$SBA" -d "$TMP/ba" 2>/dev/null || true
  # On-device the verbatim stock asset rendered as a centered logo on BLACK with the gradient only
  # flashing inside the logo box. Nextbit ships each part as one full-screen gradient (bg.png,
  # 1080x1920) + many TRANSPARENT logo frames (550x400) that the AOSP player never composites: bg.png
  # sorts AFTER the uppercase Nextbit_Logo_* names so it plays as its own frame (the flash), and the
  # 550x400 canvas confines everything to a centred box. Fix = FLATTEN: bake the gradient under every
  # logo frame at full size, drop the standalone bg.png, declare the real 1080x1920 canvas. The logo
  # stays centred at its native 550x400 (gravity center, not scaled) — same logo, now over the gradient.
  composited=0
  if command -v convert >/dev/null; then
    for part in "$TMP"/ba/part*; do
      [ -d "$part" ] || continue
      bg="$part/bg.png"; [ -f "$bg" ] || continue
      for f in "$part"/*.png; do
        [ "$f" = "$bg" ] && continue
        convert "$bg" "$f" -gravity center -composite "$f" \
          || { echo "   !! boot-anim composite failed on $f"; composited=-1; break 2; }
      done
      rm -f "$bg"; composited=1
    done
  fi
  if [ "$composited" = "1" ] && [ -f "$TMP/ba/desc.txt" ] && command -v identify >/dev/null; then
    # canvas = the (now uniform) real frame size; keep fps + part lines. Glob-loop for any frame,
    # NOT `find | head` — SIGPIPE under `set -o pipefail` would abort the script.
    first=""; for f in "$TMP"/ba/part*/*.png; do [ -e "$f" ] && { first="$f"; break; }; done
    dims=""; [ -n "$first" ] && dims="$(identify -format '%w %h' "$first" 2>/dev/null)"
    old="$(awk 'NR==1{print $1, $2}' "$TMP/ba/desc.txt")"
    fps="$(awk 'NR==1{print $3}' "$TMP/ba/desc.txt")"; [ -n "$fps" ] || fps=20
    if [ -n "$dims" ] && [ "$dims" != "$old" ]; then
      { echo "$dims $fps"; tail -n +2 "$TMP/ba/desc.txt"; } > "$TMP/ba/desc.txt.new" \
        && mv "$TMP/ba/desc.txt.new" "$TMP/ba/desc.txt"
      echo "   fixed bootanimation: gradient composited under frames, bg.png dropped; canvas $old -> $dims (fps $fps)"
    fi
  elif [ "$composited" != "1" ]; then
    echo "   !! boot-anim NOT flattened (ImageMagick 'convert' missing?) — shipping stock frames/canvas as-is"
  fi
  # Scale to the panel. The player centres the canvas and never scales it, so the Robin's 1080x1920
  # frames sit in a black border on any larger panel (V20: 1440x2560). Cover-and-crop to the panel:
  # the gradient loses a sliver at the edges, the centred logo is untouched. Only after flattening --
  # scaling the transparent 550x400 logo frames alone would just make the box bigger.
  panel="$(_panel_size)"
  if [ "$composited" = "1" ] && [ -n "$panel" ] && [ -f "$TMP/ba/desc.txt" ]; then
    pw="${panel% *}"; ph="${panel#* }"
    cur="$(awk 'NR==1{print $1, $2}' "$TMP/ba/desc.txt")"
    if [ "$cur" != "$pw $ph" ]; then
      scaled=1
      for f in "$TMP"/ba/part*/*.png; do
        [ -e "$f" ] || continue
        convert "$f" -resize "${pw}x${ph}^" -gravity center -extent "${pw}x${ph}" "$f" \
          || { echo "   !! boot-anim scale failed on $f -- shipping at $cur"; scaled=0; break; }
      done
      if [ "$scaled" = "1" ]; then
        fps="$(awk 'NR==1{print $3}' "$TMP/ba/desc.txt")"; [ -n "$fps" ] || fps=20
        { echo "$pw $ph $fps"; tail -n +2 "$TMP/ba/desc.txt"; } > "$TMP/ba/desc.txt.new" \
          && mv "$TMP/ba/desc.txt.new" "$TMP/ba/desc.txt"
        echo "   scaled bootanimation $cur -> $pw $ph (the panel this tree declares)"
      fi
    fi
  elif [ "$composited" = "1" ] && [ -z "$panel" ]; then
    echo "   .. no TARGET_SCREEN_WIDTH/HEIGHT in the device tree; bootanimation stays at its native size"
  fi
  # Re-zip STORED (bootanim requires uncompressed frames; desc.txt first so it is read fast).
  rm -f "$OEM/bootanimation.zip"
  ( cd "$TMP/ba" && zip -q -0 -X "$OEM/bootanimation.zip" desc.txt \
      && zip -q -0 -rX "$OEM/bootanimation.zip" . -x desc.txt ) || \
    cp -f "$SBA" "$OEM/bootanimation.zip"   # fall back to the raw stock zip if re-zip failed
  echo "   boot animation -> oem-boot/ (device.mk copies it to /product/media, which wins over Lineage's)"
else
  echo "   !! bootanimation.zip not found in the zip"
fi

# Fail loudly if a supposedly-valid zip produced nothing — the device makefiles consume these via
# $(wildcard ...), so an empty extraction would silently ship a "full"/"robin" ROM with no OEM assets.
tot_snd=$(find "$OEM/sounds" -name '*.ogg' 2>/dev/null | wc -l)
tot_wp=$(find "$OEM/wallpaper" -name '*.png' 2>/dev/null | wc -l)
tot_boot=$([ -f "$OEM/bootanimation.zip" ] && echo 1 || echo 0)
echo ">> extracted: $tot_snd sound(s), $tot_wp wallpaper(s), $tot_boot boot anim"
if [ $((tot_snd + tot_wp + tot_boot)) -eq 0 ]; then
  echo "!! extraction produced NOTHING from $ZIP — wrong or corrupt stock ROM? Failing." >&2
  exit 1
fi

# Emit the PACK-SPECIFIC half of the makefile. The oem option's product.mk knows how to install
# sounds, wallpapers and a boot animation on any device; it cannot know that this particular
# manufacturer called its ringtone Fillmore.ogg. That knowledge belongs to the pack, so the pack
# writes it out here and the option -includes it -- the same split gapps uses for packages.mk.
cat > "$OEM/assets.mk" <<EOM
# generated by $(basename "$0") -- do not edit. Pack: nextbit-robin.
EOM
if [ "$tot_snd" -gt 0 ]; then
  # These are the Nextbit Robin's own defaults, and only meaningful because the matching .ogg files
  # were just staged. Guarded on each file existing so a partial extraction cannot point a property
  # at a sound that is not there -- SoundPool then falls back silently and the phone is simply mute.
  for _pair in "ro.config.ringtone:Fillmore.ogg" \
               "ro.config.notification_sound:BayBridgeLights.ogg" \
               "ro.config.alarm_alert:PalaceOfFineArts.ogg"; do
    _prop="${_pair%%:*}"; _snd="${_pair#*:}"
    if find "$OEM/sounds/media/audio" -name "$_snd" 2>/dev/null | grep -q .; then
      echo "PRODUCT_PROPERTY_OVERRIDES += $_prop=$_snd" >> "$OEM/assets.mk"
    else
      echo "   note: $_snd not in this ROM; leaving $_prop alone"
    fi
  done
fi
# The Robin's own home scene, when it was recovered. The device decides whether to use it as the
# default wallpaper -- this only says that the pack has one.
#
# This goes in its OWN file, not assets.mk, because of WHO reads it. assets.mk is -included by the
# oem option, which lives in vendor/extra/product.mk -- and that is inherited AFTER the device
# makefile. A variable set there is still empty when device.mk tests it, so every WITH_OEM build
# silently kept the teal-shag as its default wallpaper. The device -includes this file itself, in
# its own scope, in time for the decision.
cat > "$OEM/assets-vars.mk" <<EOM
# generated by $(basename "$0") -- do not edit. Pack: nextbit-robin.
# Read by the DEVICE makefile (-include), not by the oem option -- see extract script for why.
EOM
if [ -f "$OEM/wallpaper/robin_scene.png" ]; then
  echo "OEM_DEFAULT_WALLPAPER := /product/media/wallpaper/robin_scene.png" >> "$OEM/assets-vars.mk"
fi
echo ">> wrote $OEM_REL/assets-vars.mk"
echo ">> wrote $OEM_REL/assets.mk ($(grep -c . "$OEM/assets.mk") line(s))"

echo ">> done. Build a preset whose options include 'oem' to ship these."
