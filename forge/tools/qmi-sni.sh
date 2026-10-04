#!/usr/bin/env bash
# qmi-sni.sh — bring up a modem data call from the AP as a direct QMI WDS client, bypassing the RIL,
# and print the modem's own answer: QMI result/error and the call-end reason TLVs.
#
#   qmi-sni.sh <node> <apn> <3gpp-profile> [v4|v6|v4v6] [epc|umts|none] [calltype] [keep] [sub] [muxN]
#   qmi-sni.sh q|qi <service> <msgid-hex> [tlv bytes hex...]        raw request (qi: also wait for indications)
#
#   qmi-sni.sh 0 internet 1 v4 epc sub mux1      # what the RIL sends: bind sub, bind mux port, SNI
#
# node 0 is the modem on the MSM IPC router (AF_MSM_IPC). Needs root and a kernel with the IPC
# router (msm8996-class); on devices that moved to QRTR it does not apply.
#
# WHY
#
# When the RIL reports "data call failed" the information you need -- WHICH layer refused and WHY --
# is in the QMI response the RIL swallowed. SETUP_DATA_CALL comes back as a generic cause code and
# `qmi_err_code` only shows in a verbose radio log. Sending START_NETWORK_INTERFACE yourself gives the
# raw error (0x2f UNKNOWN with no call-end TLV is a modem-side policy refusal, not a network reject),
# lets you vary one TLV at a time (profile, IP family, tech preference, mux binding), and runs the
# same on any ROM, so a modem fault is told from a RIL fault in minutes. Pair with diag-f3.sh for the
# modem's log line that explains the refusal.
#
# Stale handles: a call this tool leaves up ("keep") or the RIL's own call closing while you test can
# put qcril into CLOSE_IN_PROGRESS; an airplane-mode cycle clears it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/freestanding-arm64.sh"
[ $# -ge 3 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
xc_build_push "$HERE/qmi-sni/qmi-sni.c" "$HERE/qmi-sni/qmi-sni.aarch64" qmi-sni || exit 1
"${ADB:-adb}" shell "/data/local/tmp/qmi-sni $*"
