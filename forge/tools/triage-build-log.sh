#!/usr/bin/env bash
# triage-build-log.sh — collapse a `mka -k` build log into distinct failure CLASSES.
#
#   ./tools/triage-build-log.sh <build.log> [--targets]
#
# Build with `mka -k` (keep going) rather than stopping at the first error, then run this. A wall of
# failures is nearly always a handful of causes: the first lineage-19.1 ether run reported 274 failed
# edges that turned out to be two fixes, 270 of them a single missing BoardConfig flag. Reading that
# log top-to-bottom, or fixing one error per build cycle, wastes hours.
#
#   --targets   also list the failing ninja targets per class (default: counts + one example each)
#
# Exit status is the number of distinct classes (0 = clean build), so it is usable in a loop.
set -uo pipefail
export LC_ALL=C
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

LOG="${1:?usage: triage-build-log.sh <build.log> [--targets]}"
SHOW_TARGETS="${2:-}"
[ -f "$LOG" ] || { echo "!! no such log: $LOG" >&2; exit 255; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

n_failed=$(grep -c '^FAILED: ' "$LOG" 2>/dev/null || true); n_failed=${n_failed:-0}
# The real completion marker. Do NOT grep for a marker that also appears in the echoed command line
# the runner logs -- that yields a false "finished" while the build is still in Soong analysis.
done_line=$(grep -aoE '^MKA_RESULT=[0-9]+|ninja: build stopped[^\n]*' "$LOG" 2>/dev/null | tail -1)
progress=$(grep -aoE '^\[ *[0-9]+% [0-9]+/[0-9]+' "$LOG" 2>/dev/null | tail -1)

echo "=== $LOG"
[ -n "$progress" ]  && echo "    last progress : ${progress#[}"
[ -n "$done_line" ] && echo "    completion    : $done_line"
echo "    failed edges  : $n_failed"

if [ "$n_failed" -eq 0 ]; then
  echo "    no FAILED edges."
  exit 0
fi

# Normalise each error line into a signature: strip line numbers, hex, hashes and paths so that the
# same defect repeated across 270 files collapses to one row.
# The SIGNATURE is the diagnostic text only. Everything before "error:" is the file that happened to
# trip it, and keeping it would report one "class" per file -- which is precisely the wall of noise
# this tool exists to collapse.
grep -ahE '(^|[[:space:]])(error|ERROR|Error):|^ld\.[a-z]+: error|^libsepol|neverallow|ninja: error' "$LOG" 2>/dev/null \
  | sed -E 's/.*[Ee]rror:[[:space:]]*//' \
  | sed -E 's/.*(libsepol[^:]*:)/\1/' \
  | sed -E 's/[0-9]+/N/g; s#(/[A-Za-z0-9_.+-]+)+/[A-Za-z0-9_.+-]+#<path>#g; s/0x[0-9a-fA-FN]+/<hex>/g' \
  | sed -E "s/'[^']*'/'X'/g" \
  | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | grep -v '^$' \
  | sort | uniq -c | sort -rn > "$TMP/classes.txt"

echo
echo "    failure classes (count  signature):"
head -20 "$TMP/classes.txt" | while read -r c sig; do
  printf "    %6s  %s\n" "$c" "$(echo "$sig" | cut -c1-118)"
done

n_classes=$(wc -l < "$TMP/classes.txt")
echo
echo "    $n_classes distinct signatures across $n_failed failed edges."

if [ "$SHOW_TARGETS" = "--targets" ]; then
  echo
  echo "    failing targets:"
  grep -ah '^FAILED: ' "$LOG" | sed 's/^FAILED: //' | sort -u | head -40 | sed 's/^/      /'
fi

# Point at the usual one-line fixes when their fingerprints show up.
echo
grep -q 'found ELF prebuilt in PRODUCT_COPY_FILES' "$LOG" 2>/dev/null && \
  echo "    hint: ELF prebuilts -> BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true (BoardConfig)"
grep -q 'duplicate symbol: yylloc' "$LOG" 2>/dev/null && \
  echo "    hint: yylloc -> host tools need -fcommon; HOSTCFLAGS is set on the kernel make COMMAND"
grep -q 'duplicate symbol: yylloc' "$LOG" 2>/dev/null && \
  echo "          LINE by BoardConfigKernel.mk, so restate it via TARGET_KERNEL_ADDITIONAL_FLAGS."
grep -q 'unexpected token at start of statement' "$LOG" 2>/dev/null && \
  echo "    hint: asm-offsets -> pre-4.x kernel vs clang; TARGET_KERNEL_CLANG_COMPILE := false"
grep -q "unknown type" "$LOG" 2>/dev/null && \
  echo "    hint: unknown sepolicy type -> tools/find-orphaned-sepolicy-types.sh (checkpolicy reports"
grep -q "unknown type" "$LOG" 2>/dev/null && \
  echo "          only the FIRST one per run, so do not chase them one build at a time)"
grep -q 'neverallow' "$LOG" 2>/dev/null && \
  echo "    hint: neverallow -> imported vendor policy grants a type AOSP forbids; check whether"
grep -q 'neverallow' "$LOG" 2>/dev/null && \
  echo "          BOARD_SEPOLICY_M4DEFS renames it to vendor_* for supported SoCs but not yours"
grep -q 'mismatch in the <uses-library> tags' "$LOG" 2>/dev/null && \
  echo "    hint: uses-library -> add LOCAL_OPTIONAL_USES_LIBRARIES to the prebuilt module"
grep -q 'does not exist.  Stop.' "$LOG" 2>/dev/null && \
  echo "    hint: 'output directory does not exist' -> sbox deleted genDir; mkdir -p it, absolute"

exit "$n_classes"
