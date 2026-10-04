#!/usr/bin/env bash
# check-service-domains.sh — find init services whose binary has no SELinux domain, from the built
# image, before flashing.
#
#   check-service-domains.sh <system.img> [<vendor.img> ...]
#
# Reads every *.rc under etc/init (and the init.rc family at the root) out of the given ext4 images
# (sparse or raw), takes the executable of each `service` line, and prints the label the image
# builder wrote on it. A label that is not an *_exec type means init will log
#   init: Service X does not have a SELinux domain defined
# once, early, into kmsg, and never start it. Nothing else complains: the VINTF manifest still
# declares the HAL, so whoever waitForDeclaredService()s it blocks forever -- on the vs995 that was
# system_server in ConsumerIrService, killed by its own Watchdog every ~105 s behind a boot
# animation that never ended, because a patch renamed the IR HAL binary and not its file_contexts
# line. The rc, the manifest and the sepolicy name the binary three times; this checks they agree.
#
# Paths are resolved inside the images given: /vendor/... is looked up in a vendor image if one is
# passed, else under system/vendor in the system image (vendor-in-system), /system/... under the
# system image root, /odm under vendor/odm. Services with their own `seclabel` need no exec label
# and are skipped; /apex/ binaries are not in these images and are skipped. Binaries not present in
# any image are listed as ABSENT (init logs "cannot find" and the service fails) but do not fail
# the run. What this cannot see is a binary with an *_exec label and no init_daemon_domain() behind
# it -- that one still fails the same way in init, and shows the same "does not have a SELinux
# domain" line in the console. Needs debugfs (e2fsprogs); sparse images need simg2img.
set -uo pipefail
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"
export LC_ALL=C
[ $# -ge 1 ] || { sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v debugfs >/dev/null || { echo "debugfs not found (install e2fsprogs)" >&2; exit 2; }

RAWS=(); CLEAN=()
trap 'rm -f "${CLEAN[@]}"' EXIT
for img in "$@"; do
  if [ "$(head -c4 "$img" | od -An -tx1 | tr -d ' \n')" = "3aff26ed" ]; then
    S2I=$(command -v simg2img || { ls "${ANDROID_HOST_OUT:-/nonexistent}/bin/simg2img" "$(dirname "$img")"/../../../host/linux-x86/bin/simg2img 2>/dev/null || true; } | sed -n 1p)
    [ -n "$S2I" ] && [ -x "$S2I" ] || { echo "sparse image and no simg2img (set ANDROID_HOST_OUT)" >&2; exit 2; }
    raw="$(mktemp "$TMPDIR/check-service-domains.XXXXXX")"; CLEAN+=("$raw")
    "$S2I" "$img" "$raw" || exit 1
    RAWS+=("$raw")
  else
    RAWS+=("$img")
  fi
done
SYS="${RAWS[0]}"

# label <raw> <path-in-image>  -> label, or "" when the path is not there
label() { debugfs -R "ea_get \"$2\" security.selinux" "$1" 2>/dev/null | sed -n 's/.*= "\(.*\)\\000"$/\1/p'; }
exists() { [ "$(debugfs -R "stat \"$2\"" "$1" 2>/dev/null | grep -c '^Inode:')" -gt 0 ]; }  # debugfs exits 0 on a missing path
# list_rc <raw> <dir> -> files named *.rc directly under dir
list_rc() { debugfs -R "ls -p \"$2\"" "$1" 2>/dev/null | awk -F/ '$3 ~ /^100/ && $6 ~ /\.rc$/ {print $6}'; }
cat_in() { debugfs -R "cat \"$2\"" "$1" 2>/dev/null; }
# readlink_in <raw> <path> -> link target, or nothing when the path is not a symlink
readlink_in() { debugfs -R "stat \"$2\"" "$1" 2>/dev/null | sed -n 's/^Fast link dest: "\(.*\)"$/\1/p'; }

# Where a device path lives: echo "<raw> <path-in-image>" or nothing.
resolve() {
  local p="$1" i
  case "$p" in
    /vendor/*|/odm/*)
      p="${p#/}"; [ "${p%%/*}" = odm ] && p="vendor/${p}"
      for i in "${RAWS[@]:1}"; do exists "$i" "${p#vendor/}" && { echo "$i ${p#vendor/}"; return; }; done
      exists "$SYS" "$p" && { echo "$SYS $p"; return; }
      exists "$SYS" "system/$p" && { echo "$SYS system/$p"; return; } ;;
    /system/*) exists "$SYS" "${p#/system/}" && { echo "$SYS ${p#/system/}"; return; }
               exists "$SYS" "${p#/}" && { echo "$SYS ${p#/}"; return; } ;;
    /*) exists "$SYS" "${p#/}" && { echo "$SYS ${p#/}"; return; }
        exists "$SYS" "system${p}" && { echo "$SYS system${p}"; return; } ;;
  esac
}

# Collect rc files: the image's init rc dirs, in every image given.
rcs=()  # "raw|path"
for raw in "${RAWS[@]}"; do
  if exists "$raw" system/etc/init; then dirs="system/etc/init system/etc/init/hw system/vendor/etc/init system/vendor/odm/etc/init system/product/etc/init system/system_ext/etc/init"
  else dirs="etc/init etc/init/hw odm/etc/init"; fi
  for d in $dirs; do for f in $(list_rc "$raw" "$d"); do rcs+=("$raw|$d/$f"); done; done
done
[ ${#rcs[@]} -gt 0 ] || { echo "no rc files found in the given images" >&2; exit 2; }

for e in "${rcs[@]}"; do
  raw="${e%%|*}"; rc="${e#*|}"
  # one line per service: "name bin seclabel?" -- a block ends at the next unindented line
  cat_in "$raw" "$rc" | awk '
    /^service[ \t]/ { if (name) print name, bin, sec; name=$2; bin=$3; sec=0; next }
    /^[^ \t#]/      { if (name) print name, bin, sec; name="" }
    name && $1=="seclabel" { sec=1 }
    END { if (name) print name, bin, sec }' | while read -r name bin sec; do
    case "$bin" in /apex/*) continue;; /*) ;; *) continue;; esac
    [ "$sec" = 1 ] && continue
    where=$(resolve "$bin")
    if [ -z "$where" ]; then printf '%-28s %-58s ABSENT   (%s)\n' "$name" "$bin" "$rc"; continue; fi
    # init execs through symlinks (app_process -> app_process64, false -> toybox): label the target
    hops=0; cur="$bin"
    while dest=$(readlink_in ${where}) && [ -n "$dest" ] && [ $hops -lt 8 ]; do
      case "$dest" in /*) cur="$dest";; *) cur="$(dirname "$cur")/$dest";; esac
      where=$(resolve "$cur"); hops=$((hops+1))
      [ -n "$where" ] || break
    done
    if [ -z "$where" ]; then printf '%-28s %-58s ABSENT   (symlink to %s; %s)\n' "$name" "$bin" "$cur" "$rc"; continue; fi
    lab=$(label ${where})
    case "$lab" in
      *_exec:s0) ;;
      *) printf '%-28s %-58s %s   <- no domain (%s)\n' "$name" "$bin" "${lab:-UNLABELED}" "$rc";;
    esac
  done
done | sort -u -k1,2 | tee "$TMPDIR/check-service-domains.last"
n=$(grep -c 'no domain' "$TMPDIR/check-service-domains.last"); rm -f "$TMPDIR/check-service-domains.last"
if [ "$n" -gt 0 ]; then echo ">> $n service(s) init will not start"; exit 1; fi
echo ">> every service binary carries an *_exec label"
