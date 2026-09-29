#!/usr/bin/env bash
# abi-gap.sh — list the symbols a prebuilt blob imports that the running platform no longer
# provides. This is the first question to ask when a vendor binary from an older release fails to
# load, or loads and then dies somewhere unrelated.
#
#   abi-gap.sh <blob> [-s SERIAL] [--keep DIR]
#
#   abi-gap.sh /vendor/lib64/libimsmedia_jni.so        # pull from the device, analyse
#   abi-gap.sh ./libfoo.so                             # analyse a local copy
#
# A device path is pulled; a local path is used as-is. Either way the platform side comes off the
# connected device, because that is the only authoritative answer to "what does this ROM export".
#
# Needs: adb, readelf (binutils), and optionally c++filt for demangling. APEX paths are searched
# too: on modern Android libnativehelper and friends moved out of /system/lib*, and missing them
# makes every JNI symbol look unresolved.
#
# WHAT IT WILL NOT TELL YOU, and what has bitten this project twice:
#
#   1. A symbol that still RESOLVES can still be wrong. nanopb kept every pb_* symbol across
#      0.2.8 -> 0.3.x and changed the meaning of the descriptor bytes underneath them. Same name,
#      same signature, different semantics. abi-gap.sh reports nothing and everything is broken.
#
#   2. A type that still EXISTS can have grown. If the blob does `new Foo(...)` it baked
#      sizeof(Foo) into an immediate at compile time; a shim that constructs today's larger Foo in
#      that allocation overruns the heap, and the damage surfaces somewhere else entirely. Measured
#      on ether: android::Surface went 3560 -> 8168 bytes between 7.1 and 13. Before shimming any
#      constructor, disassemble both sides and compare the size passed to operator new:
#
#         llvm-objdump -d blob.so | grep -B8 '_ZN.*FooC1'      # look for mov x0/w0, #N ; bl _Znwm
#         llvm-objdump -d /path/to/platform-lib.so | grep -B8 '_ZN.*FooC1'
#
#      If they differ, patch the blob's immediate before shimming, or do not shim at all.
#
# So: an empty report means "no missing symbols", NOT "this blob will work".
set -u

BLOB=""; SERIAL=(); KEEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s)     SERIAL=(-s "$2"); shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)      BLOB="$1"; shift ;;
  esac
done
[ -n "$BLOB" ] || { echo "usage: abi-gap.sh <blob> [-s SERIAL] [--keep DIR]" >&2; exit 1; }

ADB="${ADB:-adb}"
command -v readelf >/dev/null || { echo "!! readelf not found" >&2; exit 1; }

W="${KEEP:-$(mktemp -d "${TMPDIR:-.}/abi-gap.XXXXXX")}"
mkdir -p "$W/plat" || exit 1
[ -n "$KEEP" ] || trap 'rm -rf "$W"' EXIT

# Locale matters: comm(1) silently misreports on unsorted input, and sort order is locale
# dependent. Getting this wrong produces a confident, wrong answer.
export LC_ALL=C

# Extract symbol names from `readelf --dyn-syms -W` output. Two traps, both of which silently
# produce a confident wrong answer if you index fixed columns:
#   * an IFUNC's type prints as "<OS specific>: 10" -- two tokens where every other symbol has one,
#     shifting Ndx and Name right. bionic exports strcmp/strncmp this way.
#   * a versioned symbol has a trailing version index, e.g. "UND __cxa_atexit@LIBC (2)", so the
#     last field is "(2)" and not the name.
# So: drop any trailing "(N)", take the final token, strip "@VERSION", and decide UND by whether
# " UND " appears as its own field.
sym_names() {
  awk -v want="$1" '
    /^ *[0-9]+:/ {
      line = $0
      sub(/[ \t]*\([0-9]+\)[ \t]*$/, "", line)
      n = line
      sub(/.*[ \t]/, "", n)
      sub(/@.*/, "", n)
      if (n == "" || n == "UND") next
      isund = (line ~ / UND /)
      if ((want == "UND" && isund) || (want == "DEF" && !isund)) print n
    }'
}

