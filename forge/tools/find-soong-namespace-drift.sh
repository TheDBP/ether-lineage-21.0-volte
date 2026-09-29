#!/usr/bin/env bash
# find-soong-namespace-drift.sh — Soong namespace and manifest changes between branches that will
# break a device tree the new branch no longer maintains.
#
#   ./tools/find-soong-namespace-drift.sh <OLD_SRC> <NEW_SRC> <DEVICE_PATH> [DEVICE_TREE]
#
#   OLD_SRC      a synced tree on the branch where the device BUILT
#   NEW_SRC      the synced tree for the new branch
#   DEVICE_PATH  e.g. device/google/bonito
#   DEVICE_TREE  the device tree to read (default: NEW_SRC/DEVICE_PATH, else OLD_SRC/DEVICE_PATH).
#                Point it at the OLD copy when the new tree's copy is already patched, or when the
#                new manifest dropped the device and it is not synced yet.
#   EXTRA_TREES  env, space-separated paths relative to NEW_SRC whose Android.bp deps are checked
#                too (check 5). vendor/<brand>/<codename> is added automatically; name sibling
#                devices' blob trees here, e.g. EXTRA_TREES="vendor/google/sargo".
#
# Why this exists: on the bonito 22.2 -> 24.0 port, four of the first five blockers were this
# class and none of the other pre-port tools can see them. Soong resolves a bare module name by
# searching the requesting namespace, its imports, then the root namespace -- and the root
# namespace searches PRODUCT_SOONG_NAMESPACES in order. When upstream wraps a directory in a new
# `soong_namespace {}`, every device that referenced its modules by name and does not import that
# directory silently loses them. The error, when there is one, names the wrong module:
# "module libwifi-hal-qcom is not an defaults module" was the top-level dispatch cc_defaults
# disappearing behind hardware/qcom/wlan's new namespace and the search falling through to the
# cc_library of the same name in hardware/qcom/wlan/legacy.
#
# Four checks, each a comm/diff over both trees, no build needed:
#   1. Directories that GAINED a soong_namespace, which the device does not import, and which
#      define a module the device references. -> add to PRODUCT_SOONG_NAMESPACES (device .mk) and
#      to the `imports:` of the device tree's own soong_namespace (device Android.bp). BOTH: the
#      product list serves PRODUCT_PACKAGES, the imports serve the device's Android.bp deps.
#   2. PRODUCT_SOONG_NAMESPACES entries with no directory in NEW_SRC. -> the manifest dropped a
#      project; pin it in a local manifest (newest branch that exists; often identical to the old).
#   3. Modules the device references that OLD_SRC defined under an imported namespace and NEW_SRC
#      does not. -> upstream deleted source the device still builds against; restore via a patch
#      (git revert of the drop) or drop the feature.
#   4. Namespaces the device imports whose `imports:` changed -- informational.
#   6. Literal tree paths in the device .mk files (includes, DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE,
#      sepolicy dirs, PRODUCT_COPY_FILES sources) that OLD_SRC has and NEW_SRC does not.
#   7. DT_NEEDED of every prebuilt blob (.so and bin/) against the modules NEW_SRC defines.
#   5. Every module name the device tree, its included .mk files and the vendor blob tree
#      reference (PRODUCT_PACKAGES, shared_libs, ...) that NO Android.bp or Android.mk in NEW_SRC
#      defines. Catches deleted HIDL libraries (a blob still links android.frameworks.stats@1.0),
#      dropped helper modules, renamed services. This is the check the build's own
#      "depends on undefined module" would make one at a time, six minutes apiece.
#
# Check 1 also flags SHADOWING: a directory that gained a namespace, that the device does not
# import, that defines a module of the same name as one in a namespace the device DOES import.
# Root-namespace callers (frameworks/, build/) used to reach the top-level module; now the search
# hits the imported one first. That is the libwifi-hal-qcom case: nothing in the device tree
# names it, frameworks/opt/net/wifi does.
#
# Order matters for the fix to (1): list a parent namespace BEFORE a child that defines a module of
# the same name, so the intended module wins the search.
#
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs.
# No -e: this is a diagnostic made of grep pipelines, and grep exits 1 on "no match".
set -uo pipefail
export LC_ALL=C
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

