#!/usr/bin/env bash
# release.sh — publish the redistributable preset of a build, and refuse to publish anything else.
#
#   ./forge/tools/release.sh --dry-run          # show exactly what would be published
#   ./forge/tools/release.sh                    # audit and publish
#   ./forge/tools/release.sh --preset clean     # pick the preset explicitly; a second preset the
#                                               # same day is added to that day's release
#
# device.conf knobs: RELEASE_NAME (release title, default the codename), RELEASE_NAME_DENY,
# RELEASE_AUDIT_ALLOW (cleared sha256s), RELEASE_NO_RECOVERY=1 (recovery lives in boot; publish
# only the zip). Signing needs KEYS_DIR in device.conf.local at build time.
#
# Why this exists rather than `gh release upload`:
#
# A ROM built with WITH_OEM=true contains a manufacturer's boot animation, wallpapers and system
# sounds, reclaimed from their firmware. Running that on a phone you own is uncontroversial.
# Publishing it is redistribution of someone else's copyrighted assets, and the realistic
# consequence is not a letter to you -- it is a DMCA notice to whoever hosts the file, landing on
# the account that also holds every one of your repos.
#
# The two builds differ by one flag and their filenames differ by one word. So publishing goes
# through here, and here refuses anything that is not provably clean:
#
#   1. the preset's option set must contain neither gapps nor oem
#   2. the build's recorded provenance must agree
#   3. the built tree is scanned for OEM assets and GApps packages that should not be there
#   4. the release name is checked for trademarks you did not mean to put on a download page
#   5. the image is signed with your keys, not AOSP's public test keys
#
# Any one of those failing stops the release. None of them are skippable by accident.
set -euo pipefail
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

DRY=0; PRESET_NAME=""; SKIP_CONTENT=0; ZIP_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --preset)  PRESET_NAME="${2:?--preset needs a name}"; shift 2;;
    --zip)     ZIP_OVERRIDE="${2:?--zip needs a path}"; shift 2;;
    # Deliberately verbose. The content scan is the only check that looks at what is actually in
    # the image rather than at what the build claims, so turning it off should read like a decision.
    --skip-content-audit) SKIP_CONTENT=1; shift;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "!! unknown argument '$1'" >&2; exit 1;;
  esac
done

die()  { echo "!! $*" >&2; exit 1; }
ok()   { echo "   ok   $*"; }
info() { echo ">> $*"; }

# ---- 0. locate the device repo -----------------------------------------------------------------
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$REPO/device.conf" ] || die "no device.conf at $REPO (run this as ./forge/tools/release.sh from a device repo)"
# shellcheck disable=SC1091
source "$REPO/device.conf"
FORGE_DIR="$REPO/forge"; export FORGE_DIR
source "$FORGE_DIR/lib/presets.sh"
: "${DEVICE:?device.conf sets no DEVICE}"
: "${DEVICE_CODENAME:=${DEVICE##*/}}"
BRANCH="$(git -C "$REPO" branch --show-current 2>/dev/null || echo unknown)"

# ---- 1. choose a preset, and prove it is redistributable ----------------------------------------
# A preset is redistributable when its option set contains neither gapps (we are not handing out
# Google's apps) nor oem (we are not handing out the manufacturer's art). Everything else about the
# preset is irrelevant here.
pick_preset() {
  local n opts
  for n in $(forge_preset_names); do
    if [ -n "$PRESET_NAME" ]; then [ "$n" = "$PRESET_NAME" ] || continue; fi
    opts=" $(forge_preset_options "$n") "
    case "$opts" in *" gapps "*|*" oem "*) ;; *) printf '%s\n' "$n"; return 0 ;; esac
    if [ -n "$PRESET_NAME" ]; then
      die "preset '$PRESET_NAME' is not redistributable: its options are$opts"
    fi
  done
  if [ -n "$PRESET_NAME" ]; then
    die "no preset named '$PRESET_NAME' (PRESETS defines: $(forge_preset_names | tr '\n' ' '))"
  fi
  die "no preset omits both gapps and oem, so this device has nothing publishable"
}
VN="$(pick_preset)"
VT="$(forge_preset_tag "$VN")"
VOPTS="$(forge_preset_options "$VN")"
info "preset '$VN' (tag $VT): options [${VOPTS:-none}]"
case " $VOPTS " in *" gapps "*) die "refusing: preset '$VN' ships GApps" ;; esac
case " $VOPTS " in *" oem "*)   die "refusing: preset '$VN' ships reclaimed OEM assets" ;; esac
ok "option set is redistributable"

