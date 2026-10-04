#!/usr/bin/env bash
# blob-fixups.sh — rewrite DT_NEEDED / DT_SONAME in prebuilt vendor blobs from a declarative list,
# the way LineageOS extract-files.sh `blob_fixup` does, but at overlay time against a synced tree.
#
#   blob-fixups.sh <aosp-root> <list-file>        (apply-overlay.sh runs this on overlay/blob-fixups)
#   blob-fixups.sh --check <aosp-root> <list-file> (report only; exit 1 if anything is still unapplied)
#
# List format, one fixup per line, paths relative to <aosp-root>, '#' comments:
#
#   vendor/lge/v20-common/proprietary/vendor/lib/hw/camera.msm8996.so  remove-needed  libandroid.so
#   vendor/foo/proprietary/vendor/lib/libbar.so                        replace-needed libhidltransport.so libcutils-v29.so
#   vendor/foo/proprietary/vendor/lib/libbaz.so                        add-needed     libshim_baz.so
#   vendor/foo/proprietary/vendor/lib/libqux.so                        set-soname     libqux.so
#
# Why this exists: TheMuppets blobs come in as a git project at whatever DT_NEEDED the OEM shipped,
# and a lib that no longer resolves in the vendor linker namespace (libandroid.so, libandroid_runtime.so
# -- NDK/framework libs the vendor namespace is never linked to) kills the whole process at exec or
# dlopen time: "CANNOT LINK EXECUTABLE ... library "libandroid.so" not found". A git patch to a
# binary is unreviewable; this list is one line per fact. Check first that the blob imports nothing
# from the library it names (`nm -D --undefined-only`) -- remove-needed only drops the load, it does
# not make missing symbols appear.
#
# Every verb is idempotent, so the list can run on every overlay pass: remove-needed of an absent
# entry and add-needed of a present one are no-ops, and a reset project simply gets the same edits
# again. The tree's own patchelf is preferred (prebuilts/extract-tools, the one extract-files uses).
set -u
CHECK=0
[ "${1:-}" = "--check" ] && { CHECK=1; shift; }
AOSP="${1:-}"; LIST="${2:-}"
[ -d "$AOSP" ] && [ -f "$LIST" ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//' | head -20 >&2; exit 2; }

PE=""
for c in "$AOSP"/prebuilts/extract-tools/linux-x86/bin/patchelf-0_18 "$AOSP"/prebuilts/extract-tools/linux-x86/bin/patchelf "$(command -v patchelf || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { PE="$c"; break; }
done
[ -n "$PE" ] || { echo "!! blob-fixups: no patchelf (prebuilts/extract-tools or PATH)" >&2; exit 2; }

needed() { "$PE" --print-needed "$1" 2>/dev/null; }
has_needed() { [ "$(needed "$1" | grep -cxF -- "$2")" -gt 0 ]; }

applied=0; already=0; pending=0; bad=0
while read -r path verb a b _rest; do
  case "$path" in ''|'#'*) continue ;; esac
  f="$AOSP/$path"
  [ -f "$f" ] || { echo "!! blob-fixups: no such file: $path" >&2; bad=$((bad+1)); continue; }
  want=""   # what must be true afterwards; evaluated before and after the edit
  case "$verb" in
    remove-needed)  [ -n "$a" ] || { echo "!! $path: remove-needed needs a library" >&2; bad=$((bad+1)); continue; }
                    done_already() { ! has_needed "$f" "$a"; }
                    edit() { "$PE" --remove-needed "$a" "$f"; } ;;
    add-needed)     [ -n "$a" ] || { echo "!! $path: add-needed needs a library" >&2; bad=$((bad+1)); continue; }
                    done_already() { has_needed "$f" "$a"; }
                    edit() { "$PE" --add-needed "$a" "$f"; } ;;
    replace-needed) [ -n "$a" ] && [ -n "$b" ] || { echo "!! $path: replace-needed needs OLD NEW" >&2; bad=$((bad+1)); continue; }
                    done_already() { ! has_needed "$f" "$a"; }
                    edit() { "$PE" --replace-needed "$a" "$b" "$f"; } ;;
    set-soname)     [ -n "$a" ] || { echo "!! $path: set-soname needs a name" >&2; bad=$((bad+1)); continue; }
                    done_already() { [ "$("$PE" --print-soname "$f" 2>/dev/null)" = "$a" ]; }
                    edit() { "$PE" --set-soname "$a" "$f"; } ;;
    *) echo "!! blob-fixups: unknown verb '$verb' for $path (remove-needed|add-needed|replace-needed|set-soname)" >&2
       bad=$((bad+1)); continue ;;
  esac
  if done_already; then
    already=$((already+1)); continue
  fi
  if [ "$CHECK" = 1 ]; then
    echo "   pending: $path $verb $a ${b:-}"; pending=$((pending+1)); continue
  fi
  if edit && done_already; then
    echo "   $verb $a ${b:+-> $b }: ${path##*/}"; applied=$((applied+1))
  else
    echo "!! blob-fixups: $verb $a ${b:-} did not take on $path" >&2; bad=$((bad+1))
  fi
done < "$LIST"

if [ "$CHECK" = 1 ]; then
  echo ">> blob-fixups: $already applied, $pending pending, $bad bad"
  [ "$pending" = 0 ] && [ "$bad" = 0 ]
else
  echo ">> blob-fixups: $applied applied, $already already in place, $bad bad"
  [ "$bad" = 0 ]
fi