OLD_SRC="${1:?need OLD_SRC}"
NEW_SRC="${2:?need NEW_SRC}"
DEV="${3:?need DEVICE_PATH, e.g. device/google/bonito}"
DEVTREE="${4:-}"
[ -n "$DEVTREE" ] || { [ -d "$NEW_SRC/$DEV" ] && DEVTREE="$NEW_SRC/$DEV" || DEVTREE="$OLD_SRC/$DEV"; }
[ -d "$DEVTREE" ] || { echo "!! no device tree at $DEVTREE" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Where namespaces live. Scanning the whole checkout is slow and nothing under frameworks/ or
# packages/ is namespaced for device reasons.
SUBDIRS="hardware vendor device external system"

ns_dirs() { # $1=tree -> sorted list of dirs whose Android.bp opens a soong_namespace
  local t="$1" d
  for d in $SUBDIRS; do
    [ -d "$t/$d" ] || continue
    grep -rl --include=Android.bp '^soong_namespace' "$t/$d" 2>/dev/null
  done | sed "s#^$t/##; s#/Android.bp\$##" | sort -u
}
module_names() { # $1=tree $2=dir -> module names defined by Android.bp files in that namespace
  # Files under a CHILD namespace belong to the child, not to $2 -- hardware/google/pixel must not
  # be credited with hardware/google/pixel/health's modules or every child looks like a shadow.
  local t="$1" d="$2" nsfile   # expansions in one `local` run before any of its assignments
  case "$t" in "$OLD_SRC") nsfile="$TMP/ns_old.txt";; *) nsfile="$TMP/ns_new.txt";; esac  # a tree-wide grep, computed once below
  find "$t/$d" -name Android.bp -print0 2>/dev/null | tr '\0' '\n' | sed "s#^$t/##" \
    | awk -v root="$d" 'NR==FNR { if ($0 != root && index($0, root "/") == 1) ns[$0]=1; next }
        { f=$0; sub(/\/Android\.bp$/, "", f); keep=1
          for (n in ns) if (f == n || index(f, n "/") == 1) { keep=0; break }
          if (keep) print }' "$nsfile" - \
    | sed "s#^#$t/#" | tr '\n' '\0' | xargs -0 -r grep -hoE '^\s*name:\s*"[^"]+"' 2>/dev/null \
    | sed -E 's/.*"([^"]+)"/\1/' | sort -u
}

# --- what the device imports, and which module names it mentions ---------------------------------
# .mk files the device pulls in from outside its own tree (one level; literal paths only).
{ find "$DEVTREE" -name '*.mk' -print0 | xargs -0 -r grep -hoE '^\s*(-?include|\$\(call inherit-product(-if-exists)?,)\s*[a-z][^ )]*\.mk' \
    | sed -E 's/.*[ ,]//' | { grep -v "^$DEV/" || true; } | while read -r f; do [ -f "$NEW_SRC/$f" ] && echo "$NEW_SRC/$f" || true; done; } \
  2>/dev/null | sort -u > "$TMP/included_mks.txt"
mk_blocks() { # $1=variable name -> the continuation lines of every "$1 +?=" in the device tree + included mks
  local awkprog='$0 ~ "^[ \t]*" v "[ \t]*\\+?=" { on=1 } on { print; if ($0 !~ /\\[ \t]*$/) on=0 }'
  { find "$DEVTREE" -name '*.mk' -print0 | xargs -0 -r awk -v v="$1" "$awkprog";
    if [ -s "$TMP/included_mks.txt" ]; then xargs -r -d '\n' awk -v v="$1" "$awkprog" < "$TMP/included_mks.txt"; fi; } 2>/dev/null \
    | sed -E 's/#.*//; s/^[ \t]*[A-Z_]+[ \t]*\+?=//' | tr ' \t\\' '\n\n\n' | { grep -v '^$' || true; }
}
mk_blocks PRODUCT_SOONG_NAMESPACES | { grep -E '^[a-z].*/' || true; } | sort -u > "$TMP/product_ns.txt"
# Android.bp imports of the device's own namespace(s).
find "$DEVTREE" -name Android.bp -print0 | xargs -0 -r awk '/^soong_namespace/,/^}/' 2>/dev/null \
  | grep -oE '"[^"]+"' | tr -d '"' | sort -u > "$TMP/bp_imports.txt"
# Every identifier the device tree could be naming a module with: PRODUCT_PACKAGES words and quoted
# strings in its Android.bp files. Over-inclusive on purpose; it is only used to filter candidates.
{ grep -rhoE '^\s+[A-Za-z0-9_.@+-]+\s*\\?$' "$DEVTREE" --include='*.mk' | tr -d ' \\' ;
  mk_blocks PRODUCT_PACKAGES ;
  find "$DEVTREE" -name Android.bp -print0 | xargs -0 -r grep -hoE '"[A-Za-z0-9_.@+-]+"' | tr -d '"' ; } \
  2>/dev/null | sed -E 's/:(32|64)$//' | sort -u > "$TMP/dev_refs.txt"

echo "=== Soong namespace drift for $DEV (device tree read from $DEVTREE)"
echo "    device imports: $(wc -l < "$TMP/product_ns.txt") PRODUCT_SOONG_NAMESPACES, $(wc -l < "$TMP/bp_imports.txt") Android.bp imports; $(wc -l < "$TMP/included_mks.txt") outside .mk files followed"

# --- 1. newly namespaced directories the device depends on but does not import --------------------
ns_dirs "$OLD_SRC" > "$TMP/ns_old.txt"
ns_dirs "$NEW_SRC" > "$TMP/ns_new.txt"
comm -13 "$TMP/ns_old.txt" "$TMP/ns_new.txt" > "$TMP/ns_gained.txt"
echo
echo "--- 1. directories that gained a soong_namespace ($(wc -l < "$TMP/ns_gained.txt")); listed = device uses a module from it but does not import it"
hits1=0
while read -r d; do
  [ -d "$OLD_SRC/$d" ] || continue                     # brand-new dir, nothing to lose
  grep -qxF "$d" "$TMP/product_ns.txt" && grep -qxF "$d" "$TMP/bp_imports.txt" && continue
  module_names "$NEW_SRC" "$d" > "$TMP/mods.txt"
  comm -12 "$TMP/mods.txt" "$TMP/dev_refs.txt" > "$TMP/used.txt"
  # Same-named module in a namespace the device DOES import? That is the wrong-module fall-through,
  # and it bites even when nothing in the device tree names the module.
  : > "$TMP/shadow.txt"
  while read -r ns; do
    [ "$ns" = "$d" ] && continue
    [ -d "$NEW_SRC/$ns" ] || continue
    module_names "$NEW_SRC" "$ns" | comm -12 - "$TMP/mods.txt" | sed "s#\$# $ns#" >> "$TMP/shadow.txt"
  done < "$TMP/product_ns.txt"
  [ -s "$TMP/used.txt" ] || [ -s "$TMP/shadow.txt" ] || continue
  hits1=$((hits1+1))
  inprod=no; grep -qxF "$d" "$TMP/product_ns.txt" && inprod=yes
  inbp=no;   grep -qxF "$d" "$TMP/bp_imports.txt"  && inbp=yes
  printf '  %s\n      in PRODUCT_SOONG_NAMESPACES: %s   in device Android.bp imports: %s\n      device uses: %s\n' \
    "$d" "$inprod" "$inbp" "$(tr '\n' ' ' < "$TMP/used.txt")"
  while read -r m ns; do
    printf '      !! %s is ALSO defined in imported %s -- list %s first or the search resolves there\n' "$m" "$ns" "$d"
  done < "$TMP/shadow.txt"
done < "$TMP/ns_gained.txt"
[ "$hits1" = 0 ] && echo "  (none)"

# --- 2. imported namespaces that do not exist in the new tree ------------------------------------
echo
echo "--- 2. PRODUCT_SOONG_NAMESPACES entries with no directory in NEW_SRC (manifest dropped the project)"
hits2=0
while read -r ns; do
  [ -d "$NEW_SRC/$ns" ] && continue
  hits2=$((hits2+1))
  was="absent in OLD_SRC too"
  [ -d "$OLD_SRC/$ns" ] && was="present in OLD_SRC ($(module_names "$OLD_SRC" "$ns" | wc -l) modules)"
  printf '  %s   -- %s\n' "$ns" "$was"
done < "$TMP/product_ns.txt"
[ "$hits2" = 0 ] && echo "  (none)"

# --- 3. modules the device uses that vanished from an imported namespace -------------------------
echo
echo "--- 3. modules the device references, defined under an imported namespace in OLD_SRC, gone from NEW_SRC"
hits3=0
cat "$TMP/product_ns.txt" "$TMP/bp_imports.txt" | sort -u | while read -r ns; do
  [ -d "$OLD_SRC/$ns" ] || continue
  module_names "$OLD_SRC" "$ns" > "$TMP/mo.txt"
  if [ -d "$NEW_SRC/$ns" ]; then module_names "$NEW_SRC" "$ns" > "$TMP/mn.txt"; else : > "$TMP/mn.txt"; fi
  comm -23 "$TMP/mo.txt" "$TMP/mn.txt" | comm -12 - "$TMP/dev_refs.txt" | while read -r m; do
    # Still defined somewhere else in the new tree (moved, not removed)?
    if grep -rqE --include=Android.bp "name:\s*\"$m\"" "$NEW_SRC/hardware" "$NEW_SRC/vendor" "$NEW_SRC/system" "$NEW_SRC/frameworks" 2>/dev/null; then
      continue
    fi
    old_bp=$(grep -rlE --include=Android.bp "name:\s*\"$m\"" "$OLD_SRC/$ns" 2>/dev/null | head -1 | sed "s#^$OLD_SRC/##")
    printf '  %-50s was in %s\n' "$m" "$old_bp"
    echo x >> "$TMP/hits3"
  done
done
[ -s "$TMP/hits3" ] || echo "  (none)"

# --- 4. imports changed inside namespaces the device uses ----------------------------------------
echo
echo "--- 4. imported namespaces whose own imports: changed (informational)"
hits4=0
while read -r ns; do
  [ -f "$OLD_SRC/$ns/Android.bp" ] && [ -f "$NEW_SRC/$ns/Android.bp" ] || continue
  o=$(awk '/^soong_namespace/,/^}/' "$OLD_SRC/$ns/Android.bp" | grep -oE '"[^"]+"' | sort | tr '\n' ' ')
  n=$(awk '/^soong_namespace/,/^}/' "$NEW_SRC/$ns/Android.bp" | grep -oE '"[^"]+"' | sort | tr '\n' ' ')
  [ "$o" = "$n" ] && continue
  hits4=$((hits4+1))
  printf '  %s\n      old: %s\n      new: %s\n' "$ns" "${o:-(none)}" "${n:-(none)}"
done < "$TMP/product_ns.txt"
[ "$hits4" = 0 ] && echo "  (none)"

# --- 5. anything referenced that nothing in the new tree defines --------------------------------
echo
echo "--- 5. referenced modules with no definition anywhere in NEW_SRC (Android.bp name: / LOCAL_MODULE)"
# Every module name in the tree. One find over the checkout; ~1 min on a full tree. Skips out/
# and prebuilts/ (SDK prebuilts do not matter for device modules).
{ find "$NEW_SRC" \( -name out -o -name .repo -o -name prebuilts -o -name .git \) -prune -o -name Android.bp -print0 \
    | xargs -0 -r grep -hoE '^\s*name:\s*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/';
  find "$NEW_SRC" \( -name out -o -name .repo -o -name prebuilts -o -name .git \) -prune -o -name Android.mk -print0 \
    | xargs -0 -r grep -hoE '^\s*LOCAL_MODULE\s*:?=\s*\S+' | sed -E 's/.*=\s*//'; } 2>/dev/null \
  | sort -u > "$TMP/all_modules.txt"
# Blob trees: vendor/<brand>/<codename> plus whatever EXTRA_TREES names.
codename=$(basename "$DEV"); blobtrees=""
for b in "$NEW_SRC"/vendor/*/"$codename"; do [ -d "$b" ] && blobtrees="$blobtrees ${b#"$NEW_SRC"/}"; done
blobtrees="$blobtrees ${EXTRA_TREES:-}"
# Narrower than dev_refs: only the positions that must name a module (PRODUCT_PACKAGES, and the
# dependency lists in Android.bp), so srcs, rc files and copy targets do not show up as noise.
bp_dep_names() { # $1=dir
  find "$1" -name Android.bp -print0 2>/dev/null | xargs -0 -r awk '/(shared_libs|static_libs|header_libs|whole_static_libs|required|defaults|interfaces|overrides|vintf_fragment_modules): \[/,/\]/' \
    | grep -oE '"[^"]+"' | tr -d '"'
}
{ mk_blocks PRODUCT_PACKAGES;
  bp_dep_names "$DEVTREE";
  for t in $blobtrees; do
    bp_dep_names "$NEW_SRC/$t";
    find "$NEW_SRC/$t" -name '*.mk' -print0 2>/dev/null | xargs -0 -r awk '/PRODUCT_PACKAGES[ \t]*\+?=/{on=1} on{print; if ($0 !~ /\\[ \t]*$/) on=0}' \
      | sed -E 's/#.*//; s/PRODUCT_PACKAGES[ \t]*\+?=//' | tr ' \t\\' '\n\n\n';
  done; } 2>/dev/null \
  | sed -E 's/:(32|64)$//' | grep -E '^[A-Za-z][A-Za-z0-9_.@+-]*$' \
  | grep -vE -- '-V[0-9]+-(ndk|cpp|java|rust|ndk_platform)$|_interface-(ndk|cpp|java|rust)$|\.(vendor|product|system_ext|vendor_ramdisk|recovery)$|^libc\+\+$|^libc$|^libm$|^libdl$' \
  | sort -u | comm -23 - "$TMP/all_modules.txt" > "$TMP/undefined.txt"
