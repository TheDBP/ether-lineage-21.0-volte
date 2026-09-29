#!/usr/bin/env bash
# run-one.sh — build exactly one device, and refuse if anything else is already building.
#   ./forge/tools/run-one.sh <repo-dir> [PRESET] [EXTRA_OPTIONS]
#   ./forge/tools/run-one.sh ../bonito-22.2 libre nextcloud
#
# Two AOSP workloads on one machine is an OOM kill, and a bootstrap.sh left over from a previous
# run counts as one. Use this instead of calling bootstrap.sh directly when builds are queued or
# launched unattended: it checks first, writes a timestamped log under the device's build_output/,
# and prints one start and one finish line (with the exit code) for a queue or a watcher to read.
#
# PRESET and EXTRA_OPTIONS are passed through only when given, so device.conf and device.conf.local
# keep their defaults otherwise. Passing an empty EXTRA_OPTIONS ("") is not the same as omitting it:
# it overrides a default set in device.conf.local, which is how you get a publishable build from a
# checkout that normally adds oem.
set -u

D="${1:?usage: run-one.sh <repo-dir> [PRESET] [EXTRA_OPTIONS]}"
REPO="$(cd "$D" 2>/dev/null && pwd)" || { echo "!! no such directory: $D" >&2; exit 1; }
[ -x "$REPO/bootstrap.sh" ] || { echo "!! not a device repo (no bootstrap.sh): $REPO" >&2; exit 1; }

# Only aosp-* containers count: an unrelated container that happens to be up is not our build.
busy=$(ps -eo pid,args --no-headers | awk -v me=$$ '$1!=me && /forge\/bootstrap\.sh/ && !/awk/' | wc -l)
cont=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^aosp-' || true)
if [ "$busy" -gt 0 ] || [ "$cont" -gt 0 ]; then
  echo "!! refusing: $busy bootstrap process(es), $cont container(s) already running" >&2
  ps -eo pid,args --no-headers | awk -v me=$$ '$1!=me && /forge\/bootstrap\.sh/ && !/awk/' >&2
  docker ps --format '   {{.Names}} {{.Status}}' 2>/dev/null | grep '^   aosp-' >&2 || true
  exit 1
fi

NAME="$(basename "$REPO")"
mkdir -p "$REPO/build_output"
LOG="$REPO/build_output/${2:-build}-$(date +%Y%m%d-%H%M%S).log"
echo "=== $NAME  PRESET=${2-<device.conf>}  EXTRA_OPTIONS=${3-<device.conf.local>}  started $(date '+%F %T')"
echo "=== log: $LOG"
# Only set what was given: an omitted argument must leave device.conf's own default alone,
# while an empty string is a deliberate override of device.conf.local.
pass=()
[ "$#" -ge 2 ] && pass+=("PRESET=$2")
[ "$#" -ge 3 ] && pass+=("EXTRA_OPTIONS=$3")
( cd "$REPO" && env ${pass[@]+"${pass[@]}"} ./bootstrap.sh ) > "$LOG" 2>&1
RC=$?
echo "=== $NAME finished $(date '+%F %T') exit=$RC"
if [ "$RC" -ne 0 ]; then
  echo "--- FAILED targets ---"; grep -n 'FAILED:' "$LOG" | head -3 | cut -c1-200
  echo "--- errors ---"
  grep -nE 'error:|ninja: build stopped|^!!' "$LOG" | grep -viE 'warning' | head -10 | cut -c1-200
else
  ls -la "$REPO"/build_output/artifacts/*.zip 2>/dev/null | tail -1
fi
exit "$RC"
