#!/usr/bin/env bash
# blob-attach.sh — start a vendor binary under lldb-server and print the load base of one of its
# libraries, so you can set absolute breakpoints inside a stripped prebuilt.
#
#   blob-attach.sh <device-binary> <library-soname> [--port N] [-s SERIAL]
#
#   blob-attach.sh /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64 camera.sdm710.so
#
# Prints BASE=<hex> PID=<n>, leaves lldb-server listening, and forwards the port. Then, on the
# host, with the same library copied locally so lldb can read its symbols:
#
#   lldb.sh -b -o 'gdb-remote localhost:5039' \
#           -o 'breakpoint set -a 0x<BASE + file offset>' -o continue -o 'register read x0 x2'
#
# Needs root and permissive SELinux on the device, and lldb-server pushed to /data/local/tmp
# (aarch64 one lives in prebuilts/clang/kernel/linux-x86/clang-*/runtimes_ndk_cxx/aarch64/).
#
# Why the base has to be read at runtime: lldb's gdbserver mode does not track shared libraries,
# so symbolic and pending breakpoints never resolve, and bionic's linker randomises .so bases
# regardless of kernel.randomize_va_space. Absolute addresses are the only thing that works, and
# they change every run.
set -u

BIN="${1:?usage: blob-attach.sh <device-binary> <library-soname> [--port N] [-s SERIAL]}"
LIB="${2:?usage: blob-attach.sh <device-binary> <library-soname> [--port N] [-s SERIAL]}"
shift 2
PORT=5039; S=()
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    -s)     S=(-s "$2"); shift 2 ;;
    *) echo "!! unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADB=(adb "${S[@]+"${S[@]}"}")
"${ADB[@]}" shell 'id' 2>/dev/null | grep -q 'uid=0' || {
  echo "!! need adb root (enable rooted debugging in Developer options, then 'adb root')" >&2; exit 1; }
"${ADB[@]}" shell '[ -x /data/local/tmp/lldb-server ]' 2>/dev/null || {
  echo "!! push an aarch64 lldb-server to /data/local/tmp first" >&2; exit 1; }

"${ADB[@]}" shell 'setenforce 0' 2>/dev/null
"${ADB[@]}" forward "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1

# Kill stale instances first. A second copy of the binary silently gives a base that does not
# belong to the process lldb attaches to, and every breakpoint then misses for no visible reason.
cat > /tmp/.blob-attach-$$.sh <<EOF
killall $(basename "$BIN") 2>/dev/null
sleep 1
$BIN &
P=\$!
for i in \$(seq 1 300); do
  B=\$(grep -m1 $LIB /proc/\$P/maps 2>/dev/null | cut -d- -f1)
  if [ -n "\$B" ]; then break; fi
done
A=no; if [ -d /proc/\$P ]; then A=yes; fi
echo "BASE=\$B PID=\$P ALIVE=\$A"
/data/local/tmp/lldb-server gdbserver :$PORT --attach \$P
EOF
"${ADB[@]}" push /tmp/.blob-attach-$$.sh /data/local/tmp/blob-attach.sh >/dev/null 2>&1
rm -f /tmp/.blob-attach-$$.sh
"${ADB[@]}" shell 'chmod 755 /data/local/tmp/blob-attach.sh' 2>/dev/null

LOG=$(mktemp -u "${TMPDIR:-.}/blob-attach.XXXXXX.log")
setsid nohup "${ADB[@]}" shell 'sh /data/local/tmp/blob-attach.sh' > "$LOG" 2>&1 &
for _ in $(seq 1 30); do grep -q 'BASE=' "$LOG" 2>/dev/null && break; sleep 1; done

line=$(grep -o 'BASE=[0-9a-f]* PID=[0-9]* ALIVE=[a-z]*' "$LOG" | tail -1)
[ -n "$line" ] || { echo "!! never saw the library mapped; is the soname right?" >&2; tail -3 "$LOG" >&2; exit 1; }
echo "$line"
case "$line" in *ALIVE=no*) echo "!! the process died before attach; it may crash faster than the poll" >&2 ;; esac
echo ">> lldb-server listening on :$PORT, log $LOG"
echo ">> sanity check: base should equal (crash pc - file offset of the crashing instruction)"