echo "    checked device refs + blob trees:$blobtrees"
if [ -s "$TMP/undefined.txt" ]; then
  echo "    (names generated from other modules -- .vendor variants, -V<n>-ndk -- are already filtered;"
  echo "     an entry here that is a make variable expansion or a PRODUCT_COPY_FILES word is noise)"
  sed 's/^/  /' "$TMP/undefined.txt"
else
  echo "  (none)"
fi

# --- 6. literal tree paths in the device makefiles that exist in OLD_SRC but not NEW_SRC -----------
echo
echo "--- 6. paths named in the device .mk files that OLD_SRC has and NEW_SRC does not"
find "$DEVTREE" -name '*.mk' -print0 | xargs -0 -r grep -hoE '(^|[ =,(])(build|device|hardware|vendor|frameworks|system|external|packages|kernel)/[A-Za-z0-9_./+-]+' \
  | sed -E 's/^[ =,(]//' | grep -v '\$' | sort -u | while read -r p; do
    [ -e "$NEW_SRC/$p" ] && continue
    [ -e "$OLD_SRC/$p" ] || continue          # never existed (blob-only paths, -include guards)
    echo "  $p"; echo x >> "$TMP/hits6"
  done
[ -s "$TMP/hits6" ] || echo "  (none)"
echo "    (an -include or inherit-product-if-exists of a missing file is silent; a plain include,"
echo "     a BoardConfig file variable or a Soong module source path is a hard error)"

