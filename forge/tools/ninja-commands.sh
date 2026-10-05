#!/usr/bin/env bash
# ninja-commands.sh — print (or run) the exact compile/link commands for ONE Soong module out of the
# tree's existing ninja graph, so a shim or small cc module can be iterated in seconds without `m`.
# On a 24.0 tree `m <module>` re-runs soong_build's whole analysis first (~30 GB live Go heap -- it
# swap-thrashes or OOMs a 32 GB host, and killing it mid-write leaves build.<product>.ninja EMPTY until
# the next full bootstrap). The commands are already in out/; ninja can replay them for one target.
#
#   ninja-commands.sh <module|target-path> [--run] [--variant SUBSTR] [-C <tree/src>]
#     ninja-commands.sh libimscompat --variant android_arm_armv8-a_shared          # print
#     ninja-commands.sh libimscompat --variant android_arm_armv8-a_shared --run    # build it
#     ninja-commands.sh out/soong/.intermediates/.../libfoo.so --run                # explicit target
#
# A bare module name is resolved to out/soong/.intermediates/**/<module>/<variant>/<module>{.so,.apk,}
# (lists the candidates if several match; narrow with --variant). The product comes from
# out/combined-<product>.ninja. --run executes the commands from the tree root with out/.path first in
# PATH, like ninja would. The result lands in the module's .intermediates dir (unstripped + stripped
# variants are separate targets: for the installable file target the <module>_stripped dir or the
# out/target/product/<dev>/system/... path). Push it with adb for the iteration; the final build
# must still come from the standard bootstrap.
#
# Needs a NON-EMPTY out/soong/build.<product>.ninja (soong finished at least once).
set -uo pipefail
TGT=""; RUN=0; VAR=""; SRC="${BUILD_ROOT:+$BUILD_ROOT/src}"; SRC="${SRC:-$PWD}"
while [ $# -gt 0 ]; do case "$1" in
  --run) RUN=1; shift;; --variant) VAR="$2"; shift 2;; -C) SRC="$2"; shift 2;;
  -*) echo "!! unknown arg $1" >&2; exit 2;; *) TGT="$1"; shift;; esac; done
[ -n "$TGT" ] || { sed -n '2,20p' "$0"; exit 2; }
cd "$SRC" || exit 1
COMB=$(ls out/combined-*.ninja 2>/dev/null | head -1); [ -n "$COMB" ] || { echo "!! no out/combined-<product>.ninja under $SRC (set -C / BUILD_ROOT)" >&2; exit 1; }
P=${COMB#out/combined-}; P=${P%.ninja}
[ -s "out/soong/build.$P.ninja" ] || { echo "!! out/soong/build.$P.ninja is empty/missing -- soong_build never finished (or was killed mid-write); run the standard bootstrap once" >&2; exit 1; }
NINJA=prebuilts/build-tools/linux-x86/bin/ninja; [ -x "$NINJA" ] || NINJA=$(command -v ninja) || { echo "!! no ninja" >&2; exit 1; }
if [[ "$TGT" != */* ]]; then
  mapfile -t C < <(find out/soong/.intermediates -path "*/$TGT/*$VAR*" \( -name "$TGT.so" -o -name "$TGT.apk" -o -name "$TGT" -o -name "$TGT.jar" \) -type f 2>/dev/null | grep -v '/unstripped/' | sort)
  [ ${#C[@]} -gt 0 ] || { echo "!! no built output for module $TGT under out/soong/.intermediates (never built? try the target path)" >&2; exit 1; }
  if [ ${#C[@]} -gt 1 ]; then echo "!! several variants, pick one with --variant:" >&2; printf '   %s\n' "${C[@]}" >&2; exit 1; fi
  TGT="${C[0]}"
fi
echo ">> target $TGT (product $P)" >&2
CMDS=$("$NINJA" -f "$COMB" -t commands "$TGT") || exit 1
if [ "$RUN" = 1 ]; then
  echo ">> running $(printf '%s\n' "$CMDS" | wc -l) commands" >&2
  PATH="$PWD/out/.path:$PATH" bash -e <<<"$CMDS" && echo ">> built $TGT" >&2
else
  printf '%s\n' "$CMDS"
fi
