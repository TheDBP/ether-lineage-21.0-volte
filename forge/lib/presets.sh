#!/bin/bash
# presets.sh -- read PRESETS and the option registry. Sourced; defines functions, runs nothing.
#
# A PRESET is a named set of options plus a build tag. It is not a list of things to build together:
# one build command produces one image. The name exists so the two or three combinations anyone
# actually uses do not have to be retyped.
#
#   PRESETS="
#     full   tag=turbo        options=gapps,root,oem,nav-icons
#     clean  tag=turbo-clean  options=nav-icons
#   "
#
# Every value is labelled. The format this replaced was positional --
# "full:true:true:true:turbo:WITH_NAV_ICONS=true" -- where three unnamed booleans meant gapps, oem
# and root in an order you had to look up, and adding an option changed the shape of every row.
#
# An OPTION is a capability the forge carries, one directory under forge/options/. The registry is
# the source of truth for what exists: a preset naming an option with no directory is an error, not
# a silently ignored word.

# All option names the forge knows about.
forge_all_options() {
  local d
  for d in "${FORGE_DIR:?FORGE_DIR unset}"/options/*/; do
    [ -f "$d/option.conf" ] || continue
    basename "$d"
  done
}

# nav-icons -> WITH_NAV_ICONS. Derived, never declared, so the name in a preset and the name a
# makefile tests cannot drift apart.
forge_option_switch() { printf 'WITH_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"; }

# Export an option's build-env into the make environment: VAR=value lines, one per line, exported
# when the option is on and unset when it is off (so a build without the option does not inherit
# them from the caller's shell). This is for variables a makefile tests at parse time -- ifdef
# WITH_ADB_INSECURE in vendor/lineage/config/common.mk. Setting such a variable in product.mk does
# nothing: inherit-product only records the path, and vendor/extra/product.mk is read after
# common.mk has finished. Environment variables are visible to every makefile from the start.
forge_export_option_env() {
  local o sw f kv
  for o in $(forge_all_options); do
    f="${FORGE_DIR:?FORGE_DIR unset}/options/$o/build-env"
    [ -f "$f" ] || continue
    sw="$(forge_option_switch "$o")"
    while IFS= read -r kv || [ -n "$kv" ]; do
      kv="${kv%%#*}"; kv="${kv%"${kv##*[![:space:]]}"}"
      [ -n "$kv" ] || continue
      case "$kv" in
        [A-Za-z_]*=*) ;;
        *) echo "!! $f: not VAR=value: $kv" >&2; return 1 ;;
      esac
      if [ "${!sw:-}" = true ]; then export "$kv"; else unset "${kv%%=*}"; fi
    done < "$f"
  done
}

# The raw row for a preset, comments stripped. Empty output + non-zero if there is no such preset.
_forge_preset_row() {
  local want="$1" line first
  while IFS= read -r line; do
    line="${line%%#*}"
    first="$(printf '%s\n' $line 2>/dev/null | head -1)"
    [ -n "$first" ] || continue
    if [ "$first" = "$want" ]; then printf '%s\n' "$line"; return 0; fi
  done <<< "${PRESETS:-}"
  return 1
}

# "stock" is reserved and exists on every device without being declared anywhere. It is the EMPTY
# option set: LineageOS as upstream ships it, carrying only the overlay/patches that make this
# hardware run, and none of the theming, app or behaviour options. Unlike every other preset it
# takes neither COMMON_OPTIONS nor EXTRA_OPTIONS, because "stock plus the dozen things we always
# add" is not stock.
#
# The point is to have a reference. When something misbehaves, a stock build answers "is this ours
# or upstream's?" in one flash, which is otherwise a question that can only be argued about. There
# was no way to ask for it before: an ad-hoc OPTIONS="" is indistinguishable from unset, so
# bootstrap fell through to the first preset, and every declared preset gets COMMON_OPTIONS merged
# in -- so the empty set was not expressible.
#
# A device may still declare its own `stock` row, and that row then wins.
FORGE_STOCK_PRESET=stock

_forge_stock_is_synthetic() {
  [ "$1" = "$FORGE_STOCK_PRESET" ] && ! _forge_preset_row "$FORGE_STOCK_PRESET" >/dev/null 2>&1
}

forge_preset_names() {
  local line first seen_stock=0
  while IFS= read -r line; do
    line="${line%%#*}"
    first="$(printf '%s\n' $line 2>/dev/null | head -1)"
    [ -n "$first" ] || continue
    [ "$first" = "$FORGE_STOCK_PRESET" ] && seen_stock=1
    printf '%s\n' "$first"
  done <<< "${PRESETS:-}"
  # Appended, never prepended: bootstrap builds the first name when none is given and release.sh
  # publishes the first that omits gapps and oem. Putting stock at the top would silently change
  # both of those to a build nobody asked for.
  [ "$seen_stock" = 1 ] || printf '%s\n' "$FORGE_STOCK_PRESET"
}

# Value of key=... in a preset row. Absent key -> empty string, still exit 0; unknown preset -> 1.
forge_preset_field() {
  local row kv
  row="$(_forge_preset_row "$1")" || return 1
  for kv in $row; do
    case "$kv" in "$2="*) printf '%s' "${kv#"$2"=}"; return 0 ;; esac
  done
  return 0
}

# The build tag. An option added from OUTSIDE the preset -- EXTRA_OPTIONS -- changes what the image
# contains, so it has to change the tag too: every such option appends "-<name>" (sorted, so the
# same set always gives the same tag). release.sh proves an artifact by the tag in its filename: it
# picks the preset that omits gapps and oem, then refuses any zip not carrying that preset's tag. A
# clean build carrying reclaimed OEM art under the plain clean tag would walk straight through that
# gate. Deriving the suffix here means the tag cannot disagree with the contents, which a
# hand-written "clean-oem tag=turbo-clean" row could.
forge_preset_tag() {
  local tag own o
  if _forge_stock_is_synthetic "$1"; then printf '%s' "$FORGE_STOCK_PRESET"; return 0; fi
  tag="$(forge_preset_field "$1" tag)" || return 1
  own=" $(forge_preset_field "$1" options | tr ',' ' ') $(printf '%s' "${COMMON_OPTIONS:-}" | tr ',' ' ') "
  # Only suffix what the preset does not already declare; a preset that names oem has its own tag.
  for o in $(printf '%s' "${EXTRA_OPTIONS:-}" | tr ', ' '\n\n' | sort -u); do
    case "$own" in *" $o "*) ;; *) tag="$tag-$o" ;; esac
  done
  printf '%s' "$tag"
}

# The prefix every preset tag on this device shares -- `turbo` where the rows read turbo,
# turbo-clean, turbo-libre. That prefix is the device's identity rather than any one preset's, so an
# ad-hoc build should keep it. Taken from the first row and then CHECKED against the rest, so a device
# whose tags have nothing in common gets no prefix instead of a wrong one. The synthetic stock preset
# is excluded: its tag is `stock` by definition and would defeat the check on every device.
_forge_preset_tag_prefix() {
  local n t cand="" all
  all="$(forge_preset_names)"
  for n in $all; do
    _forge_stock_is_synthetic "$n" && continue
    t="$(forge_preset_field "$n" tag 2>/dev/null)" || continue
    [ -n "$t" ] || continue
    [ -n "$cand" ] || { cand="${t%%-*}"; continue; }
    case "$t" in "$cand"*) ;; *) printf ''; return 0 ;; esac
  done
  printf '%s' "$cand"
}

# The tag for a build described by OPTIONS rather than by a preset. Derived for the same reason preset
# tags are: so the filename cannot disagree with the contents. Options are sorted, so the same set
# always produces the same name.
forge_adhoc_tag() {
  local opts pre
  opts="$(printf '%s' "${1:-}" | tr ', ' '\n\n' | sed '/^$/d' | sort -u | tr '\n' '-')"
  opts="${opts%-}"
  pre="$(_forge_preset_tag_prefix)"
  if [ -n "$pre" ] && [ -n "$opts" ]; then printf '%s-%s' "$pre" "$opts"
  elif [ -n "$opts" ]; then printf '%s' "$opts"
  else printf '%s' "${pre:-adhoc}"
  fi
}

# The options for a build: COMMON_OPTIONS (everything this device always wants) plus the preset's
# own. Without the common set every preset row repeats the same dozen names, which is unreadable and
# is how one row quietly ends up missing something the others have.
forge_preset_options() {
  local own common extra out=" " o
  if _forge_stock_is_synthetic "$1"; then
    # Warn rather than silently honour it: EXTRA_OPTIONS is often set once in device.conf.local and
    # forgotten, and a "stock" image carrying oem or gapps would be a lie in the filename.
    [ -z "${EXTRA_OPTIONS:-}" ] || \
      echo "   note: preset $FORGE_STOCK_PRESET ignores EXTRA_OPTIONS='${EXTRA_OPTIONS}' -- stock takes no options" >&2
    # STOCK_OPTIONS is the device saying "these are not extras, they are part of the phone working at
    # all". ether names setup-mobile-data: without it Lineage's SetupWizard leaves mobile data off, and
    # a stock image that comes up unable to reach the network is not the working phone stock exists to
    # prove. Empty everywhere else, so no other device changes. The tag stays plain `stock`: these are
    # behavioural patches, not payload, and the audit this guards is about redistributable content.
    printf '%s' "$(printf '%s' "${STOCK_OPTIONS:-}" | tr ',' ' ')"; return 0
  fi
  own="$(forge_preset_field "$1" options | tr ',' ' ')" || return 1
  common="$(printf '%s' "${COMMON_OPTIONS:-}" | tr ',' ' ')"
  # EXTRA_OPTIONS applies to whichever preset you build -- one switch across all of them, rather than
  # an -oem twin of every preset. Set it per build (EXTRA_OPTIONS=oem PRESET=clean ...) or once in
  # device.conf.local, which is gitignored and so stays out of the published repo.
  extra="$(printf '%s' "${EXTRA_OPTIONS:-}" | tr ',' ' ')"
  for o in $common $own $extra; do
    case "$out" in *" $o "*) ;; *) out="$out$o " ;; esac
  done
  printf '%s' "${out# }" | sed 's/ $//'
}

# Check a preset names only options that exist. A typo here would otherwise be silent: the switch
# would simply never be set, and the image would build fine without whatever you asked for.
forge_preset_validate() {
  local name="$1" o known rc=0
  known=" $(forge_all_options | tr '\n' ' ') "
  for o in $(forge_preset_options "$name"); do
    case "$known" in
      *" $o "*) ;;
      *) echo "!! preset '$name' names option '$o', which does not exist in forge/options/" >&2
         echo "!! known options:$known" >&2; rc=1 ;;
    esac
  done
  return $rc
}
