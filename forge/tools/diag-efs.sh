#!/usr/bin/env bash
# diag-efs.sh — read a modem EFS/NV item file over /dev/diag, on a connected device.
#
#   diag-efs.sh <buildid|hello|ls DIR|read PATH|write PATH HEX [OFLAG MODE]|rm PATH|probe HEX>
#
# buildid prints the modem build id, which is a sanity check with a known answer -- if that is
# wrong, nothing below it is trustworthy. read takes an item path and prints hex and decimal.
# probe sends a raw diag payload and prints every reply, including the error answers. write creates
# the item if absent; EFS2's oflag values are Linux-style, so O_WRONLY|O_CREAT is 0x41, which is the
# default. Verify every write by reading it back -- a write can report success having gone nowhere.
#
# Before writing anything, check the modem actually READS the item: `strings` the modem image for the
# item name. An EFS tree accumulates items from older firmware and from AP-side provisioning tools,
# and an item no build references can be written all day with no effect.
#
# WHY
#
# A modem feature can be entirely present in the firmware and still never run, because the thing
# that gates it is a file in the modem's own EFS that no part of Android can see. `getprop` cannot
# reach it, the RIL does not expose it, and a missing item is indistinguishable from a disabled one
# from the outside -- both simply produce a feature that does nothing.
#
# This reads those items directly. It is the difference between "the modem refuses" and "the modem
# was never told", which are the same symptom and completely different problems.
#
# THREE THINGS THAT MAKE IT AWKWARD, ALL CONFIRMED AGAINST THE KERNEL, NOT ASSUMED
#
#   - Requests are [u32 USER_SPACE_DATA_TYPE][HDLC frame]: diagchar_write() hands the payload
#     straight to diag_process_hdlc(), so CRC-16/X-25, 0x7d/0x7e escaping and the 0x7e terminator
#     are the caller's job.
#   - Replies from the MODEM only reach userspace when logging_mode is MEMORY_DEVICE_MODE.
#     Otherwise diagchar_read() clears the ready flag and drops them, so the modem looks silent.
#   - But MEMORY_DEVICE_MODE also sets mask_check, and mask_request_validate() then allows only a
#     whitelist -- for DIAG_SUBSYS_FS that is HELLO and QUERY, so OPEN/READ fail in the KERNEL with
#     EFAULT and never reach the modem at all. Requesting UART_MODE takes the branch that clears
#     mask_check and then forces MEMORY_DEVICE_MODE anyway, which is the combination needed.
#
# Also: this driver implements no .poll, so poll() always reports ready and the following read()
# parks forever. The tool uses an alarm instead, because that wait is interruptible.
#
# The binary is cross-compiled in a container so the host needs no toolchain, and cached.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/diag-efs/diag-efs.c"
OUT="$HERE/diag-efs/diag-efs.aarch64"
IMAGE="${XC_IMAGE:-aosp-xc:22.04}"
ADB="${ADB:-adb}"

[ $# -ge 1 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -f "$SRC" ] || { echo "!! missing $SRC" >&2; exit 1; }

if [ ! -x "$OUT" ] || [ "$SRC" -nt "$OUT" ]; then
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo ">> building $IMAGE (one time: ubuntu + gcc-aarch64-linux-gnu)"
    BASE="${XC_BASE:-ubuntu:22.04}"
    docker rm -f rom-forge-xc >/dev/null 2>&1
    docker run --name rom-forge-xc --user 0:0 "$BASE" bash -c \
      'apt-get update -qq && apt-get install -y -qq gcc-aarch64-linux-gnu' >/dev/null 2>&1 || {
        echo "!! could not prepare the cross-compile image" >&2; exit 1; }
    docker commit rom-forge-xc "$IMAGE" >/dev/null
    docker rm -f rom-forge-xc >/dev/null 2>&1
  fi
  echo ">> cross-compiling diag-efs for aarch64"
  docker run --rm --user 0:0 -v "$HERE/diag-efs":/w -w /w "$IMAGE" \
    bash -c 'aarch64-linux-gnu-gcc -static -O2 -Wall -o diag-efs.aarch64 diag-efs.c' || exit 1
fi

[ "$("$ADB" shell id -u 2>/dev/null | tr -d '\r')" = "0" ] || \
  echo "!! not root; /dev/diag is not readable otherwise. Run 'adb root'." >&2

"$ADB" push "$OUT" /data/local/tmp/diag-efs >/dev/null 2>&1 || {
  echo "!! could not push the helper" >&2; exit 1; }
"$ADB" shell 'chmod 755 /data/local/tmp/diag-efs'
"$ADB" shell "/data/local/tmp/diag-efs $*"
