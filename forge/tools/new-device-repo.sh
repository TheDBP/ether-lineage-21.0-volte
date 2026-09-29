#!/usr/bin/env bash
# new-device-repo.sh — scaffold a device repo from scratch.
#
# Run from a rom-forge clone: creates the directory layout, vendors forge/ into it, writes a
# device.conf. sync-forge.sh cannot do this -- it lives inside forge/, which does not exist yet.
#
#   git clone https://github.com/TheDBP/rom-forge.git
#   ./rom-forge/tools/new-device-repo.sh ~/pixel3a-android
#
# With --codename: finds the LineageOS device tree, lists its branches, reads the product name from
# AndroidProducts.mk, pulls extra projects from lineage.dependencies, locates the TheMuppets blobs,
# and writes device.conf plus the local manifest. Reads the codename from a connected phone.
#
#   ./rom-forge/tools/new-device-repo.sh --codename bonito --branch lineage-22.2 ~/bonito-android
#   ./rom-forge/tools/new-device-repo.sh --codename bonito ~/bonito-android   # newest branch
#   ./rom-forge/tools/new-device-repo.sh ~/bonito-android                     # reads adb, or blank
#   ./rom-forge/tools/new-device-repo.sh --no-probe ~/somewhere               # offline, blank
#
# Unresolved values are left blank. bootstrap refuses to start on an unset key.
#
set -euo pipefail

FORGE_SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST=""; CODENAME=""; BRANCH=""; NO_PROBE=false; INPLACE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codename) CODENAME="${2:?}"; shift 2 ;;
    --device)   INPLACE="${2:?}";  shift 2 ;;
    --branch)   BRANCH="${2:?}";   shift 2 ;;
    --no-probe) NO_PROBE=true;     shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *)          DEST="$1";         shift ;;
  esac
done
# --device <name> scaffolds in place, under this clone's devices/<name>/, for people who would
# rather keep one directory than manage a repo per phone. No forge/ is copied in: bootstrap.sh
# --device layers the engine over /repo/forge inside the container instead.
if [ -n "$INPLACE" ]; then
  [ -n "$DEST" ] && { echo "!! --device and an explicit path are mutually exclusive"; exit 1; }
  DEST="$FORGE_SRC/devices/$INPLACE"
  [ -n "$CODENAME" ] || CODENAME="$INPLACE"
fi
[ -n "$DEST" ] || { echo "usage: $0 [--codename <name>] [--branch <lineage-XX.X>] [--no-probe] {<path> | --device <name>}"; exit 1; }

# ---- discovery -------------------------------------------------------------------------------
# Lookups, not guesses. A failed step leaves the value blank: a wrong value builds the wrong phone.
VENDOR_FOUND=""; PRODUCT=""; DEPS_JSON=""; BLOBS_REPO=""; BRANCHES=""

if [ "$NO_PROBE" != true ]; then
  if [ -z "$CODENAME" ] && command -v adb >/dev/null 2>&1; then
    CODENAME="$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r' || true)"
    [ -n "$CODENAME" ] && echo ">> detected connected device: $CODENAME"
  fi
fi

if [ -n "$CODENAME" ] && [ "$NO_PROBE" != true ]; then
  echo ">> looking for a LineageOS device tree for '$CODENAME' ..."
  for v in google lge nextbit xiaomi samsung oneplus motorola sony asus nothing fairphone essential razer zuk; do
    if git ls-remote --exit-code --heads "https://github.com/LineageOS/android_device_${v}_${CODENAME}" >/dev/null 2>&1; then
      VENDOR_FOUND="$v"; break
    fi
  done
  if [ -n "$VENDOR_FOUND" ]; then
    REPO="https://github.com/LineageOS/android_device_${VENDOR_FOUND}_${CODENAME}"
    echo "   found: LineageOS/android_device_${VENDOR_FOUND}_${CODENAME}"
    BRANCHES="$(git ls-remote --heads "$REPO" 2>/dev/null | grep -oE 'lineage-[0-9.]+' | sort -uV | tr '\n' ' ')"
    echo "   branches: ${BRANCHES:-none}"
    if [ -z "$BRANCH" ]; then
      BRANCH="$(echo $BRANCHES | tr ' ' '\n' | tail -1)"
      [ -n "$BRANCH" ] && echo "   defaulting to newest: $BRANCH  (override with --branch)"
    fi
    if [ -n "$BRANCH" ]; then
      RAW="https://raw.githubusercontent.com/LineageOS/android_device_${VENDOR_FOUND}_${CODENAME}/$BRANCH"
      # A device tree can serve several products (bonito's also builds sargo) -- match the codename.
      PRODUCT="$(curl -fsSL "$RAW/AndroidProducts.mk" 2>/dev/null | grep -oE "lineage_${CODENAME}\b" | head -1 || true)"
      DEPS_JSON="$(curl -fsSL "$RAW/lineage.dependencies" 2>/dev/null || true)"
    fi
    for br in "proprietary_vendor_${VENDOR_FOUND}_${CODENAME}" "proprietary_vendor_${VENDOR_FOUND}"; do
      if git ls-remote --exit-code --heads "https://github.com/TheMuppets/$br" >/dev/null 2>&1; then
        BLOBS_REPO="$br"; break
      fi
    done
    [ -n "$BLOBS_REPO" ] && echo "   blobs: TheMuppets/$BLOBS_REPO"
  else
    echo "   no LineageOS tree found for '$CODENAME'."
    echo "   That is a porting project, not a config problem — see the forge README."
  fi