# --- 7. DT_NEEDED of every prebuilt ELF in the blob trees ------------------------------------------
# A blob's linker deps are invisible to checks 3 and 5: nothing in a makefile names them. Soong
# still fails the build ("depends on undefined module") when the HIDL/AIDL library a blob loads
# has been deleted from the platform (24.0 dropped android.frameworks.stats@1.0 -> fpc blob).
echo
echo "--- 7. libraries the prebuilt blobs are linked against that NEW_SRC does not build or ship"
if command -v readelf >/dev/null 2>&1; then
  { for t in $blobtrees; do
      find "$NEW_SRC/$t" -type f \( -name '*.so' -o -path '*/bin/*' \) -print0 2>/dev/null \
        | xargs -0 -r readelf -d 2>/dev/null | grep -oE 'Shared library: \[[^]]+\]' | sed -E 's/.*\[(.*)\]/\1/'
    done; } | sort -u > "$TMP/needed.txt"
  # Provided by: any module name (soong strips .so), or another blob in the same trees.
  { cat "$TMP/all_modules.txt"
    for t in $blobtrees; do find "$NEW_SRC/$t" -name '*.so' -printf '%f\n' 2>/dev/null | sed 's/\.so$//'; done; } \
    | sort -u > "$TMP/providers.txt"
  # AIDL backends are generated names: android.hardware.power-V1-ndk is defined if android.hardware.power is.
  sed 's/\.so$//' "$TMP/needed.txt" | sort -u | comm -23 - "$TMP/providers.txt" | while read -r n; do
    base=$(echo "$n" | sed -E 's/(-V[0-9]+)?-(ndk|cpp|java|rust|ndk_platform)$//')
    [ "$base" != "$n" ] && grep -qxF "$base" "$TMP/providers.txt" && continue
    echo "$n"
  done > "$TMP/needed_missing.txt"
  if [ -s "$TMP/needed_missing.txt" ]; then
    echo "    (anything @x.y or -V<n> here is a deleted interface library; a versioned lib like"
    echo "     libprotobuf-cpp-full-3.9.1 is fine if the blob Android.bp maps it to a -vendorcompat module."
    echo "     Find the blob with: readelf -d <blob> | grep <name>)"
    grep -vE '^(libc|libm|libdl|libdl_android|ld-android|libstdc\+\+|libc\+\+|libgcc)$' "$TMP/needed_missing.txt" | sed 's/^/  /'
  else
    echo "  (none)"
  fi
else
  echo "  (skipped: readelf not installed -- apt install binutils)"
fi

echo
echo "  Fix (1) in both places: PRODUCT_SOONG_NAMESPACES in the device .mk AND imports: in the device"
echo "  Android.bp. Fix (2) with a local-manifest pin. Fix (3) with a revert patch on the upstream"
echo "  project, or drop the feature. Fix (5) and (7) the same way as (3), or by converting the consumer."
echo "  Fix (6) by dropping the include or pointing it at the moved file."
echo "  Check every fix against the ORDER note in the header."