SRC="$REPO/build_output/src"

# ---- 2. find the artifact ----------------------------------------------------------------------
OUTDIR="$SRC/out/target/product/$DEVICE_CODENAME"
if [ -n "$ZIP_OVERRIDE" ]; then
  ZIP="$ZIP_OVERRIDE"
else
  # Straight from the build output only. Nothing writes staging/, so anything in it was copied by
  # hand from some other build; the audit below inspects the tree, and the tree is not that zip.
  # The tag is bounded on both sides: an EXTRA_OPTIONS build appends "-<option>" to it, so
  # turbo-libre-nextcloud must not answer for turbo-libre.
  ZIP="$(ls -t "$OUTDIR"/*-"$VT"-"$DEVICE_CODENAME".zip 2>/dev/null | head -1 || true)"
fi
[ -n "$ZIP" ] && [ -f "$ZIP" ] || die "no built zip for preset '$VN' (expected $OUTDIR/*-${VT}-${DEVICE_CODENAME}.zip) -- build it first: PRESET=$VN ./forge/bootstrap.sh"
info "artifact: $(basename "$ZIP") ($(du -h "$ZIP" | cut -f1))"
case "$(basename "$ZIP")" in
  *-"$VT"-"$DEVICE_CODENAME".zip) ok "filename carries the '$VT' tag" ;;
  *) die "refusing: $(basename "$ZIP") does not carry the '$VT' tag -- wrong artifact for preset '$VN'" ;;
esac

# ---- 3. provenance: what did the build actually think it was doing? -----------------------------
# _build_rom.sh writes out/.turbo_config before each build. It is the build's own record, and it
# is the cheapest way to catch a zip that was renamed or copied from another run.
PROV="$SRC/out/.turbo_config"
if [ -f "$PROV" ]; then
  P="$(cat "$PROV")"
  info "build provenance: $P"
  case "$P" in
    *"WITH_GAPPS=false"*) ;; *) die "refusing: provenance says this tree last built with GApps ($P)";;
  esac
  case "$P" in
    *"WITH_OEM=false"*) ;; *) die "refusing: provenance says this tree last built with OEM assets ($P)";;
  esac
  case "$P " in
    *"tag=$VT "*)
      ok "provenance matches preset '$VN'"
      # The provenance describes the tree; the zip is a file. If the tree has been rebuilt since
      # this zip was packaged, every content check below is inspecting something the zip is not.
      if [ "$PROV" -nt "$ZIP" ]; then
        die "refusing: $PROV is NEWER than $(basename "$ZIP").
   The tree has been rebuilt since that zip was packaged, so the audit below would be
   describing a different build. Re-run the build, or pass --zip explicitly if you know better."
      fi
      ;;
    *) [ -n "$ZIP_OVERRIDE" ] && echo "   note: provenance tag does not match '$VT' (--zip given, continuing)" \
         || die "refusing: provenance tag does not match '$VT' -- the tree has since built something else,
   so recovery.img and the content audit describe that build, not this zip. Rebuild the preset." ;;
  esac
else
  echo "   note: no build provenance at $PROV (tree cleaned?)"
fi

# ---- 4. content audit: look in the image, not at the label --------------------------------------
# Everything above trusts a label of some kind. This step does not: it scans what was actually
# staged into the system partition. Hash-matching against the extractor's own output directories
# means it stays correct when the asset list changes -- no filename list to keep in sync.
OUT="$SRC/out/target/product/$DEVICE_CODENAME"
if [ "$SKIP_CONTENT" = 1 ]; then
  echo "   !! content audit SKIPPED by --skip-content-audit"
elif [ ! -d "$OUT/system" ]; then
  die "cannot audit contents: no staged system tree at $OUT/system.
   The build tree was cleaned, so nothing here can look inside the image. Rebuild
   (PRESET=$VN ./forge/bootstrap.sh) or, if you are certain, re-run with --skip-content-audit."
