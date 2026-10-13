#!/bin/bash
# ims-call-test.sh — place an outgoing call on a VoLTE port and report how it ended, so a call that
# never ends is a test failure instead of something noticed by hand.
#
#   ./forge/tools/ims-call-test.sh cancel [--number N] [--log F]   # end it once it reaches ALERTING
#   ./forge/tools/ims-call-test.sh wait   [--number N] [--log F]   # let the network decide
#
# Needs root adb (a bringup build). Exits non-zero if a call is left behind, which is the whole
# point: the failures this catches all look like a dialer that will not close.
#
# WHY THE TWO MODES ARE DIFFERENT TESTS
#
# `cancel` only exercises the interesting path once the call has reached ALERTING. Before that the
# framework still holds mPendingMO and disconnects through it, so cancelling during DIALING passes
# even on a broken build. The script waits for ALERTING rather than sleeping a fixed time.
#
# `wait` is how a network-side failure is caught: a rejection, a decline, or a stack that asks for a
# circuit-switched retry the handset cannot complete (GOTCHAS 58).
#
# WHY IT CAPTURES WITH -b all
#
# The telephony framework logs through Rlog, which is the radio buffer. A default logcat has no
# ImsPhoneCallTracker, RILJ or ImsManager lines in it at all while still being full of Telecom
# traffic, so a broken build reads as a handler that was never called. GOTCHAS 57.
#
# The default number is in the NANP 555-01xx reserved range, which is never assigned to a
# subscriber. Pass --number only for a line you own; this places real calls.
set -uo pipefail

MODE=""; NUM="12125550100"; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    cancel|wait) MODE="$1" ;;
    --number) NUM="${2:?--number needs a value}"; shift ;;
    --log) LOG="${2:?--log needs a value}"; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "!! unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { echo "usage: ims-call-test.sh cancel|wait [--number N] [--log F]" >&2; exit 2; }

ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null 2>&1 || { echo "!! no adb on PATH (set ADB=/path/to/adb)" >&2; exit 2; }
[ -n "$LOG" ] || LOG="$(mktemp -t ims-call-XXXXXX.log)"

state=$($ADB get-state 2>/dev/null)
[ "$state" = device ] || { echo "!! adb state is '${state:-none}', need a booted device" >&2; exit 2; }

$ADB root >/dev/null 2>&1; sleep 2
$ADB wait-for-device

# An outgoing call does not ring, but a test that leaves the ringer up is a test nobody runs twice.
ring=$($ADB shell settings get system volume_ring 2>/dev/null | tr -d '\r')
[ "$ring" = 0 ] || echo ">> note: ring volume is '$ring', not 0"

echo ">> capturing to $LOG"
$ADB logcat -b all -c >/dev/null 2>&1
$ADB logcat -b all -v time > "$LOG" 2>/dev/null &
LOGPID=$!
trap 'kill $LOGPID 2>/dev/null' EXIT
sleep 1

echo ">> dialling $NUM ($MODE)"
$ADB shell am start -a android.intent.action.CALL -d "tel:$NUM" >/dev/null 2>&1

# Judge progress from the capture file, never from `adb shell logcat | grep`: adbd logs every shell
# request, so the pattern turns up in the log it is searching.
for i in $(seq 1 30); do
  sleep 1
  if grep -aq "to DISCONNECTED" "$LOG"; then echo ">> ended on its own after ${i}s"; break; fi
  if [ "$MODE" = cancel ] && grep -aq "to ALERTING" "$LOG"; then
    echo ">> reached ALERTING after ${i}s, ending the call"
    $ADB shell input keyevent KEYCODE_ENDCALL >/dev/null 2>&1
    break
  fi
done
if [ "$MODE" = cancel ] && ! grep -aq "to ALERTING" "$LOG"; then
  echo ">> never reached ALERTING, so the mPendingMO path was not exercised"
fi

sleep 12
kill $LOGPID 2>/dev/null; trap - EXIT

say() { printf '\n== %s\n' "$1"; }

say "reason the stack reported"
grep -a "callSessionStartFailed ::\|callSessionTerminated ::" "$LOG" \
  | grep -ao "reasonInfo=ImsReasonInfo :: {[^}]*}" | sed 's/^/   /'

say "what the bridge did with it"
grep -a "delivering as terminated\|cs retry" "$LOG" | cut -c1-160 | sed 's/^/   /'

say "what the framework handler did"
grep -a "ImsPhoneCallTracker" "$LOG" \
  | grep -a "onCallStartFailed\|onCallTerminated\|SilentRedial" | cut -c1-140 | sed 's/^/   /'

say "circuit-switched retry"
redial=$(grep -ac "MSG_REDIAL_CONNECTION_CHANGED\|initiateSilentRedial" "$LOG")
echo "   redial lines: $redial"
grep -ao "type:gsm state:[A-Z]*" "$LOG" | sort -u | sed 's/^/   /'
# A DIAL with no matching response is the modem accepting a call it has no network for. The framework
# then has nothing to disconnect and waits for good.
for tag in $(grep -ao "\[[0-9]\{4\}\]> DIAL" "$LOG" | grep -ao "[0-9]\{4\}" | sort -u); do
  if grep -aq "\[$tag\]<" "$LOG"; then echo "   DIAL $tag: answered"
  else echo "   DIAL $tag: NEVER ANSWERED by the modem"; fi
done

say "telecom transitions"
grep -ao "Update state from [A-Z]* to [A-Z]* for TC@[0-9_]*" "$LOG" | sed 's/^/   /'

say "verdict"
cs=$($ADB shell dumpsys telephony.registry 2>/dev/null | grep -m1 -oE 'mCallState=[0-9]+' | cut -d= -f2)
cs="${cs:-unknown}"
if [ "$cs" = 0 ] && grep -aq "to DISCONNECTED" "$LOG"; then
  echo "   PASS — reached DISCONNECTED and no call is left (mCallState=0)"
  exit 0
fi
echo "   FAIL — mCallState=$cs, DISCONNECTED $(grep -aq 'to DISCONNECTED' "$LOG" && echo reached || echo 'never reached')"
echo "   the call is still live; end it with: $ADB shell input keyevent KEYCODE_ENDCALL"
echo "   full capture: $LOG"
exit 1
