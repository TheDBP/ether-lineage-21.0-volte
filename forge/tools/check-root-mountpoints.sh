#!/usr/bin/env bash
# check-root-mountpoints.sh — every top-level directory the init scripts mount or mkdir into must
# exist in the root filesystem image; the root is read-only, so a missing one fails silently.
#
#   check-root-mountpoints.sh <system.img> [<vendor.img> ...]
#
# Works on a system-as-root system.img (the root of the image is /). Walks every rc file the image
# carries (init.rc, */etc/init/*.rc, */etc/init/hw/*.rc) plus every fstab under */etc/, collects
# the first path component of each `mount ... /X`, `mkdir /X/...`, `mount_all` fstab mount point,
# and reports the /X that are not directories in the image root (fstab rows of type emmc/mtd are
# flash targets, not mounts, and are skipped). Needs debugfs (e2fsprogs); sparse
# images need simg2img.
#
# Why: Android 17 keeps the aconfig flag storage under /metadata, filled by aconfigd in post-fs. A
# device without a metadata partition, and without BOARD_USES_METADATA_PARTITION to put the mount
# point in the root image, has no /metadata at all: init's `mkdir /metadata/aconfig` fails on the
# read-only root, every aconfigd service stays stopped, AconfigPackage.load returns
# ERROR_PACKAGE_NOT_FOUND for every package, and system_server dies in AdvancedProtectionService
# ("Invalid feature flag") every ~20 s behind the boot animation. The fix on such a device is a
# tmpfs mount from the vendor rc plus the mount point; this check says from the out tree that the
# mount point is there. Exit 1 if any referenced top-level directory is missing.
set -uo pipefail
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C
[ $# -ge 1 ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v debugfs >/dev/null || { echo "debugfs not found (install e2fsprogs)" >&2; exit 2; }

RAWS=(); CLEAN=()
trap 'rm -f "${CLEAN[@]}"' EXIT
for img in "$@"; do
  if [ "$(head -c4 "$img" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
    S2I=$(command -v simg2img || { ls "${ANDROID_HOST_OUT:-/nonexistent}/bin/simg2img" "$(dirname "$img")"/../../../host/linux-x86/bin/simg2img 2>/dev/null || true; } | sed -n 1p)
    [ -n "$S2I" ] && [ -x "$S2I" ] || { echo "sparse image and no simg2img (set ANDROID_HOST_OUT)" >&2; exit 2; }
    raw="$(mktemp "$TMPDIR/check-root-mountpoints.XXXXXX")"; CLEAN+=("$raw")
    "$S2I" "$img" "$raw" || exit 1
    RAWS+=("$raw")
  else
    RAWS+=("$img")
  fi
done
SYS="${RAWS[0]}"

isdir()   { [ "$(debugfs -R "stat \"$2\"" "$1" 2>/dev/null | grep -c 'Type: directory')" -gt 0 ]; }
exists()  { [ "$(debugfs -R "stat \"$2\"" "$1" 2>/dev/null | grep -c '^Inode:')" -gt 0 ]; }
# files in <dir> whose name matches the ERE <pat>
list_in() { debugfs -R "ls -p \"$2\"" "$1" 2>/dev/null | awk -F/ -v pat="$3" '$3 ~ /^100/ && $6 ~ pat {print $6}'; }
cat_in()  { debugfs -R "cat \"$2\"" "$1" 2>/dev/null; }

# System-as-root: the image root carries init.rc (or system/etc/init/hw/init.rc with a /system dir).
if ! { exists "$SYS" init.rc || exists "$SYS" system/etc/init/hw/init.rc; }; then
  echo "not a system-as-root image (no init.rc at the root): the root directories come from the ramdisk, nothing to check here"; exit 0
fi

# Every rc and fstab the image carries.
files=()  # "raw|path"
for raw in "${RAWS[@]}"; do
  if exists "$raw" system/etc/init; then
    dirs="system/etc/init system/etc/init/hw system/vendor/etc/init system/vendor/etc/init/hw system/vendor/odm/etc/init system/product/etc/init system/system_ext/etc/init"
    fstabdirs="system/etc system/vendor/etc system/vendor/odm/etc"
    exists "$raw" init.rc && files+=("$raw|init.rc")
  else
    dirs="etc/init etc/init/hw odm/etc/init"; fstabdirs="etc odm/etc"
  fi
  for d in $dirs;      do for f in $(list_in "$raw" "$d" '[.]rc$');     do files+=("$raw|$d/$f"); done; done
  for d in $fstabdirs; do for f in $(list_in "$raw" "$d" '^fstab[.]'); do files+=("$raw|$d/$f"); done; done
done
[ ${#files[@]} -gt 0 ] || { echo "no rc or fstab files found in the given images" >&2; exit 2; }

# top-level component of every path init will mount or create
refs=$(for e in "${files[@]}"; do
  raw="${e%%|*}"; p="${e#*|}"
  case "$p" in
    *fstab.*) cat_in "$raw" "$p" | awk '!/^[[:space:]]*(#|$)/ && $2 ~ /^\// && $3 !~ /^(emmc|mtd)$/ {print $2}' ;;  # emmc/mtd rows are recovery flash targets, never mounted
    *) cat_in "$raw" "$p" | sed 's/#.*//' | awk '
         $1=="mkdir" && $2 ~ /^\// {print $2}
         $1=="mount" && NF>=4 {print $4}
         $1=="mount" && NF>=4 && $5 ~ /^\// {print $5}' ;;   # mount <fs> <dev> <dir> or with a 5th positional dir
  esac
done | sed -n 's|^/\([^/]*\).*|\1|p' | grep -v '^$' | sort -u)

missing=0; checked=0
for top in $refs; do
  checked=$((checked+1))
  isdir "$SYS" "$top" && continue
  if exists "$SYS" "$top"; then
    echo "   /$top: exists in the root but is not a directory (symlink to a later mount is fine)"; continue
  fi
  echo "!! /$top: referenced by an init script or fstab, not in the root image"; missing=$((missing+1))
  for e in "${files[@]}"; do
    raw="${e%%|*}"; p="${e#*|}"
    cat_in "$raw" "$p" | grep -nE "^[[:space:]]*(mkdir|mount|[^[:space:]#]+[[:space:]]+)/$top(/|[[:space:]]|$)" | sed -n "1,3s|^|      $p:|p"
  done
done
echo ">> check-root-mountpoints: $checked top-level directories referenced, $missing missing from the root image"
[ "$missing" = 0 ]