else
  info "auditing staged image at $OUT/system"
  DEVTREE="$SRC/device/$DEVICE"
  hits=0

  # 4a. any file byte-identical to something the OEM extractor staged
  # Where the extractor stages OEM assets. vendor/extra/oem-assets is current; the device-tree dirs
  # are where it used to put them, kept so this still audits a tree built before that move. Looking
  # only at the old paths is how this check silently passed: they no longer exist, find returned
  # nothing, and the audit reported "no OEM assets to leak" on a build that was full of them.
  oem_files=$(find "$SRC"/vendor/extra/oem-assets "$SRC"/vendor/extra/overlay/oem-assets \
                   "$DEVTREE"/oem-sounds "$DEVTREE"/oem-wallpaper "$DEVTREE"/oem-boot \
                   "$DEVTREE"/overlay-oem -type f ! -name '.gitignore' ! -name 'assets.mk' 2>/dev/null || true)
  if [ -n "$oem_files" ]; then
    # Build a hash set of the staged image once, then look each OEM asset up in it.
    imgsums="$(mktemp)"; trap 'rm -f "$imgsums"' EXIT
    find "$OUT/system" -type f -print0 2>/dev/null | xargs -0 -r sha256sum 2>/dev/null | awk '{print $1}' | sort -u > "$imgsums"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      h="$(sha256sum "$f" | awk '{print $1}')"
      if grep -qx "$h" "$imgsums"; then
        echo "   !! OEM asset present in image: ${f#"$DEVTREE"/}"
        hits=$((hits+1))
      fi
    done <<<"$oem_files"
    ok "checked $(printf '%s\n' "$oem_files" | grep -c .) extracted OEM asset(s) against the image"
  else
    ok "no extracted OEM assets staged anywhere to leak"
  fi

  # 4b. GApps packages, by the names Google ships them under
  for g in PrebuiltGmsCore Phonesky GoogleServicesFramework GoogleLoginService SetupWizard \
           PrebuiltGmsCoreSc GmsCore VelvetOverlay; do
    if find "$OUT/system" -maxdepth 6 -type d -name "$g" 2>/dev/null | grep -q .; then
      echo "   !! GApps package present in image: $g"; hits=$((hits+1))
    fi
  done

  # 4c. every wallpaper shipped as a loose file must be one we can account for. This is the check
  # that does not know what it is looking for -- 4a and 4b only find things already named somewhere.
  # Accounted-for means: it is an asset from a feature this build enables (so, ours), or its hash is
  # listed in RELEASE_AUDIT_ALLOW with a reason. Anything else stops the release until a human says
  # what it is. It has already earned its place once, on a wallpaper nobody remembered shipping.
  featsums="$(mktemp)"
  find "$REPO/forge/options" -type f -path '*/assets/*' 2>/dev/null \
    -exec sha256sum {} \; 2>/dev/null | awk '{print $1}' | sort -u > "$featsums"
  allow_sums="$(printf '%s\n' ${RELEASE_AUDIT_ALLOW:-} | sed 's/#.*//' | tr -d ' \t' | grep -E '^[0-9a-f]{64}$' || true)"
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    h="$(sha256sum "$w" | awk '{print $1}')"
    if grep -qx "$h" "$featsums"; then
      ok "wallpaper $(basename "$w") is one of this build's own feature assets"
    elif printf '%s\n' "$allow_sums" | grep -qx "$h"; then
      ok "wallpaper $(basename "$w") cleared by RELEASE_AUDIT_ALLOW"
    else
      echo "   !! unaccounted wallpaper in image: ${w#"$OUT/system"/}"
      echo "      sha256 $h"
      echo "      Identify it. If it is redistributable, add the hash to RELEASE_AUDIT_ALLOW in"
      echo "      device.conf with a comment saying what it is and why it is safe to hand out."
      hits=$((hits+1))
    fi
  done < <(find "$OUT/system" -type d -path '*/media/wallpaper' -exec find {} -type f \; 2>/dev/null)
  rm -f "$featsums"

  [ "$hits" -eq 0 ] || die "content audit found $hits problem(s). Not publishing."
  ok "content audit clean"
fi

# ---- 4b. signing: test keys are public, so anyone can sign an "update" for a test-keys image ----
# Read from the zip itself, not the tree: META-INF/com/android/otacert is the certificate recovery
# verifies the zip against. If it is AOSP's public testkey, anyone can sign an "update" for this
# device. (ro.build.tags and the metadata fingerprint are no use: device trees spoof the stock
# fingerprint, which says release-keys regardless.)
TESTKEY="$SRC/build/make/target/product/security/testkey.x509.pem"
OTACERT="$(unzip -p "$ZIP" META-INF/com/android/otacert 2>/dev/null || true)"
[ -n "$OTACERT" ] || die "cannot check signing: no META-INF/com/android/otacert in $(basename "$ZIP")"
[ -f "$TESTKEY" ] || die "cannot check signing: no $TESTKEY to compare against (tree cleaned?)"
if [ "$(printf '%s' "$OTACERT" | openssl x509 -noout -fingerprint -sha256)" = "$(openssl x509 -in "$TESTKEY" -noout -fingerprint -sha256)" ]; then
  die "refusing: $(basename "$ZIP") is signed with AOSP's public test keys.
   Set KEYS_DIR in device.conf.local (forge/tools/make-keys.sh makes the keys) and rebuild."