case "$BLOB" in
  /*) LOCAL="$W/$(basename "$BLOB")"
      "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" pull "$BLOB" "$LOCAL" >/dev/null 2>&1 \
        || { echo "!! could not pull $BLOB from the device" >&2; exit 1; }
      echo ">> pulled $BLOB" ;;
  *)  LOCAL="$BLOB"
      [ -f "$LOCAL" ] || { echo "!! no such file: $LOCAL" >&2; exit 1; } ;;
esac

# 64- or 32-bit decides which platform directories to search.
case "$(readelf -h "$LOCAL" 2>/dev/null | awk '/Class:/{print $2}')" in
  ELF64) LIBDIRS="/system/lib64 /system/vendor/lib64 /vendor/lib64 /system/lib64/vndk-sp
                  /apex/com.android.art/lib64 /apex/com.android.runtime/lib64
                  /apex/com.android.os.statsd/lib64 /apex/com.android.vndk.current/lib64" ;;
  ELF32) LIBDIRS="/system/lib /system/vendor/lib /vendor/lib /system/lib/vndk-sp
                  /apex/com.android.art/lib /apex/com.android.runtime/lib
                  /apex/com.android.os.statsd/lib /apex/com.android.vndk.current/lib" ;;
  *) echo "!! not an ELF file: $LOCAL" >&2; exit 1 ;;
esac

# The blob's own DT_NEEDED, plus the libraries every binary ends up resolving against. A missing
# entry here shows up as a false "missing symbol", which is how you end up blaming the wrong thing.
NEEDED=$(readelf -d "$LOCAL" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
CORE="libc.so libm.so libdl.so liblog.so libc++.so libutils.so libcutils.so libbinder.so libnativehelper.so"

echo ">> resolving platform exports"
for lib in $NEEDED $CORE; do
  [ -f "$W/plat/$lib" ] && continue
  for d in $LIBDIRS; do
    if "$ADB" "${SERIAL[@]+"${SERIAL[@]}"}" pull "$d/$lib" "$W/plat/$lib" >/dev/null 2>&1; then break; fi
  done
done
found=$(ls "$W/plat" 2>/dev/null | wc -l)
echo "   $found platform libs available"
for lib in $NEEDED; do
  [ -f "$W/plat/$lib" ] || echo "   !! DT_NEEDED not found on device: $lib"
done

# Parse by line shape, not column index. readelf prints an IFUNC's type as "<OS specific>: 10",
# two tokens where every other symbol has one, which shifts Ndx and Name right by one. Indexing $7/$8
# then reports bionic's strcmp/strncmp as missing -- a false positive that sends you chasing a libc
# gap that does not exist. The name is always the last field; "UND" is always its own field.
readelf --dyn-syms -W "$LOCAL" 2>/dev/null | sym_names UND | sort -u > "$W/und.txt"
: > "$W/have.txt"
for f in "$W"/plat/*; do
  readelf --dyn-syms -W "$f" 2>/dev/null | sym_names DEF >> "$W/have.txt"
done
sort -u "$W/have.txt" -o "$W/have.txt"
comm -23 "$W/und.txt" "$W/have.txt" > "$W/missing.txt"

n_und=$(wc -l < "$W/und.txt"); n_missing=$(wc -l < "$W/missing.txt")
echo ">> $(basename "$LOCAL"): imports $n_und symbols, $n_missing unresolved"
if [ "$n_missing" -gt 0 ]; then
  echo
  while read -r s; do
    if command -v c++filt >/dev/null; then
      printf '   %s\n       %s\n' "$s" "$(c++filt "$s")"
    else
      printf '   %s\n' "$s"
    fi
  done < "$W/missing.txt"
  echo
  echo "   Read the header of this script before shimming any of these: a resolvable symbol can"
  echo "   still be semantically wrong, and a constructor whose type has grown will corrupt the heap."
fi
[ -n "$KEEP" ] && echo ">> artefacts kept in $W"
exit 0
