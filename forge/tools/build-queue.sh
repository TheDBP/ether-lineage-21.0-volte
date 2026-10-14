#!/bin/bash
# build-queue.sh — run several builds back to back, one at a time, unattended.
#
#   ./forge/tools/build-queue.sh <queue-file>
#   ./forge/tools/build-queue.sh -            # read the queue on stdin
#
# One build per line, blanks and # comments ignored:
#
#   <repo-dir> <preset> [extra-options]
#
#   ../vs995-24.0   stock
#   ../vs995-24.0   libre   ""
#   ../vs995-24.0   full    "root oem"
#   ../ether-20.0   full    "oem root"
#
# WHY THIS EXISTS
#
# Two AOSP builds on one machine is an OOM kill, so `run-one.sh` refuses to start when something else
# is building. That makes it safe and leaves the queueing to whoever is watching, which is no good
# overnight or across a run that takes hours. This waits for the machine to go idle before each
# build, so a list can be left to run.
#
# An empty extra-options field ("") is not the same as omitting it: it overrides a default set in
# device.conf.local, which is how a publishable build comes out of a checkout that normally adds
# `oem` or `root`. Quote it to pass several.
#
# STATUS, because a queue nobody can see is a queue nobody trusts
#
# One START and one DONE line per build, with the exit code and the forge's own tag line, appended to
# <queue-file>.status next to the queue (or ./build-queue.status for stdin). A failing build does not
# stop the queue: the rest still run and the summary at the end says which failed, since the usual
# reason for queueing is to come back to several finished artifacts.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
Q="${1:?usage: build-queue.sh <queue-file>|-}"

if [ "$Q" = - ]; then
  QUEUE="$(cat)"; STATUS="./build-queue.status"
else
  [ -r "$Q" ] || { echo "!! cannot read queue file: $Q" >&2; exit 2; }
  QUEUE="$(cat "$Q")"; STATUS="$Q.status"
fi

# Validate the whole queue before building anything. Discovering a typo in line four after two hours
# of building is the failure this avoids.
n=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  eval "set -- $line"
  d="${1:-}"
  [ -n "$d" ] || { echo "!! queue line has no repo: $line" >&2; exit 2; }
  [ -x "$d/bootstrap.sh" ] || { echo "!! not a device repo (no bootstrap.sh): $d" >&2; exit 2; }
  [ -n "${2:-}" ] || { echo "!! queue line has no preset: $line" >&2; exit 2; }
  n=$((n + 1))
done <<EOF
$QUEUE
EOF
[ "$n" -gt 0 ] || { echo "!! queue is empty" >&2; exit 2; }
echo ">> $n build(s) queued, status in $STATUS"
: > "$STATUS"

wait_idle() {
  local waited=0 busy
  while :; do
    busy=$(ps -eo pid,args --no-headers | awk -v me=$$ '$1!=me && /forge\/bootstrap\.sh/ && !/awk/' | wc -l)
    [ "$busy" = 0 ] && return 0
    [ "$waited" = 0 ] && echo "   waiting for the machine to go idle"
    waited=1
    sleep 30
  done
}

fails=0
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  eval "set -- $line"
  repo="$1"; preset="$2"; extra="${3-}"
  label="$(basename "$repo")-$preset$([ -n "$extra" ] && echo "-$(echo "$extra" | tr ' ' '-')")"
  log="$repo/build_output/queue-$label.log"

  wait_idle
  echo ">> building $label"
  echo "$(date '+%m-%d %H:%M') START $label" >> "$STATUS"
  if [ $# -ge 3 ]; then
    "$HERE/run-one.sh" "$repo" "$preset" "$extra" > "$log" 2>&1
  else
    "$HERE/run-one.sh" "$repo" "$preset" > "$log" 2>&1
  fi
  rc=$?
  tag=$(grep -ao "=== tag=.* exit: [0-9]* ===" "$log" | tail -1)
  echo "$(date '+%m-%d %H:%M') DONE  $label rc=$rc ${tag:-<no tag line, see $log>}" >> "$STATUS"
  [ "$rc" = 0 ] || { fails=$((fails + 1)); echo "   !! $label failed (rc=$rc), continuing; log: $log" >&2; }
done <<EOF
$QUEUE
EOF

echo "$(date '+%m-%d %H:%M') QUEUE COMPLETE, $fails failed of $n" >> "$STATUS"
echo ">> queue complete, $fails failed of $n"
[ "$fails" = 0 ]