fi

[ -e "$DEST" ] && { echo "!! $DEST already exists — refusing to overwrite"; exit 1; }
[ -f "$FORGE_SRC/bootstrap.sh" ] || { echo "!! $FORGE_SRC does not look like a rom-forge clone"; exit 1; }

mkdir -p "$DEST"/{overlay/local_manifests,overlay/patches}
touch "$DEST/overlay/patches/.gitkeep"

# forge/ is vendored (copied), not submoduled: keeps history squashable, and "which forge is this?"
# stays a single grep. sync-forge.sh takes over from here.
if [ -z "$INPLACE" ]; then
cp -a "$FORGE_SRC" "$DEST/forge"
rm -rf "$DEST/forge/.git"
( cd "$FORGE_SRC" && git rev-parse HEAD 2>/dev/null ) > /dev/null 2>&1 && {
  cat > "$DEST/forge/FORGE_REF" <<EOF
# Pinned rom-forge commit vendored into forge/. Written by forge/tools/sync-forge.sh.
# Update with: ./forge/tools/sync-forge.sh [ref]
url=$( cd "$FORGE_SRC" && git remote get-url origin 2>/dev/null || echo https://github.com/TheDBP/rom-forge.git )
ref=main
commit=$( cd "$FORGE_SRC" && git rev-parse HEAD )
subject=$( cd "$FORGE_SRC" && git log -1 --format=%s )
synced=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}
fi

# Blank the identity keys, then fill in what discovery resolved. Unresolved keys stay empty:
# bootstrap refuses to start on an unset key rather than guess. Single-line keys only: PRESETS
# spans several lines and is device-neutral as shipped, so it is copied through untouched --
# rewriting its first line left the example's rows dangling after the new block.
sed -E 's/^(DEVICE|DEVICE_CODENAME|DEVICE_SLUG|VENDOR|SOC|BRANCH|BASE_REF|LUNCH_TARGET)=[^#]*(#?)/\1=                    \2/' \
    "$FORGE_SRC/device.conf.example" > "$DEST/device.conf"
cp "$FORGE_SRC/device.conf.example" "$DEST/device.conf.example"

_set() {  # _set KEY VALUE  — fill a blanked key, preserving its trailing comment
  [ -n "$2" ] || return 0
  sed -i -E "s|^($1)=[[:space:]]*(#?)|\1=$2$(printf '%*s' 8 '')\2|" "$DEST/device.conf"
}
_set DEVICE           "${VENDOR_FOUND:+$VENDOR_FOUND/$CODENAME}"
_set DEVICE_CODENAME  "$CODENAME"
_set DEVICE_SLUG      "$CODENAME"
_set VENDOR           "$VENDOR_FOUND"
_set BRANCH           "$BRANCH"
_set BASE_REF         "${BRANCH:+m/$BRANCH}"
# LUNCH_TARGET's release suffix only exists after syncing (build/release/aconfig). Write the
# suffix-less form: correct on lineage-21 and earlier; on 22+ lunch rejects it and prints the valid
# choices.
_set LUNCH_TARGET     "${PRODUCT:+$PRODUCT-userdebug}"

if [ -z "$INPLACE" ]; then
cat > "$DEST/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
# Convenience shim -> the forge orchestrator. Logic lives in forge/; per-device config is
# ./device.conf. Run `./bootstrap.sh` or `./forge/bootstrap.sh` — same thing.
exec "$(cd "$(dirname "$0")" && pwd)/forge/bootstrap.sh" "$@"
EOF
chmod +x "$DEST/bootstrap.sh"
fi

if [ -z "$INPLACE" ]; then
cat > "$DEST/.gitignore" <<'EOF'
# heavy build state — re-created by the forge; never committed
/build_output/
out/
*.log
*.rej
*.orig
.DS_Store

# fetched prebuilts (re-downloaded on demand, often non-redistributable)
forge/prebuilt/*.apk

# historical session notes, kept on disk but not published
archive/

# personal, per-checkout build settings (KEYS_DIR, EXTRA_OPTIONS) -- never published
/device.conf.local
EOF
fi

# If discovery worked, write a real local manifest instead of leaving only the template.
if [ -n "$VENDOR_FOUND" ] && [ -n "$BRANCH" ]; then
  MF="$DEST/overlay/local_manifests/$CODENAME.xml"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<manifest>'
    printf '  <project name="LineageOS/android_device_%s_%s"\n' "$VENDOR_FOUND" "$CODENAME"
    printf '           path="device/%s/%s" remote="github" revision="%s" />\n' "$VENDOR_FOUND" "$CODENAME" "$BRANCH"
    # extra projects the device tree declares for itself
    if [ -n "$DEPS_JSON" ]; then
      printf '%s' "$DEPS_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for x in d:
    r=x.get("repository"); t=x.get("target_path")
    if r and t:
        print(f"  <project name=\"LineageOS/{r}\"")
        print(f"           path=\"{t}\" remote=\"github\" revision=\"BRANCH_PLACEHOLDER\" />")
' 2>/dev/null | sed "s/BRANCH_PLACEHOLDER/$BRANCH/"
    fi
    # Path depends on which repo form exists: a per-device repo mounts at vendor/<vendor>/<codename>,
    # a vendor-wide one at vendor/<vendor>. Getting this wrong puts the blobs where nothing looks.
    [ -n "$BLOBS_REPO" ] && {
      case "$BLOBS_REPO" in
        *_"$CODENAME") BLOBS_PATH="vendor/$VENDOR_FOUND/$CODENAME" ;;
        *)             BLOBS_PATH="vendor/$VENDOR_FOUND" ;;
      esac
      printf '  <project name="TheMuppets/%s"\n' "$BLOBS_REPO"
      printf '           path="%s" remote="github" revision="%s" />\n' "$BLOBS_PATH" "$BRANCH"
    }
    echo '</manifest>'
  } > "$MF"
  echo ">> wrote overlay/local_manifests/$CODENAME.xml"
  echo "   verify each revision with 'git ls-remote' — branch names differ between repos."
fi

cat > "$DEST/overlay/local_manifests/README.md" <<'EOF'
# local_manifests

XML fragments telling `repo` about projects the upstream manifest does not carry: your device tree,
its kernel, the vendor blobs, and anything else the device needs.

Minimal example — replace the names with your device's:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="LineageOS/android_device_<vendor>_<codename>"
           path="device/<vendor>/<codename>" remote="github" revision="lineage-22.2" />
  <project name="LineageOS/android_kernel_<vendor>_<soc>"
           path="kernel/<vendor>/<soc>" remote="github" revision="lineage-22.2" />
  <project name="TheMuppets/proprietary_vendor_<vendor>"
           path="vendor/<vendor>" remote="github" revision="lineage-22.2" />
</manifest>
```

Two things that will bite you:
- branch names differ per repo — check each with `git ls-remote` rather than assuming
- `--` is illegal inside an XML comment, and `repo sync` dies on it with "not well-formed"
EOF

# In-place devices live under the forge clone, which gitignores devices/. No repo of their own, so
# the config is not version-controlled.
if [ -z "$INPLACE" ]; then
( cd "$DEST" && git init -q && git add -A \
  && git -c user.name=rom-forge -c user.email=rom-forge@users.noreply.github.com \
       commit -q -m "scaffold device repo (rom-forge)" )
fi

if [ -n "$INPLACE" ]; then
cat <<EOF

  Created $DEST

  Next:
    1. check $DEST/device.conf
    2. check $DEST/overlay/local_manifests/
    3. cd $FORGE_SRC && ./bootstrap.sh --device $INPLACE

EOF
else
cat <<EOF

  Created $DEST

  Next:
    1. check $DEST/device.conf
    2. check $DEST/overlay/local_manifests/
    3. cd $DEST && ./bootstrap.sh

  Later, to pull a newer engine:  ./forge/tools/sync-forge.sh

EOF
fi
