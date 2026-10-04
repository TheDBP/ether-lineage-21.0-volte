#!/usr/bin/env bash
# image-labels.sh — read the SELinux labels the image builder actually wrote, out of a built ext4
# image, before flashing it.
#
#   image-labels.sh <image> <path> [<path>...]       one line per path: label, or MISSING
#   image-labels.sh <image> --tree <dir>             every file under <dir> with its label
#
# <image> is a sparse or raw ext4 image (system.img, vendor.img, product.img ...). Paths are
# relative to the image root (for a system-as-root system.img, /vendor/odm/etc is "vendor/odm/etc").
# Needs `debugfs` (e2fsprogs) and, for sparse images, `simg2img` (ANDROID_HOST_OUT, or the out tree
# next to the image).
#
# The label on a path in the image is whatever the last matching file_contexts regex said at build
# time, and a path the rules do not know falls through to its parent partition's catch-all --
# silently, with no build error. The vs995 found out at runtime: vendor built into the system image
# puts the odm sepolicy files at /system/vendor/odm/etc/selinux/*, no odm rule knew that prefix, the
# whole subtree became vendor_file, and system_server died in PackageManagerService ("Unable to load
# SELinux MMAC policy") behind an endless boot animation. `ls -Z` on the phone would have said the
# same, after a flash; this says it from the out tree. Pair it with an avc denial's tcontext: if the
# image already carries the right label the problem is a policy rule, if not it is file_contexts.
set -uo pipefail
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C

IMG="${1:?usage: image-labels.sh <image> <path>... | --tree <dir>}"; shift
[ $# -gt 0 ] || { echo "need at least one path or --tree <dir>" >&2; exit 2; }
command -v debugfs >/dev/null || { echo "debugfs not found (install e2fsprogs)" >&2; exit 2; }

RAW="$IMG"; CLEAN=""
if [ "$(head -c4 "$IMG" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
  S2I=$(command -v simg2img || { ls "${ANDROID_HOST_OUT:-/nonexistent}/bin/simg2img" "$(dirname "$IMG")"/../../../host/linux-x86/bin/simg2img 2>/dev/null || true; } | sed -n 1p)
  [ -n "$S2I" ] && [ -x "$S2I" ] || { echo "sparse image and no simg2img (set ANDROID_HOST_OUT)" >&2; exit 2; }
  RAW="$(mktemp "$TMPDIR/image-labels.XXXXXX")"; CLEAN="$RAW"
  "$S2I" "$IMG" "$RAW" || exit 1
fi
trap '[ -n "$CLEAN" ] && rm -f "$CLEAN"' EXIT

label() {  # path -> label or MISSING; debugfs prints: security.selinux (N) = "u:object_r:x:s0\000"
  local v
  v=$(debugfs -R "ea_get \"$1\" security.selinux" "$RAW" 2>/dev/null | sed -n 's/.*= "\(.*\)\\000"$/\1/p')
  echo "${v:-MISSING}"
}

if [ "$1" = "--tree" ]; then
  DIR="${2:?--tree needs a directory}"
  walk() {  # debugfs ls -p: /inode/mode/uid/gid/name/size/
    local d="$1" line mode name
    debugfs -R "ls -p \"$d\"" "$RAW" 2>/dev/null | while IFS=/ read -r _ _ mode _ _ name _; do
      [ -n "$name" ] && [ "$name" != . ] && [ "$name" != .. ] || continue
      printf '%-50s %s\n' "$d/$name" "$(label "$d/$name")"
      case "$mode" in 04*) walk "$d/$name" ;; esac
    done
  }
  printf '%-50s %s\n' "$DIR" "$(label "$DIR")"; walk "$DIR"
else
  for p in "$@"; do printf '%-50s %s\n' "$p" "$(label "$p")"; done
fi
