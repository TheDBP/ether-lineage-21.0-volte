#!/usr/bin/env bash
# check-bpf-readiness.sh — find what a kernel without eBPF (or other modern
# syscalls) will break, before you spend a build-flash-boot cycle finding out.
#
# Two modes, both useful:
#
#   --src <ANDROID_ROOT>    static: who calls BPF, and which callers abort on failure
#   --log <file>            runtime: which processes actually hit ENOSYS
#
# Written after the Nextbit Robin's 20.0 port hit eBPF four separate times --
# BpfMap's constructor, netd's BpfHandler, ClatCoordinator and swapActiveStatsMap
# -- each one costing a full flash-and-crash cycle to discover.
set -u

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[ -t 1 ] || { RED=; YEL=; GRN=; DIM=; RST=; }

# arm64 syscalls that a pre-4.x kernel will not have. Number -> name.
# The kernel logs "comm[pid]: syscall N" for each unimplemented call, which makes
# this a complete list of what userspace actually tried.
declare -A SYSCALLS=(
  [280]=bpf [281]=execveat [282]=userfaultfd [283]=membarrier [284]=mlock2
  [285]=copy_file_range [291]=statx [292]=io_pgetevents [293]=rseq
  [424]=pidfd_send_signal [434]=pidfd_open [435]=clone3 [436]=close_range
  [439]=faccessat2 [440]=process_madvise [441]=epoll_pwait2
  [442]=mount_setattr [448]=process_mrelease
)

usage() { sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 1; }

MODE=; TARGET=
while [ $# -gt 0 ]; do
  case "$1" in
    --src) MODE=src; TARGET="${2:-}"; shift 2 ;;
    --log) MODE=log; TARGET="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1"; usage ;;
  esac
done
[ -n "$MODE" ] && [ -n "$TARGET" ] || usage

# ---------------------------------------------------------------- runtime mode
if [ "$MODE" = log ]; then
  [ -r "$TARGET" ] || { echo "cannot read $TARGET"; exit 1; }
  echo
  echo "${GRN}== unimplemented syscalls actually attempted ==${RST}"
  echo "${DIM}   the kernel logs every one, so this is exhaustive for this boot${RST}"
  echo
  grep -aoE 'syscall [0-9]+' "$TARGET" | awk '{print $2}' | sort | uniq -c | sort -rn |
  while read -r n num; do
    name="${SYSCALLS[$num]:-unknown}"
    printf "   %6d  syscall %-4s %s\n" "$n" "$num" "$name"
  done

  echo
  echo "${GRN}== which processes attempted them ==${RST}"
  for num in "${!SYSCALLS[@]}"; do
    hits=$(grep -acE "syscall $num\$" "$TARGET" 2>/dev/null) || hits=0
    [ "$hits" = 0 ] && continue
    echo "   ${YEL}${SYSCALLS[$num]}${RST} (syscall $num):"
    grep -aoE "[a-zA-Z_0-9.:@-]+\[[0-9]+\]: syscall $num\$" "$TARGET" \
      | sed -E 's/\[[0-9]+\]//' | sort | uniq -c | sort -rn | head -12 | sed 's/^/     /'
  done

  echo
  echo "${GRN}== subsystems reporting ENOSYS ==${RST}"
  echo "${DIM}   high counts are noisy-but-surviving; the ones that matter are those${RST}"
  echo "${DIM}   that abort or throw -- cross-check against --src output${RST}"
  echo
  grep -aiE 'ENOSYS|Function not implemented' "$TARGET" \
    | grep -aoE '[EWIF] [A-Za-z_0-9./-]+ *:' | sed -E 's/ *:$//' \
    | sort | uniq -c | sort -rn | head -20 | sed 's/^/   /'
  echo
  exit 0
fi

# ----------------------------------------------------------------- static mode
ROOT="$TARGET"
[ -d "$ROOT" ] || { echo "not a directory: $ROOT"; exit 1; }
echo
echo "${GRN}== BPF map construction that aborts on failure ==${RST}"
echo "${DIM}   these kill the process on a kernel with no bpf() syscall${RST}"
echo
found=0
while IFS= read -r f; do
  # an abort()/LOG_ALWAYS_FATAL within a few lines of a map open
  if grep -qE 'mapRetrieve|bpfFdGet|bpf_obj_get|createMap' "$f" 2>/dev/null &&
     grep -qE '\babort\(\)|LOG_ALWAYS_FATAL' "$f" 2>/dev/null; then
    echo "   ${RED}ABORTS${RST}  ${f#$ROOT/}"
    grep -nE '\babort\(\)|LOG_ALWAYS_FATAL' "$f" | head -3 | sed 's/^/            /'
    found=$((found+1))
  fi
done < <(grep -rl --include=*.h --include=*.cpp -E 'BpfMap|mapRetrieve|bpfFdGet' "$ROOT" 2>/dev/null | head -60)
[ "$found" = 0 ] && echo "   ${GRN}none${RST}"

echo
echo "${GRN}== Java/JNI BPF entry points that throw ==${RST}"
echo "${DIM}   maybeThrow() turns an ENOSYS into a ServiceSpecificException; if the${RST}"
echo "${DIM}   caller does not catch it, the whole operation is abandoned${RST}"
echo
grep -rn --include=*.java -E 'maybeThrow\(' "$ROOT/packages/modules/Connectivity" 2>/dev/null \
  | head -20 | sed "s|$ROOT/|   |"

echo
echo "${GRN}== callers that DO degrade gracefully (for reference) ==${RST}"
grep -rn --include=*.cpp --include=*.java -E 'isValid\(\)|isBpfSupported|bpf.progs_loaded' "$ROOT" 2>/dev/null \
  | head -10 | sed "s|$ROOT/|   |"
echo
