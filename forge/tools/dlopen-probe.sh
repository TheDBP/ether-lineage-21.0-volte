#!/usr/bin/env bash
# dlopen-probe.sh -- find out, empirically, whether a prebuilt .so actually LOADS on the running
# device: dlopen it and its whole DT_NEEDED closure, running the init-array too. This is the ground
# truth that `abi-gap.sh` only estimates -- it catches missing transitive libs, the real symbol gaps
# in load order, and constructors that crash.
#
#   dlopen-probe.sh <blob.so> [--supply DIR] [--stub LIB ...] [--preload LIB ...]
#                   [--ldpath P] [--arch 32|64] [-s SERIAL] [--keep]
#
#   --supply DIR   when the loader reports "library X not found", copy X from DIR (a stock
#                  /system/lib or /vendor/lib extract) and retry -- walks the closure automatically
#   --stub LIB     generate an empty .so with that soname instead of supplying it (for an
#                  over-link or a subsystem you are deliberately cutting out, e.g. video codecs);
#                  repeatable
#   --preload LIB  dlopen this first with the global flag (your hand-written shim lib providing
#                  symbols the platform dropped); repeatable. On 32-bit bionic RTLD_GLOBAL=0x2 and
#                  the global-group route is flaky, so preloads go in via the harness's own dlopen
#   --ldpath P     extra LD_LIBRARY_PATH dirs (the staging dir and /system/lib:/vendor/lib are added)
#   --arch 32|64   blob architecture (default: read from the ELF)
#
# It builds a tiny PIE harness once (cached under the work dir) with the ROM tree's clang, linked
# against the DEVICE's own libc/libdl (their dynamic symbol table is all lld needs; the binding is
# on-device). Run it from `adb shell` -- shell UID uses the default linker namespace, which can reach
# /system/lib and your staging dir, so it isolates the ABI/closure question from the app-namespace
# packaging question (an app classloader namespace can't reach libgui/libbinder et al; that is a
# separate ld.config.txt/sepolicy problem solved after this proves the binaries are compatible).
#
# Reads BUILD_ROOT (default: two levels up from the forge) for the clang + bionic CRT objects. The
# blob and any stock extracts are OEM-proprietary: keep the work dir in .scratch, never a repo.
#
# A clean "OK ... loaded" means the closure resolves and no constructor faulted -- NOT that the lib
# works (see abi-gap.sh's header on semantic drift and grown types). Empty/`--stub` libs and stub
# symbols satisfy the loader but crash if actually called.
set -uo pipefail
BLOB=""; SUPPLY=""; LDPATH=""; ARCH=""; SER=(); KEEP=0; STUBS=(); PRELOADS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --supply) SUPPLY="$2"; shift 2 ;;
    --stub) STUBS+=("$2"); shift 2 ;;
    --preload) PRELOADS+=("$2"); shift 2 ;;
    --ldpath) LDPATH="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    -s) SER=(-s "$2"); shift 2 ;;
    --keep) KEEP=1; shift ;;
    -*) echo "!! unknown arg $1" >&2; exit 2 ;;
    *) BLOB="$1"; shift ;;
  esac
done
[ -f "$BLOB" ] || { echo "usage: dlopen-probe.sh <blob.so> [--supply DIR] [--stub LIB] [--preload LIB] [--ldpath P] [-s SERIAL]" >&2; exit 1; }
ADB=("${ADB:-adb}" "${SER[@]+"${SER[@]}"}")
BR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRC="$BR/src"; [ -d "$SRC" ] || SRC="$BR"
[ -z "$ARCH" ] && case "$(readelf -h "$BLOB" 2>/dev/null | awk '/Class:/{print $2}')" in ELF64) ARCH=64 ;; *) ARCH=32 ;; esac
if [ "$ARCH" = 64 ]; then TRIPLE=aarch64-linux-android21; CRTA="android_arm64_armv8-a"; else TRIPLE=armv8a-linux-androideabi21; CRTA="android_arm_armv8-a"; fi

W="${WORKDIR:-$(dirname "$BLOB")/.dlopen-probe}"; mkdir -p "$W/stage" "$W/dev"
CL=$(ls "$SRC"/prebuilts/clang/host/linux-x86/clang-r*/bin/clang 2>/dev/null | tail -1)
[ -x "${CL:-}" ] || { echo "!! clang not found under $SRC/prebuilts/clang (set BUILD_ROOT)" >&2; exit 1; }
cbo(){ ls "$SRC"/out/soong/.intermediates/bionic/libc/"$1"/"$CRTA"/"$1".o 2>/dev/null | head -1; }

