#!/usr/bin/env bash
# fn-calls.sh — what one function in a stripped-of-source vendor library calls, and the constants
# it passes: the fastest way from a qcril/RIL handler symbol to the QMI message id it sends.
#
#   fn-calls.sh <lib.so> <symbol|0xaddr> [--len BYTES] [--all] [--dis out.dis]
#
# Prints the external calls (`bl`) in the function in order, dropping the logging/string noise
# (qcril_format_log_msg, strlcpy, pthread_*, fprintf ...) unless --all, and every 2-4 digit hex
# immediate loaded into an argument register (w0-w7) before each call. Read it as: the constant
# before `*_send_cmd`/`qmi_client_send_msg_sync` is the message id, the other immediates are the
# request/response lengths and the timeout. Confirm the id against `qmi-services.py idl`, whose
# "C struct N bytes" must equal the length passed.
#
# Tracing an OEM RIL request end to end on a 2016 LG device went: RIL.smali gives the request
# number -> `strings` on libril-qc-qmi gives the handler name -> this prints
#   mov w0, #0x609 ... mov w5, #0x1f4 ... bl qcci_qmi_lge_vss_send_cmd
# -> `idl` shows REQ 0x0609 as {u32; u32; u8[1024]} = the 0x410 passed. Four steps, no debugger.
#
# Misses ids that go through a stack slot (`mov w8, #0x603; str w8, [sp, #..]`, as in a dispatcher
# that picks the id by argument): when a send shows no `<-`, keep the disassembly with --dis and read
# the stores before the call.
#
# aarch64 and arm32 libs with a dynamic symbol table (vendor libs keep theirs). The window is the
# distance to the next symbol, or --len. Needs llvm-objdump and nm.
set -uo pipefail
LIB="${1:?usage: fn-calls.sh <lib.so> <symbol|0xaddr> [--len BYTES] [--all] [--dis out.dis]}"
SYM="${2:?usage: fn-calls.sh <lib.so> <symbol|0xaddr> [--len BYTES] [--all] [--dis out.dis]}"; shift 2
LEN=""; ALL=0; DIS=""
while [ $# -gt 0 ]; do
  case "$1" in --len) LEN="$2"; shift ;; --all) ALL=1 ;; --dis) DIS="$2"; shift ;; *) echo "!! unknown arg $1" >&2; exit 2 ;; esac; shift
done
[ -f "$LIB" ] || { echo "!! no such lib: $LIB" >&2; exit 1; }
NOISE='log_msg|strlc|pthread_|fprintf|msg_sprintf|get_thread_name|get_process_instance_id|log_msg_to_adb|__stack_chk|memset|memcpy|strlen|snprintf'

SYMS=$(nm -D --defined-only "$LIB" 2>/dev/null | awk '$2 ~ /^[TtWw]$/ {print $1, $3}' | sort)
if [[ "$SYM" == 0x* ]]; then
  START=$((SYM))
else
  START=$(echo "$SYMS" | awk -v s="$SYM" '$2==s {print "0x"$1}')
  [ -n "$START" ] || { echo "!! $SYM not in the dynamic symbol table of $LIB (try: strings $LIB | grep -i <keyword>)" >&2; exit 1; }
  START=$((START))
fi
if [ -z "$LEN" ]; then
  NEXT=$(echo "$SYMS" | awk -v a="$START" '{v=strtonum("0x"$1); if (v>a) {print v; exit}}')
  LEN=$(( ${NEXT:-$((START+0x2000))} - START ))
fi
END=$((START+LEN))
printf '%s @0x%x, %d bytes\n' "$SYM" "$START" "$LEN"
DISOUT="${DIS:-$(mktemp -p "${TMPDIR:-$PWD}" fn-calls.XXXX.dis)}"
llvm-objdump -d --no-show-raw-insn --start-address=$START --stop-address=$END "$LIB" > "$DISOUT" 2>/dev/null
# Immediates into argument registers, then the call they feed.
awk -v all=$ALL -v noise="$NOISE" '
  /mov[kz]?\tw[0-7], #0x[0-9a-f]{2,4}($|[^0-9a-f])/ { gsub(/.*mov[kz]?\t/, ""); sub(/[ \t]*\/\/ =/, "="); imm[++n] = $0; next }
  /\tbl\t/ {
    tgt = $NF; gsub(/[<>]/, "", tgt); sub(/@plt/, "", tgt)
    if (!all && tgt ~ noise) next   # keep the immediates: memset/strlcpy sit between the mov and the send
    line = sprintf("%-10s bl %s", $1, tgt)
    if (n) { line = line "   <-"; for (i = 1; i <= n; i++) line = line " " imm[i] }
    print line; n = 0
  }' "$DISOUT"
[ -n "$DIS" ] && echo "disassembly: $DIS" || rm -f "$DISOUT"
