#!/usr/bin/env bash
# qmi-sec-check.sh -- find QMI services a device uses that its IPC-router security config does not
# grant, the cause of "QMI works for everything except this one vendor service".
#
#   qmi-sec-check.sh [-s SERIAL]                       # live device: dmesg + logcat + its sec_config
#   qmi-sec-check.sh --config <sec_config> --svc 703   # offline: is one service covered?
#   qmi-sec-check.sh --config device/<oem>/<soc>/configs/permissions/sec_config --list
#
# On a QTI SoC the kernel's MSM IPC router gates every QMI service by GID: irsc_util feeds it
# sec_config at boot, and a service with NO rule is reachable only by root. A vendor stack running
# as radio/system then fails on exactly one service while all the others work -- and the failure is
# reported nowhere useful. Seen on the LG V20: LG's own sec_config granted services 1-511, 704 and
# 4097 but omitted 703 (lge_ims), the service LG's own IMS media stack needs to create the modem
# voice session, so VoLTE calls connected and were silent.
#
# What it reads:
#   dmesg   "IPC_RTR: msm_ipc_router_send_to: permission failure for <thread>"  <- the kernel's own
#           verdict, and the only unambiguous signal. No line here means look elsewhere.
#   logcat  "Error sending TXN: svc_id: <N>"  /  "xport_send: Sendto failed"    <- names the service
#   sec_config  "<service>:<instance>:<gid>[:<gid>...]", instance 4294967295 = all
#
# ORDERING TRAP: the router binds a rule to a service when the service REGISTERS. Running irsc_util
# after boot therefore changes nothing for services the modem already registered -- it looks like
# the rule did not help. The rule has to be in the file init reads before the modem comes up.
set -uo pipefail
SER=""; CONFIG=""; SVC=""; LIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SER="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --svc) SVC="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "!! unknown arg $1" >&2; exit 2 ;;
  esac
done
ADB=(adb); [ -n "$SER" ] && ADB=(adb -s "$SER")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [ -z "$CONFIG" ]; then
  for p in /vendor/etc/sec_config /etc/sec_config /system/etc/sec_config; do
    if "${ADB[@]}" shell "[ -f $p ]" 2>/dev/null; then
      "${ADB[@]}" pull "$p" "$TMP/sec_config" >/dev/null 2>&1 && CONFIG="$TMP/sec_config" && echo ">> sec_config from device: $p" && break
    fi
  done
  [ -n "$CONFIG" ] || { echo "!! no sec_config on the device and none given with --config"; exit 1; }
fi
[ -f "$CONFIG" ] || { echo "!! no such file: $CONFIG"; exit 1; }

# rules: service id -> gid list
rule_for(){ grep -E "^[[:space:]]*$1:" "$CONFIG" | head -1; }
ids=$(grep -oE '^[[:space:]]*[0-9]+:' "$CONFIG" | tr -d ' :' | sort -n -u)
echo ">> $(echo "$ids" | grep -c .) service(s) have a rule"

if [ "$LIST" = 1 ]; then echo "$ids" | tr '\n' ' '; echo; exit 0; fi

if [ -n "$SVC" ]; then
  r=$(rule_for "$SVC")
  if [ -n "$r" ]; then echo "OK  service $SVC is granted: $r"; exit 0; fi
  echo "!! service $SVC has NO rule -- only root may reach it. Add to $CONFIG:"
  echo "   $SVC:4294967295:1000:1001:3004     /* system, radio, net_raw */"
  exit 1
fi

# live device: who is being denied, and for which service
echo ">> kernel IPC-router denials:"
den=$("${ADB[@]}" shell 'dmesg 2>/dev/null | grep -i "IPC_RTR.*permission failure"' 2>/dev/null | tail -5)
[ -n "$den" ] && echo "$den" | sed 's/^/   /' || echo "   none (if QMI still fails, it is not this)"
echo ">> services named in failed transactions:"
svcs=$("${ADB[@]}" shell 'logcat -b all -d 2>/dev/null | grep -oE "svc_id: [0-9]+"' 2>/dev/null | awk '{print $2}' | sort -n -u)
if [ -z "$svcs" ]; then
  echo "   none in the current log buffer (reproduce the failure, then re-run)"
else
  bad=0
  for s in $svcs; do
    r=$(rule_for "$s")
    if [ -n "$r" ]; then echo "   OK  svc $s granted: $r"
    else echo "   !!  svc $s has NO rule -- add: $s:4294967295:1000:1001:3004"; bad=1; fi
  done
  [ "$bad" = 1 ] && echo ">> remember: add it to the sec_config init feeds irsc_util at BOOT; a later irsc_util run will not help services already registered"
fi
