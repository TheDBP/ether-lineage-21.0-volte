#!/usr/bin/env bash
# deodex-app.sh — rebuild a dex-stripped stock app into editable smali, and report what framework
# surface it needs. See VOLTE-BRINGUP.md.
#
#   deodex-app.sh <stock-rom.zip> <workdir> <ims|cne>
#
# ether ships both apps we need with the dex removed: a few KB of manifest with the real code in an
# arm64 odex beside it. Importing either apk alone installs a shell with no code.
#
#   ims  vendor/app/ims/ims.apk              27 KB apk, 2.3 MB odex  -> VoLTE
#   cne  priv-app/CNEService/CNEService.apk  4.6 KB apk, 1.1 MB odex -> Wi-Fi calling
#
# The two CNE framework jars (com.quicinc.cne.jar, cneapiclient.jar) still carry their own
# classes.dex, so they need no work -- ship them as they are.
#
# Needs a JDK and the baksmali/smali jars the Android tree already carries at
# prebuilts/extract-tools/common/smali/. Point SMALI_DIR elsewhere to override.
set -u

ZIP="${1:?usage: deodex-app.sh <stock-rom.zip> <workdir> <ims|cne>}"
W="${2:?usage: deodex-app.sh <stock-rom.zip> <workdir> <ims|cne>}"
T="${3:?usage: deodex-app.sh <stock-rom.zip> <workdir> <ims|cne>}"
# baksmali/smali come from the Android tree. Look where the tree actually is -- this runs both from
# the host (tree under build_output/src) and from inside the container (tree at /aosp, cwd /aosp).
if [ -z "${SMALI_DIR:-}" ]; then
  for _c in build_output/src/prebuilts/extract-tools/common/smali \
            prebuilts/extract-tools/common/smali \
            /aosp/prebuilts/extract-tools/common/smali; do
    [ -f "$_c/baksmali.jar" ] && SMALI_DIR="$_c" && break
  done
fi
SMALI_DIR="${SMALI_DIR:-build_output/src/prebuilts/extract-tools/common/smali}"
[ -f "$ZIP" ] || { echo "!! no such zip: $ZIP" >&2; exit 1; }
BK="$SMALI_DIR/baksmali.jar"; SM="$SMALI_DIR/smali.jar"
for j in "$BK" "$SM"; do [ -f "$j" ] || { echo "!! missing $j (set SMALI_DIR)" >&2; exit 1; }; done

case "$T" in
  ims) APK=system/vendor/app/ims/ims.apk;             ODEX=system/vendor/app/ims/oat/arm64/ims.odex
       SURFACE='Lcom/android/ims[^;]*;';              OWN=org/codeaurora/ims ;;
  cne) APK=system/priv-app/CNEService/CNEService.apk; ODEX=system/priv-app/CNEService/oat/arm64/CNEService.odex
       SURFACE='Lcom/android/internal[^;]*;';         OWN=com/quicinc/cne ;;
  *)   echo "!! target must be ims or cne" >&2; exit 1 ;;
esac

mkdir -p "$W/in" || exit 1
echo ">> extracting $(basename "$APK") + odex"
unzip -o -j -q "$ZIP" "$APK" "$ODEX" -d "$W/in" || exit 1

# The odex is an ART OAT: its instructions are resolved against the boot image it was compiled
# against, so baksmali needs that same boot classpath to turn them back into portable smali.
echo ">> extracting the arm64 boot classpath"
unzip -o -q "$ZIP" 'system/framework/arm64/*' -d "$W" || exit 1

echo ">> deodexing"
java -jar "$BK" x -d "$W/system/framework/arm64" "$W/in/$(basename "$ODEX")" -o "$W/smali" 2>/dev/null || exit 1
echo "   $(find "$W/smali" -name '*.smali' | wc -l) smali files, $(find "$W/smali/$OWN" -name '*.smali' 2>/dev/null | wc -l) under $OWN"

# A partial deodex is the dangerous outcome: it still assembles and installs, and only fails at
# runtime. baksmali leaves quick opcodes in place when it cannot resolve them, so check.
echo ">> checking the deodex is complete"
q=$(grep -rhoE '\b(execute-inline|invoke-virtual-quick|invoke-super-quick|i(get|put)(-object|-wide)?-quick)\b' "$W/smali" 2>/dev/null | wc -l)
u=$(grep -rl 'unresolvable\|Unable to resolve' "$W/smali" 2>/dev/null | wc -l)
echo "   leftover odex opcodes: $q    files with unresolved refs: $u"
[ "$q" -eq 0 ] && [ "$u" -eq 0 ] || { echo "!! incomplete deodex -- do not ship this" >&2; exit 1; }

echo ">> round-trip check (smali must reassemble before any edits)"
java -jar "$SM" a "$W/smali" -o "$W/classes-roundtrip.dex" 2>/dev/null || { echo "!! reassembly failed" >&2; exit 1; }
echo "   reassembled, $(java -jar "$BK" list classes "$W/classes-roundtrip.dex" 2>/dev/null | wc -l) classes"

echo ">> framework surface this app expects"
grep -rhoE "$SURFACE" "$W/smali" 2>/dev/null | sed 's/^L//;s/;$//' | sed 's/\$.*//' | LC_ALL=C sort -u > "$W/surface.txt"
echo "   $(wc -l < "$W/surface.txt") distinct types -> $W/surface.txt"

[ "$T" = "cne" ] && { echo ">> cne needs no legacy library: every type it uses still exists on 13"; exit 0; }

# ims only. Its surface is com.android.ims, which Android 9 deleted, so step 2 has to rebuild it.
# Take those classes from the device's own 7.1 boot image rather than an AOSP checkout: exact
# signature match by construction, and nothing to fetch. They span two jars, and the second has a
# trap -- `baksmali x <oat>` disassembles only the FIRST dex of a multi-dex oat and says nothing
# about the rest, so asking boot-framework.oat for com/android/ims returns zero and reads exactly
# like proof the classes are absent. Address the entry by the name `baksmali list dex` prints,
# appended to the oat path as if the oat were a directory.
echo ">> recovering the 7.1 framework classes from the boot image"
java -jar "$BK" x -d "$W/system/framework/arm64" "$W/system/framework/arm64/boot-ims-common.oat" \
     -o "$W/legacy/ims-common" 2>/dev/null || exit 1
java -jar "$BK" x -d "$W/system/framework/arm64" \
     "$W/system/framework/arm64/boot-framework.oat//system/framework/framework.jar:classes2.dex" \
     -o "$W/legacy/framework2" 2>/dev/null || exit 1
echo "   ims-common: $(find "$W/legacy/ims-common" -name '*.smali' | wc -l) classes"
echo "   framework classes2: $(find "$W/legacy/framework2" -name '*.smali' | wc -l) classes"

echo ">> confirming every referenced type is recoverable"
{ find "$W/legacy/ims-common" -name '*.smali' | sed "s#^$W/legacy/ims-common/##"
  find "$W/legacy/framework2" -name '*.smali' | sed "s#^$W/legacy/framework2/##"; } \
  | sed 's/\.smali$//' | sed 's/\$.*//' | LC_ALL=C sort -u > "$W/have.txt"
miss=$(LC_ALL=C comm -23 "$W/surface.txt" "$W/have.txt")
if [ -n "$miss" ]; then echo "!! not recoverable from the boot image:"; echo "$miss" | sed 's/^/   /'; exit 1; fi
echo "   all $(wc -l < "$W/surface.txt") types present"
