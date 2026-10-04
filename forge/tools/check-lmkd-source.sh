#!/usr/bin/env bash
# check-lmkd-source.sh — does this kernel give lmkd a memory-pressure source it can actually use?
#
#   check-lmkd-source.sh <kernel .config or defconfig> [<cgroups.json>] [<kernel source dir>]
#
# Android 16+ lmkd (system/memory/lmkd) has exactly two modes: PSI monitors (CONFIG_PSI) or the
# in-kernel lowmemorykiller module (CONFIG_ANDROID_LOW_MEMORY_KILLER, read through
# /sys/module/lowmemorykiller/parameters/minfree). The vmpressure fallback older lmkd used on
# pre-4.20 kernels is gone, and the platform cgroups.json now puts the memory controller in cgroup2,
# so the "old kill strategy" path is unreachable even where memcg v1 exists. With neither option the
# daemon exits at startup:
#
#   lowmemorykiller: Old kill strategy can only be used with v1 cgroup hierarchy
#   lowmemorykiller: Failed to initialize PSI monitors
#   lowmemorykiller: exiting
#
# and the damage is indirect: init restarts it forever, /dev/socket/lmkd never appears, every
# ProcessList.writeLmkd() in system_server blocks 3 s under the AMS lock, ANRs cascade through
# systemui/phone/nfc/networkstack, and the network stack's death kills system_server with
# "IllegalStateException: Lost network stack" every ~80 s. Nothing in that log says "kernel config".
#
# On a 4.4/4.9 kernel without a PSI backport the fix is one defconfig line:
# CONFIG_ANDROID_LOW_MEMORY_KILLER=y (drivers/staging/android/lowmemorykiller.c, present on every
# Android kernel up to 4.14). Run this against the built .config (out/.../KERNEL_OBJ/.config) rather
# than the defconfig when both exist: fragments and `make olddefconfig` can flip either option.
set -u
CFG="${1:?usage: check-lmkd-source.sh <kernel .config|defconfig> [<cgroups.json>] [<kernel src>]}"
CGJ="${2:-}"; KSRC="${3:-}"
[ -f "$CFG" ] || { echo "!! no such config: $CFG" >&2; exit 2; }

on() { grep -qE "^$1=y" "$CFG"; }
rc=0
if on CONFIG_PSI; then
  if on CONFIG_PSI_DEFAULT_DISABLED; then
    echo "   PSI built but CONFIG_PSI_DEFAULT_DISABLED=y: lmkd only gets it with psi=1 in BOARD_KERNEL_CMDLINE"
  else
    echo "   PSI: CONFIG_PSI=y -- lmkd will use PSI monitors"
  fi
elif on CONFIG_ANDROID_LOW_MEMORY_KILLER; then
  echo "   in-kernel LMK: CONFIG_ANDROID_LOW_MEMORY_KILLER=y -- lmkd will use /sys/module/lowmemorykiller"
  echo "   (expect one lmkd exit after dev.bootcomplete when AMS sends LMK_START_MONITORING; init restarts it)"
else
  echo "!! neither CONFIG_PSI nor CONFIG_ANDROID_LOW_MEMORY_KILLER is set: Android 16+ lmkd exits at startup"
  rc=1
  if [ -n "$CGJ" ] && [ -f "$CGJ" ]; then
    mpath=$(python3 - "$CGJ" <<'PY' 2>/dev/null
import json,sys
j=json.load(open(sys.argv[1]))
for c in j.get("Cgroups",[]):
    if c.get("Controller")=="memory": print("v1 "+c.get("Path","")); break
else:
    c2=j.get("Cgroups2",{})
    if "memory" in c2.get("Controllers",[]) or any(x.get("Controller")=="memory" for x in c2.get("Controllers",[]) if isinstance(x,dict)):
        print("v2 "+c2.get("Path",""))
PY
)
    case "$mpath" in
      v1*) echo "   cgroups.json mounts memcg v1 at ${mpath#v1 }: only lmkd <= Android 15 (vmpressure fallback) can use that" ;;
      v2*) echo "   cgroups.json puts memory in cgroup2 at ${mpath#v2 }: the vmpressure/'old kill strategy' path is unreachable" ;;
      *)   echo "   cgroups.json: no memory controller at all" ;;
    esac
  fi
  if [ -n "$KSRC" ]; then
    [ -f "$KSRC/kernel/sched/psi.c" ] && echo "   kernel has kernel/sched/psi.c: set CONFIG_PSI=y" \
      || echo "   kernel has no kernel/sched/psi.c (PSI landed in 4.20)"
    [ -f "$KSRC/drivers/staging/android/lowmemorykiller.c" ] && echo "   kernel has drivers/staging/android/lowmemorykiller.c: set CONFIG_ANDROID_LOW_MEMORY_KILLER=y" \
      || echo "   kernel has no lowmemorykiller.c (dropped in 4.19): PSI backport is the only route"
  fi
fi
echo ">> check-lmkd-source: $( [ $rc = 0 ] && echo ok || echo 'no usable pressure source')"
exit $rc
