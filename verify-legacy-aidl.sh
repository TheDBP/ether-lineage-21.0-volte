#!/usr/bin/env bash
# verify-legacy-aidl.sh — prove the generated legacy AIDL is wire-compatible with stock's 7.1 binary.
#
#   verify-legacy-aidl.sh <deodex-workdir> <built-ImsBridge.apk>
#
# The generated interfaces talk to compiled 2016 code that cannot be recompiled to agree with us, so
# a wrong transaction code or descriptor is a silent, hardware-only failure. Compare what our built
# apk actually contains against what the stock binary declares -- not the .aidl source, which is one
# generation step removed from the bytes that ship.
set -u
W="${1:?usage: verify-legacy-aidl.sh <deodex-workdir> <ImsBridge.apk>}"
APK="${2:?usage: verify-legacy-aidl.sh <deodex-workdir> <ImsBridge.apk>}"
BK="${BAKSMALI:-build_output/src/prebuilts/extract-tools/common/smali/baksmali.jar}"
[ -f "$BK" ] || { echo "!! baksmali not found: $BK" >&2; exit 1; }
[ -f "$APK" ] || { echo "!! no such apk: $APK" >&2; exit 1; }

T="${TMPDIR:-build_output/tmp}/aidlverify.$$"; mkdir -p "$T" || exit 1
trap 'rm -rf "$T"' EXIT
unzip -q -o -j "$APK" classes.dex -d "$T" || exit 1
java -jar "$BK" d "$T/classes.dex" -o "$T/ours" 2>/dev/null || exit 1

codes() {  # <stub-smali> -> "name code" lines, sorted by code
  grep -oE 'TRANSACTION_[A-Za-z0-9_]+:I = 0x[0-9a-f]+' "$1" 2>/dev/null \
    | sed 's/TRANSACTION_//;s/:I = /|/' \
    | awk -F'|' '{printf "%d %s\n", strtonum($2), $1}' | sort -n
}

rc=0; n=0
for stub in "$W"/legacy/framework2/com/android/ims/internal/*\$Stub.smali \
            "$W"/legacy/framework2/com/android/ims/*\$Stub.smali; do
  [ -f "$stub" ] || continue
  iface=$(basename "$stub" '$Stub.smali')
  sub=internal; case "$stub" in */ims/"$iface"'$Stub.smali') sub="" ;; esac
  ours="$T/ours/org/codeaurora/ims/legacy${sub:+/$sub}/${iface}\$Stub.smali"
  [ -f "$ours" ] || continue          # not every 7.1 interface is one we ship
  n=$((n+1))
  if diff <(codes "$stub") <(codes "$ours") >/dev/null 2>&1; then
    printf "  ok    %-32s %s transactions\n" "$iface" "$(codes "$stub" | wc -l)"
  else
    printf "  MISMATCH %-29s\n" "$iface"; diff <(codes "$stub") <(codes "$ours") | sed 's/^/        /'
    rc=1
  fi
  want="org.codeaurora.ims.legacy${sub:+.$sub}.$iface"
  grep -q "\"$want\"" "$ours" || { echo "        !! descriptor is not $want"; rc=1; }
done
[ "$n" -gt 0 ] || { echo "!! compared nothing -- paths wrong?" >&2; exit 1; }
echo "  compared $n interface(s)"
exit $rc
