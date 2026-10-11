#!/bin/bash
# unpack-lg-kdz.sh -- get a partition image out of an LG KDZ, so a stock firmware container can be
# handed to a build directly instead of being unpacked by hand first.
#
#   unpack-lg-kdz.sh <firmware.kdz> <work-dir> [partition]        (partition default: system)
#
# Prints the path of the extracted image on stdout. Everything else goes to stderr, so the caller can
# capture the path.
#
# LG ships firmware as a KDZ, which holds a DZ, which holds the partition images. Nothing in AOSP
# reads either, so this drives kdztools (unkdz, then undz).
#
# kdztools is GPL-3.0 and this tree is Apache-2.0, so it is fetched rather than vendored: keeping it
# out of the repo keeps the licence of the repo simple. Point KDZTOOLS at a local checkout to skip
# the fetch, which is also how a build with no network uses it.
#
# Idempotent: an already-extracted image is reused, because unpacking a 3 GB container is minutes and
# the result never changes for a given KDZ.
set -o pipefail

KDZ="${1:?usage: unpack-lg-kdz.sh <firmware.kdz> <work-dir> [partition]}"
WORK="${2:?usage: unpack-lg-kdz.sh <firmware.kdz> <work-dir> [partition]}"
PART="${3:-system}"
# Pinned to the commit the extraction was actually validated against, not to a branch.
KDZTOOLS_REF="${KDZTOOLS_REF:-4eaa7f7}"

[ -f "$KDZ" ] || { echo "!! no such KDZ: $KDZ" >&2; exit 1; }
command -v python3 >/dev/null || { echo "!! python3 not found; kdztools is Python" >&2; exit 1; }

mkdir -p "$WORK" || exit 1
OUT="$WORK/$PART.image"
if [ -s "$OUT" ]; then
  echo ">> kdz: $PART.image already extracted, reusing it" >&2
  echo "$OUT"; exit 0
fi

# 1. kdztools itself
TOOLS="${KDZTOOLS:-}"
if [ -z "$TOOLS" ]; then
  TOOLS="$WORK/kdztools"
  if [ ! -x "$TOOLS/unkdz.py" ] && [ ! -f "$TOOLS/unkdz.py" ]; then
    echo ">> kdz: fetching kdztools ($KDZTOOLS_REF)" >&2
    TB="$WORK/kdztools.tar.gz"
    curl -fsSL -o "$TB" "https://github.com/ehem/kdztools/archive/$KDZTOOLS_REF.tar.gz" \
      || { echo "!! could not fetch kdztools; set KDZTOOLS to a local checkout" >&2; exit 1; }
    rm -rf "$TOOLS"; mkdir -p "$TOOLS"
    tar -xzf "$TB" -C "$TOOLS" --strip-components=1 || exit 1
    rm -f "$TB"
  fi
fi
[ -f "$TOOLS/unkdz.py" ] || { echo "!! $TOOLS does not look like kdztools (no unkdz.py)" >&2; exit 1; }

# 2. KDZ -> DZ. The KDZ holds the DZ plus a few small vendor DLLs; -x takes the lot, which is
# simpler and more robust than selecting by the numeric id that -s wants.
echo ">> kdz: unpacking $(basename "$KDZ") (gigabytes, minutes)" >&2
python3 "$TOOLS/unkdz.py" -f "$KDZ" -x -d "$WORK/kdz" >&2 || {
  echo "!! unkdz failed on $KDZ" >&2; exit 1; }
DZ="$(find "$WORK/kdz" -maxdepth 2 -iname '*.dz' -print -quit 2>/dev/null)"
[ -n "$DZ" ] || { echo "!! unkdz produced no .dz under $WORK/kdz" >&2; exit 1; }

# 3. DZ -> the wanted partition, as <slice-name>.image.
#
# -s and not -x: -x writes the chunk files a reconstruction needs, not the partitions. And -s must
# be given a slice INDEX, not a name, so the index is read out of the listing. Extracting every
# slice instead would be simpler and is not an option: userdata alone unpacks to 55 GB on this
# device, against about 3 GB for system.
#
# Listing format is `<slice>/<chunk> : <name>_<n>.bin (<size> bytes)`, with `<name> (<empty>)` for
# slices carrying nothing. awk reads the whole listing rather than stopping at the first match, so
# nothing upstream is ever handed a SIGPIPE.
echo ">> kdz: locating the $PART slice in $(basename "$DZ")" >&2
IDX="$(python3 "$TOOLS/undz.py" -f "$DZ" -l 2>/dev/null | awk -v p="$PART" '
  /^[[:space:]]*[0-9]+\// {
    split($0, a, "/"); idx = a[1] + 0
    if (match($0, /:[[:space:]]*[^ ]+/)) {
      nm = substr($0, RSTART, RLENGTH); sub(/^:[[:space:]]*/, "", nm)
      sub(/_[0-9]+\.bin$/, "", nm); sub(/\.bin$/, "", nm)
      if (nm == p && !found) { print idx; found = 1 }
    }
  }')"
[ -n "$IDX" ] || { echo "!! no slice named '$PART' in $(basename "$DZ")" >&2
                   echo "!! list it with: python3 undz.py -f '$DZ' -l" >&2; exit 1; }
echo ">> kdz: extracting slice $IDX ($PART)" >&2
python3 "$TOOLS/undz.py" -f "$DZ" -s "$IDX" -d "$WORK/parts" >&2 || {
  echo "!! undz failed extracting slice $IDX from $DZ" >&2; exit 1; }

# undz names the output per partition; take the largest match so a chunked partition does not win
# over the assembled one.
# awk prints the first line without exiting early: `head -1` would SIGPIPE sort under pipefail.
SRC="$(find "$WORK" -name "${PART}*.image" -printf '%s\t%p\n' 2>/dev/null | sort -rn | awk -F'\t' 'NR==1{print $2}')"
[ -n "$SRC" ] || { echo "!! no ${PART}*.image came out of $DZ" >&2; exit 1; }
[ "$SRC" = "$OUT" ] || mv -f "$SRC" "$OUT"
echo ">> kdz: $PART -> $OUT ($(stat -c %s "$OUT") bytes)" >&2
echo "$OUT"
