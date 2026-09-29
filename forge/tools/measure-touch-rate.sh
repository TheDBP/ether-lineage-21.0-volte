#!/usr/bin/env bash
# Measure how fast the touchscreen actually reports, while a finger is down.
#
# The number that matters is the interval between SYN_REPORTs *within one contact*. Gaps between
# gestures are the user lifting a finger and mean nothing, so they are excluded by tracking
# ABS_MT_TRACKING_ID per slot. A healthy digitizer reports at 60-120 Hz; anything with a p90 past
# ~33 ms is dropping more than two frames' worth of finger positions and will feel like lag no
# matter how fast the renderer is.
#
# Point it at two phones to compare builds:
#   tools/measure-touch-rate.sh -s SERIAL_A -t 30
#   tools/measure-touch-rate.sh -s SERIAL_B -t 30
#
# Do not use injected input. `input swipe` goes through uinput and never touches the digitizer, so
# it measures nothing about the hardware and reports different numbers.
set -u
# Scratch goes under build_output/, never /tmp: on the build host that is a RAM tmpfs and the
# things these tools unpack (ROM zips, images, trees) fill it.
export TMPDIR="${BUILD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/build_output}/tmp"; mkdir -p "$TMPDIR"

SERIAL=""; SECS=30; DEV=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SERIAL="$2"; shift 2 ;;
    -t) SECS="$2"; shift 2 ;;
    -d) DEV="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ADB="adb"; [ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

$ADB get-state >/dev/null 2>&1 || { echo "!! no device (serial '${SERIAL:-any}')" >&2; exit 1; }
MODEL=$($ADB shell getprop ro.product.device 2>/dev/null | tr -d '\r')
BUILD=$($ADB shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')

# Find the touchscreen: the input device advertising multitouch position.
if [ -z "$DEV" ]; then
  DEV=$($ADB shell 'getevent -pl 2>/dev/null' | tr -d '\r' | awk '
    /^add device/ { d=$NF }
    /ABS_MT_POSITION_X/ { print d; exit }')
fi
[ -n "$DEV" ] || { echo "!! could not find a multitouch device; pass -d /dev/input/eventN" >&2; exit 1; }

echo "device : ${MODEL:-?}  ${BUILD:-?}"
echo "input  : $DEV"
echo
echo ">>> swipe and scroll CONTINUOUSLY for ${SECS}s, keeping your finger down <<<"

$ADB shell "rm -f /data/local/tmp/touchrate.log; \
            nohup timeout $((SECS + 3)) getevent -t $DEV > /data/local/tmp/touchrate.log 2>&1 &" >/dev/null 2>&1
sleep "$((SECS + 5))"

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT
$ADB shell 'cat /data/local/tmp/touchrate.log' 2>/dev/null | tr -d '\r' > "$TMP"
[ -s "$TMP" ] || { echo "!! captured nothing -- was the screen on and a finger on the glass?" >&2; exit 1; }

python3 - "$TMP" <<'PY'
import re, sys

# Per-slot tracking IDs: a contact is open while any slot holds a valid ID. Without the slot
# bookkeeping a second finger lifting looks like the whole gesture ending.
slot, ids, prev, ints, contacts, was = 0, {}, None, [], 0, False
for line in open(sys.argv[1]):
    m = re.match(r'\[\s*([0-9.]+)\]\s+(\S+)\s+(\S+)\s+(\S+)', line)
    if not m:
        continue
    t, typ, code, val = float(m.group(1)), m.group(2), m.group(3), m.group(4)
    if typ == '0003' and code == '002f':          # ABS_MT_SLOT
        slot = int(val, 16)
    elif typ == '0003' and code == '0039':        # ABS_MT_TRACKING_ID
        if val.lower() == 'ffffffff':
            ids.pop(slot, None)
        else:
            ids[slot] = val
    elif typ == '0000' and code == '0000':        # SYN_REPORT
        down = bool(ids)
        if down and not was:
            contacts += 1
            prev = t
        elif down and prev is not None:
            d = (t - prev) * 1000.0
            if 0 < d < 5000:
                ints.append(d)
            prev = t
        elif not down:
            prev = None
        was = down

if not ints:
    print("no in-contact intervals captured"); sys.exit(1)
ints.sort()
n = len(ints)
p = lambda q: ints[min(n - 1, int(n * q / 100))]
mean = sum(ints) / n
slow = sum(1 for x in ints if x > 33)
print(f"contacts          : {contacts}")
print(f"in-contact reports: {n}")
print(f"mean interval     : {mean:6.1f} ms   ->  {1000/mean:5.1f} Hz")
print(f"p50 / p90 / p95   : {p(50):6.1f} / {p(90):6.1f} / {p(95):6.1f} ms")
print(f"worst gap         : {ints[-1]:6.1f} ms")
print(f"intervals > 33 ms : {slow} ({slow*100.0/n:.1f}%)   <- each one is 2+ frames with no new position")
print()
verdict = "HEALTHY" if p(90) <= 33 else "DEGRADED"
print(f"verdict           : {verdict}  (p90 <= 33 ms is the bar)")
PY