# device libc/libdl to link against (their dynsym only)
for l in libc.so libdl.so; do
  [ -f "$W/dev/$l" ] || "${ADB[@]}" pull /apex/com.android.runtime/lib$([ "$ARCH" = 64 ] && echo 64)/bionic/$l "$W/dev/$l" >/dev/null 2>&1 || \
    "${ADB[@]}" pull /system/lib$([ "$ARCH" = 64 ] && echo 64)/$l "$W/dev/$l" >/dev/null 2>&1
  [ -f "$W/dev/$l" ] || { echo "!! could not pull $l from device" >&2; exit 1; }
done

# build the harness once
H="$W/h"
if [ ! -x "$H" ] || [ "$0" -nt "$H" ]; then
  cat > "$W/h.c" <<'EOF'
extern void* dlopen(const char*, int); extern char* dlerror(void); extern int printf(const char*, ...);
int main(int argc, char** argv){
  if(argc<2){printf("usage: h <target.so> [preload-global.so ...]\n");return 2;}
  for(int i=2;i<argc;i++){ dlerror(); if(!dlopen(argv[i], 2)){printf("PRELOAD FAIL %s\n  %s\n",argv[i],dlerror());return 3;} }
  dlerror(); void* h=dlopen(argv[1], 2);
  if(h){printf("OK %s loaded (%p)\n",argv[1],h);return 0;}
  printf("FAIL %s\n  %s\n",argv[1],dlerror()); return 1;
}
EOF
  "$CL" --target=$TRIPLE -fPIE -pie -nostdlib -o "$H" "$(cbo crtbegin_dynamic)" "$W/h.c" "$(cbo crtend_android)" "$W/dev/libc.so" "$W/dev/libdl.so" || { echo "!! harness build failed" >&2; exit 1; }
fi

mkstub(){ # mkstub <soname> -> empty .so in stage
  echo 'static int _s;' > "$W/stub.c"
  "$CL" --target=$TRIPLE -nostdlibinc -fPIC -shared -nostdlib -Wl,-soname,"$1" -o "$W/stage/$1" "$(cbo crtbegin_so)" "$W/stub.c" "$(cbo crtend_so)" "$W/dev/libc.so" 2>/dev/null
}
cp "$BLOB" "$W/stage/"
for s in "${STUBS[@]+"${STUBS[@]}"}"; do mkstub "$s"; echo "  stub $s"; done
for p in "${PRELOADS[@]+"${PRELOADS[@]}"}"; do cp "$p" "$W/stage/"; done

DEVDIR=/data/local/tmp/dlopen-probe
"${ADB[@]}" shell "rm -rf $DEVDIR; mkdir -p $DEVDIR" >/dev/null 2>&1
"${ADB[@]}" push "$H" "$DEVDIR/h" >/dev/null 2>&1; "${ADB[@]}" shell "chmod 755 $DEVDIR/h"
LP="$DEVDIR:/system/lib$([ "$ARCH" = 64 ] && echo 64):/vendor/lib$([ "$ARCH" = 64 ] && echo 64)${LDPATH:+:$LDPATH}"
# Preloads go in via LD_PRELOAD, not the harness's own dlopen: on 32-bit bionic the RTLD_GLOBAL
# global-group route does not reliably expose a preload's symbols to a later dlopen, but LD_PRELOAD
# puts the lib in the global group at process start deterministically.
PRE=""; for p in "${PRELOADS[@]+"${PRELOADS[@]}"}"; do PRE="$PRE$DEVDIR/$(basename "$p") "; done
run(){ "${ADB[@]}" push "$W/stage/." "$DEVDIR/" >/dev/null 2>&1; "${ADB[@]}" shell "LD_PRELOAD=\"$PRE\" LD_LIBRARY_PATH=$LP $DEVDIR/h $DEVDIR/$(basename "$BLOB")" 2>&1 | tr -d '\r'; }

for i in $(seq 1 60); do
  out=$(run)
  if echo "$out" | grep -q "^OK"; then echo "$out"; echo ">> stage: $W/stage"; [ $KEEP = 0 ] && : ; exit 0; fi
  miss=$(echo "$out" | grep -oE 'library "[^"]+" not found' | head -1 | sed 's/library "//;s/" not found//')
  if [ -n "$miss" ]; then
    if [ -n "$SUPPLY" ] && [ -f "$SUPPLY/$miss" ]; then cp "$SUPPLY/$miss" "$W/stage/"; echo "  +supply $miss"; continue
    elif printf '%s\n' "${STUBS[@]+"${STUBS[@]}"}" | grep -qx "$miss"; then continue
    else echo "$out"; echo ">> missing lib '$miss' -- add it with --supply <dir containing it> or --stub $miss"; exit 1; fi
  fi
  # not a missing-lib failure: a symbol gap or constructor crash -- report, human must shim
  echo "$out"; echo ">> not a missing-library failure: author a shim lib exporting the symbol and pass it with --preload (see docs/debugging-volte.md)"; exit 1
done
echo "!! still not loaded after 60 iterations" >&2; exit 1
