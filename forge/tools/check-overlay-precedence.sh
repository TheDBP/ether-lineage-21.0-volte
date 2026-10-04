#!/usr/bin/env bash
# check-overlay-precedence.sh — which overlay directory wins for every resource that more than one
# device overlay defines, and what each framework dimen the overlays touch resolves to.
#
#   check-overlay-precedence.sh <src-root> <product.mk>
#   check-overlay-precedence.sh <src-root> --dirs <overlay-dir> [<overlay-dir> ...]
#
# Reads DEVICE_PACKAGE_OVERLAYS / PRODUCT_PACKAGE_OVERLAYS out of the product makefile and every
# makefile it inherits (in inherit order, which is the order the build uses), then lists each
# resource name (per target package and values qualifier) that two or more of those directories
# define. The FIRST directory in the list wins: package_internal.mk reverses LOCAL_RESOURCE_DIR
# because "in aapt2 the last takes precedence", and the auto-generated RRO goes through the same
# file, so a value in device/<v>/<device-common>/overlay cannot be overridden from a tree that
# inherits it and adds its overlay afterwards. Also prints every framework dimen (core/res) the
# overlays set, with the winner, so a flattened indirection stands out: the framework defines
# status_bar_height as @dimen/status_bar_height_portrait, and a common tree that pins it to 32dp
# silently discards the 160px a device tree put in status_bar_height_portrait. On the V20 under 24.0
# that put the expanded-QS clock under the camera cutout, because SystemUI now sizes the header
# rows from status_bar_height. Exit 1 when any resource is defined in more than one directory.
set -uo pipefail
export LC_ALL=C
[ $# -ge 2 ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SRC=$(cd "$1" && pwd) || exit 2; shift

dirs=()
if [ "$1" = --dirs ]; then
  shift; dirs=("$@")
else
  # Walk inherit-product in order; an overlay line is taken where the make parser would see it.
  seen=()
  walk() {
    local mk=$1 line target
    for s in "${seen[@]:-}"; do [ "$s" = "$mk" ] && return; done; seen+=("$mk")
    [ -f "$mk" ] || return
    local lp; lp=$(dirname "$mk")
    while IFS= read -r line; do
      case "$line" in
        *inherit-product*)
          target=$(sed -n 's/.*inherit-product[-a-z]*, *\([^)]*\)).*/\1/p' <<<"$line")
          target=${target//\$(LOCAL_PATH)/$lp}; target=${target//\$(SRC_TARGET_DIR)/build/make/target}
          target=${target//\$(COMMON_PATH)/$lp}
          case "$target" in /*) ;; *) target=$SRC/$target;; esac
          walk "$target";;
        *PACKAGE_OVERLAYS*[:+]=*)
          target=$(sed -n 's/.*OVERLAYS *[:+]*= *\(.*\)$/\1/p' <<<"$line" | tr -d '\\')
          for t in $target; do
            t=${t//\$(LOCAL_PATH)/$lp}; t=${t//\$(COMMON_PATH)/$lp}
            case "$t" in /*) ;; *) t=$SRC/$t;; esac
            [ -d "$t" ] && dirs+=("$t")
          done;;
      esac
    done < "$mk"
  }
  mk=$1; case "$mk" in /*) ;; *) mk=$SRC/$mk;; esac
  [ -f "$mk" ] || { echo "no such product makefile: $mk" >&2; exit 2; }
  walk "$mk"
fi
[ ${#dirs[@]} -gt 0 ] || { echo "no overlay directories found" >&2; exit 2; }

echo "## overlay directories, highest precedence first"
i=0; for d in "${dirs[@]}"; do i=$((i+1)); echo "  $i. ${d#$SRC/}"; done

# key = <target package path>|<values qualifier>|<type>|<name>; value = dir index
export TMPDIR="${BUILD_ROOT:-$SRC/..}/tmp"; mkdir -p "$TMPDIR"
tmp=$(mktemp "$TMPDIR/ovl.XXXXXX")
trap 'rm -f "$tmp"' EXIT
i=0
for d in "${dirs[@]}"; do
  i=$((i+1))
  find "$d" -path '*/res/values*/*.xml' -type f | while read -r f; do
    rel=${f#$d/}; pkg=${rel%%/res/*}; qual=${rel##*/res/}; qual=${qual%%/*}
    grep -o '<\(dimen\|bool\|integer\|string\|string-array\|integer-array\|array\|item\|color\|fraction\) [^>]*name="[^"]*"' "$f" \
      | sed -n 's/^<\([a-z-]*\).*name="\([^"]*\)".*/\1 \2/p' \
      | while read -r type name; do echo "$pkg|$qual|$type|$name|$i|${f#$SRC/}"; done
  done
done | sort -t'|' -k1,5 -u > "$tmp"   # one row per (resource, directory); product/plural variants collapse

echo "## resources defined in more than one overlay directory (first listed wins)"
rc=0
awk -F'|' '{k=$1"|"$2"|"$3"|"$4; n[k]++; if(!(k in first)||$5<first[k]) first[k]=$5; files[k]=files[k] "\n      " $6}
  END{for(k in n) if(n[k]>1){print "  " k " -> dir " first[k] files[k]; bad=1} if(!bad) print "  none"; exit bad}' "$tmp" || rc=1

echo "## framework dimens the overlays set (winner only)"
awk -F'|' '$1 ~ /frameworks\/base\/core$/ && $3=="dimen" {k=$2"|"$4; if(!(k in w)){w[k]=1; print "  " $4 " [" $2 "] <- " $6}}' "$tmp" | sort
exit $rc