fi
ok "OTA cert is not the AOSP testkey: $(printf '%s' "$OTACERT" | openssl x509 -noout -subject | sed 's/^subject=//')"

# ---- 5. naming -----------------------------------------------------------------------------------
# A download page is the most public thing in this project. Trademarks belong to their owners and
# putting one in a release title invites the one kind of letter a rights holder has a real incentive
# to send -- marks have to be policed to stay valid, copyright does not.
REL_NAME="${RELEASE_NAME:-$DEVICE_CODENAME}"
TAGNAME="${BRANCH}-$(date +%Y%m%d)-${DEVICE_CODENAME}"
TITLE="${REL_NAME} — ${BRANCH} (${VN})"
DENY="${RELEASE_NAME_DENY:-nextbit razer robin pixel google nexus motorola samsung oneplus xiaomi}"
for word in $DENY; do
  if printf '%s %s' "$TITLE" "$TAGNAME" | grep -qi "\b$word\b"; then
    die "refusing: release name contains '$word'.
   '$TITLE' / tag '$TAGNAME'
   Set RELEASE_NAME in device.conf to something that is yours, or adjust RELEASE_NAME_DENY if this
   is a false positive (a codename that happens to collide with a mark you are not using)."
  fi
done
ok "release name carries no denied trademark: '$TITLE'"

# ---- 6. checksum + notes -------------------------------------------------------------------------
SUM="$(sha256sum "$ZIP" | awk '{print $1}')"
# The zip does not write the recovery partition on an A-only device, and the zip is signed with
# keys only this recovery's otacerts trust -- so the recovery ships next to it, as
# <zipname-without-.zip>-recovery.img, from the same build (bacon builds it; it must be newer than
# the zip's provenance or it is from some other run).
RECOVERY="$OUT/recovery.img"; RECOVERY_ASSET=""; RECOVERY_SUM=""
if [ "${RELEASE_NO_RECOVERY:-0}" = 1 ]; then
  echo "   note: RELEASE_NO_RECOVERY=1 -- no recovery image published"
elif [ -f "$RECOVERY" ]; then
  [ -f "$PROV" ] && [ "$RECOVERY" -ot "$PROV" ] && die "refusing: $RECOVERY predates the build's provenance -- it is from another run"
  RECOVERY_ASSET="$TMPDIR/$(basename "${ZIP%.zip}")-recovery.img"
  cp -f "$RECOVERY" "$RECOVERY_ASSET"
  RECOVERY_SUM="$(sha256sum "$RECOVERY_ASSET" | awk '{print $1}')"
  ok "recovery image: $(basename "$RECOVERY_ASSET") ($(du -h "$RECOVERY" | cut -f1))"
else
  die "no $RECOVERY -- the zip cannot be installed without it. Rebuild, or if this device boots from the zip's own image, set RELEASE_NO_RECOVERY=1"
fi
NOTES="$(mktemp)"; SECTION="$(mktemp)"; trap 'rm -f "$NOTES" "$SECTION" "${imgsums:-}" "${RECOVERY_ASSET:-}"' EXIT
# Not `${VAR:-text}`: that expands to VAR's VALUE when it is set, which once put a local path in a
# published release body.
if [ -n "$RECOVERY_ASSET" ]; then
  RECOVERY_NOTE="The zip does not write recovery."
  RECOVERY_STEP="\`fastboot flash recovery\` the \`-recovery.img\` published beside the zip you pick, "
else
  RECOVERY_NOTE="The zip carries its own boot image, recovery included."
  RECOVERY_STEP=""
