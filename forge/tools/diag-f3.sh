#!/usr/bin/env bash
# diag-f3.sh — capture the modem's F3 debug messages (the firmware's own printf log) over /dev/diag
# for N seconds and decode them to text on the host.
#
#   diag-f3.sh <seconds> <out.txt>          # raw stream kept beside it as <out.txt>.bin
#
# Run the thing you are debugging (a data call, an attach, a toggle) during the window. Needs root.
# Output lines: <timestamp> ssid=<subsystem> <file.c>:<line> <formatted message>. Useful ssids:
# 5000 DS, 5005 DS_3GMGR, 5006 DS_PS, 5012 ATCoP, 5022 ACLPOLICY, 5025 DS_3GPP, 5026 DS_LTE,
# 9509 LTE ML1, 63 RIL DiagLogger.
#
# WHY
#
# The modem decides things the AP never hears about -- which bearer to use, whether a profile is
# throttled, whether a boot-time flag disables a feature -- and it logs every one of those decisions
# as an F3 message with the source file and line. This is what a commercial QXDM shows. Without it a
# modem-side refusal looks like a network problem.
#
# FORMAT (verified against the kernel's diagchar and the QCOM DIAG spec; getting one offset wrong
# silently turns every message into an empty format string, which looks like an obfuscated log):
# EXT_MSG 0x79: cmd@0 ts_type@1 nargs@2 drop@3 ts u64@4 line u16@12 ssid u16@14 mask u32@16
# args u32 x nargs @20, then fmt\0 file\0. HDLC framing with 0x7e terminator, 0x7d escapes, CRC-16.
#
# Strings in the modem image stay plain, so a decoded line can be grepped straight back to the
# function that emitted it with `strings modem.img | grep`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/freestanding-arm64.sh"
[ $# -eq 2 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
ADB="${ADB:-adb}"
xc_build_push "$HERE/diag-f3/diag-f3-capture.c" "$HERE/diag-f3/diag-f3-capture.aarch64" diag-f3-capture || exit 1
"$ADB" shell "/data/local/tmp/diag-f3-capture $1 /data/local/tmp/diag-f3.bin" || exit 1
"$ADB" pull /data/local/tmp/diag-f3.bin "$2.bin" >/dev/null || exit 1
python3 "$HERE/diag-f3/diag-f3-parse.py" "$2.bin" > "$2" && echo ">> $(wc -l < "$2") lines in $2"
