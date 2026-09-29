#!/usr/bin/env bash
# check-tree-dirt.sh — every uncommitted change in a patched project should have been put there by
# forge. Prove it, and shout about anything that was not.
#
#   check-tree-dirt.sh [AOSP_ROOT]
#
# WHY
#
# A synced tree is normally dirty after a build, and that is fine: options stage assets into it,
# kernel config fragments get appended, prebuilt APKs get downloaded into it. `git status` in those
# projects is therefore noisy by design, and `refresh-patches.sh` prints "uncommitted changes -- they
# will NOT be exported" so often that it reads as background hum.
#
# Which is the problem. A hand edit made directly in the synced tree looks exactly like that hum. It
# will not be exported as a patch, it will be destroyed by the next `repo sync --force-sync`, and
# nothing will have warned you. The work is simply gone, and the ROM quietly stops matching the
# repo.
#
# So: attribute every dirty path to the thing that generated it, and report anything left over.
#
# WHAT COUNTS AS ATTRIBUTED
#
#   - a destination named in some options/<opt>/assets.list  (copy / copy? / rm)
#   - a path under a FEATURE_DEST from some options/<opt>/fetch.sh  (downloaded prebuilts)
#   - a kernel defconfig whose diff carries a "# --- rom-forge:" marker (KERNEL_CONFIGS fragments)
#
# Anything else is unexplained and is reported. That is not automatically a bug -- you may have
# edited a file on purpose, mid-debug -- but it should be a decision, not a surprise.
set -uo pipefail

ARG="${1:-}"
# Normally forge/ is vendored inside the device repo, so ../.. is it. But this tool is just as
# likely to be run from the canonical rom-forge checkout while standing in a device repo, so fall
# back to the working directory rather than refusing.
DEVICE_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
if [ ! -f "$DEVICE_REPO/device.conf" ] && [ -f "$PWD/device.conf" ]; then
  DEVICE_REPO="$PWD"
fi
[ -f "$DEVICE_REPO/device.conf" ] || {
  echo "!! no device.conf: run this from a device repo, or from its vendored forge/" >&2; exit 1; }
# shellcheck disable=SC1091
source "$DEVICE_REPO/device.conf"
[ -f "$DEVICE_REPO/device.conf.local" ] && source "$DEVICE_REPO/device.conf.local"
AOSP="${ARG:-${BUILD_ROOT:-$DEVICE_REPO/build_output}/src}"
FORGE="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$AOSP" ] || { echo "!! no synced tree at $AOSP" >&2; exit 1; }
export LC_ALL=C

W=$(mktemp -d "${TMPDIR:-/tmp}/tree-dirt.XXXXXX"); trap 'rm -rf "$W"' EXIT

# ---- build the attribution list ---------------------------------------------------------------
: > "$W/allow"
for al in "$FORGE"/options/*/assets.list; do
  [ -f "$al" ] || continue
  # "copy <src> <dest>", "copy? <src> <dest>", "rm <dest>"
  awk '/^[[:space:]]*#/ || NF==0 { next }
       $1=="copy" || $1=="copy?" { print $3 }
       $1=="rm"                  { print $2 }' "$al"
done >> "$W/allow"
# Any option script that names a destination under $AOSP. Three mechanisms use this and they are
# easy to miss one at a time: fetch.sh sets FEATURE_DEST for downloaded prebuilts, and post-patch.sh
# / post-build.sh place files directly -- firefox does both, staging the same APK into
# vendor/lineage/prebuilts AND into device/<device>/ as a legacy device-tree module. So match on the
# "$AOSP/" prefix rather than on any one variable name.
for fs in "$FORGE"/options/*/fetch.sh "$FORGE"/options/*/post-patch.sh "$FORGE"/options/*/post-build.sh; do
  [ -f "$fs" ] || continue
  grep -oE '"\$AOSP/[^"]+"' "$fs" 2>/dev/null | sed -E 's|^"\$AOSP/||; s|"$||'
done >> "$W/allow"
# An unexpanded ${VAR} in a destination cannot be matched literally, so keep the fixed prefix
# before it as a directory wildcard. An entry whose variable is at the START has no fixed prefix and
# would reduce to a bare "*", which matches every path and silently turns this whole check into a
# no-op -- so those are dropped instead. (Found by the negative test below; before this the check
# passed on any input, including a file planted specifically to be caught.)
# Replace each unexpanded variable with a single "*" and KEEP the rest of the path. Truncating to
# end-of-line instead turns device/${DEVICE}/firefox into "device/*", which allows every path under
# device/ -- a second way of quietly making this check a no-op, and one the negative test caught
# only because the planted file happened to live there. Entries left with no literal component at
# all are dropped.
sed -i -E 's|\$\{[^}]*\}|*|g; s|\$[A-Za-z_][A-Za-z0-9_]*|*|g' "$W/allow"
sed -i -E '\|^[*/]*$|d; /^$/d' "$W/allow"
sort -u "$W/allow" -o "$W/allow"
NALLOW=$(grep -c . "$W/allow" || true)
echo ">> $NALLOW generated paths declared by forge options"

attributed() {           # $1 = path relative to AOSP root
  local p="$1" a
  while read -r a; do
    [ -n "$a" ] || continue
    # glob match: the entry may contain "*" where an unexpanded variable was
    # shellcheck disable=SC2053
    [[ $p == $a ]]   && return 0   # the path itself is generated
    # shellcheck disable=SC2053
    [[ $p == $a/* ]] && return 0   # the path sits inside a generated directory
    # shellcheck disable=SC2053
    [[ $a == $p/* ]] && return 0   # the path IS a directory generated paths live under
  done < "$W/allow"
  return 1
}

# ---- walk the patched projects ----------------------------------------------------------------
UNEXPLAINED=0
for proj in ${PATCHED_PROJECTS:-}; do
  d="$AOSP/$proj"
  [ -d "$d/.git" ] || continue
  dirty=$(git -C "$d" status --porcelain 2>/dev/null) || continue
  [ -n "$dirty" ] || continue

  hits=""
  while read -r st path; do
    [ -n "$path" ] || continue
    path="${path%/}"
    full="$proj/$path"
    if attributed "$full"; then continue; fi
    # Anything forge appends to a file labels itself. There are two such generators and they use
    # different wording, so match the name rather than either phrasing: KERNEL_CONFIGS appends
    # "# --- rom-forge:<frag>" to a defconfig on kernels with no %.config rule, and
    # KERNEL_EXTRA_CONFIGS appends "# added by rom-forge (...)" plus a TARGET_KERNEL_CONFIG line to
    # the device BoardConfig on kernels that have one.
    if [ "$st" = "M" ] && git -C "$d" diff -- "$path" 2>/dev/null | grep -q '^+.*rom-forge'; then
      continue
    fi
    hits="$hits$st $full"$'\n'
  done <<< "$dirty"

  if [ -n "$hits" ]; then
    echo
    echo "!! $proj: uncommitted changes forge did not make"
    printf '%s' "$hits" | sed 's/^/     /'
    UNEXPLAINED=$((UNEXPLAINED + $(printf '%s' "$hits" | grep -c .)))
  fi
done

echo
if [ "$UNEXPLAINED" -eq 0 ]; then
  echo ">> every dirty file in a patched project is accounted for"
  exit 0
fi
echo ">> $UNEXPLAINED unexplained change(s)"
echo "   These will NOT become patches and the next force-sync destroys them. If the work is wanted,"
echo "   commit it in the project and run refresh-patches.sh. If it is not, discard it, so the next"
echo "   person does not have to work out which of these was deliberate."
exit 1