fi
# The body is one shared head plus one section per preset, so a second preset published the same
# day (same tag, same commit) appends its section instead of needing a release of its own.
cat > "$NOTES" <<EOF
Unofficial LineageOS build for \`$DEVICE_CODENAME\`, branch \`$BRANCH\`. One zip per preset below.

**What is not in it:** no Google apps, and none of the manufacturer's own boot animation, wallpapers
or system sounds. Those are theirs, not mine, so they are not mine to hand out. If you want them on
your phone, the build system can put them back from a copy of your phone's own stock firmware --
see \`forge/docs/OEM-ASSETS.md\`.

Like every Android ROM, this contains proprietary vendor firmware for the hardware to work at all.

**Installing:** ${RECOVERY_STEP}boot into recovery, *Factory reset*, then *Apply update → ADB
sideload* the zip, reboot. Updating from an earlier one of these builds: sideload the new zip, no
wipe. $RECOVERY_NOTE

No warranty. It wipes your phone. You already knew that.
EOF
cat > "$SECTION" <<EOF

## \`$VN\`

LineageOS plus: $(printf '%s' "${VOPTS:-nothing, this is the baseline}" | sed 's/ /, /g').

\`\`\`
$(basename "$ZIP")
sha256  $SUM${RECOVERY_ASSET:+
$(basename "$RECOVERY_ASSET")
sha256  $RECOVERY_SUM}
\`\`\`
EOF
cat "$SECTION" >> "$NOTES"
# The notes are published verbatim: nothing from this host may be in them.
grep -qF -e "$REPO" -e "$TMPDIR" -e "$HOME" "$NOTES" && die "refusing: release notes contain a path from this machine: $(grep -F -e "$REPO" -e "$TMPDIR" -e "$HOME" "$NOTES" | head -1)"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

# ---- 7. publish -----------------------------------------------------------------------------------
TARGET="${RELEASE_REPO:-$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')}"
[ -n "$TARGET" ] || die "no release target: set RELEASE_REPO in device.conf, or give this repo an origin"

# A release already tagged today, at this commit, is another preset of the same build: add this
# one to it. At any other commit it is a different build, and nothing here replaces a release.
EXISTING=""
if command -v gh >/dev/null && gh release view "$TAGNAME" --repo "$TARGET" >/dev/null 2>&1; then
  tagged="$(git -C "$REPO" ls-remote origin "refs/tags/$TAGNAME" 2>/dev/null | cut -f1)"
  [ "$tagged" = "$HEAD_SHA" ] || die "release $TAGNAME already exists on $TARGET at ${tagged:0:12}; this tree is at ${HEAD_SHA:0:12}"
  EXISTING="$(gh release view "$TAGNAME" --repo "$TARGET" --json assets -q '.assets[].name' | tr '\n' ' ')"
  case " $EXISTING " in *" $(basename "$ZIP") "*) die "release $TAGNAME already carries $(basename "$ZIP")" ;; esac
  TITLE="$(gh release view "$TAGNAME" --repo "$TARGET" --json name -q .name | sed "s/)\$/, $VN)/")"
fi

echo
info "ready to publish"
echo "   repo:   $TARGET"
echo "   tag:    $TAGNAME${EXISTING:+ (exists at this commit: adding to it, has $EXISTING)}"
echo "   title:  $TITLE"
echo "   asset:  $(basename "$ZIP")"
echo "   sha256: $SUM"
[ -n "$RECOVERY_ASSET" ] && { echo "   asset:  $(basename "$RECOVERY_ASSET")"; echo "   sha256: $RECOVERY_SUM"; }

if [ "$DRY" = 1 ]; then
  echo
  info "--dry-run: nothing published. Release notes would be:"
  if [ -n "$EXISTING" ]; then sed 's/^/   | /' "$SECTION"; echo "   (appended to the existing notes)"; else sed 's/^/   | /' "$NOTES"; fi
  exit 0
fi

command -v gh >/dev/null || die "gh CLI not installed"
if gh repo view "$TARGET" --json isPrivate -q .isPrivate 2>/dev/null | grep -qx true; then
  echo "   note: $TARGET is PRIVATE — the release will not be publicly downloadable until it is public."
fi

if [ -n "$EXISTING" ]; then
  gh release view "$TAGNAME" --repo "$TARGET" --json body -q .body > "$NOTES"
  cat "$SECTION" >> "$NOTES"
  gh release upload "$TAGNAME" "$ZIP" ${RECOVERY_ASSET:+"$RECOVERY_ASSET"} --repo "$TARGET"
  gh release edit "$TAGNAME" --repo "$TARGET" --title "$TITLE" --notes-file "$NOTES" >/dev/null
else
  # Without --target gh tags the repo's default branch, not the branch this zip came from.
  git -C "$REPO" fetch -q origin "$BRANCH" 2>/dev/null
  git -C "$REPO" merge-base --is-ancestor "$HEAD_SHA" "origin/$BRANCH" 2>/dev/null \
    || die "refusing: HEAD ${HEAD_SHA:0:12} is not on origin/$BRANCH -- push the branch first so the tag has something to point at"
  gh release create "$TAGNAME" "$ZIP" ${RECOVERY_ASSET:+"$RECOVERY_ASSET"} --repo "$TARGET" --target "$HEAD_SHA" --title "$TITLE" --notes-file "$NOTES"
fi
info "published: $(gh release view "$TAGNAME" --repo "$TARGET" --json url -q .url)"
