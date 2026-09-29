# Debugging a boot loop

A port that hangs on the boot animation and reboots itself is a `system_server` crash loop.

## Order

1. Boot to recovery, pull `/data/tombstones`. **Not pstore.**
2. Only if that is empty, pull `console-ramoops-0` and `pmsg-ramoops-0`.
3. If pmsg has no tombstone and no Java `FATAL EXCEPTION`, stop reading logs and get live adb.

## Tombstones first

| | `/data/tombstones` | pmsg-ramoops |
|---|---|---|
| Survives cold power-off | yes | **no** |
| Loses the first crash | no | **yes, quickly** |
| Names faulting library and function | **yes** | only if the record survived |
| Holds every crash of every process | **yes** | last few seconds only |

From TWRP, where adb needs no authorisation:

```sh
adb shell mount /data
adb pull /data/tombstones ./diag/
```

Census before reading any single one:

```sh
for f in tombstone_[0-9]*; do case "$f" in *.pb) continue;; esac
  echo "$(grep -aoE '^signal [0-9]+ \([A-Z]+\)' "$f" | head -1) | $(grep -aoE '^Cmdline: .*' "$f" | head -1)"
done | sort | uniq -c | sort -rn
```

## Nothing reaches the boot animation

That is a different problem from a loop: init dies before `zygote`. USB never enumerates, and on a
device whose bootloader hard-resets and rewrites the ramoops region on every boot, pstore is empty.
The order there is `tools/init-harness.sh` (bionic → `selinux_setup`, from recovery, no boot), then
`tools/dtbo-ramoops-alt.py` + `tools/pstore-pull.sh` for `early-init` onwards (cgroups,
`apexd-bootstrap` — its `reboot_on_failure` is a clean `reboot bootloader` ~10 s in, with nothing
on USB and nothing in klog). Read init's `Command '...' failed:` line, not the `exited with status`
line after it: "failed to start due to a fatal error" is the forked child giving up before exec.
`tools/README.md`, *Bringing a kernel up*.

Stuck on the OEM logo with no USB, and the console ring shows services restarting, is the next
stage: init is fine, userspace aborts. The reasons are not in kmsg. Read `pmsg-ramoops-0` from the
same pull (`pstore-pull.sh` decodes it): it is the last boot's logcat, tombstones included, and
the phone has no adb to `logcat -L` with. Several vendor HALs failing on `Permission denied` for
their `/dev` nodes with no `avc:` line anywhere is DAC, i.e. ueventd never applied the vendor
rules — Android 17 reads `/system/etc/ueventd.rc` only, and the vendor file has to be at
`/vendor/etc/ueventd.rc` for its `import` (system/core `1b926a344` dropped the legacy
`/vendor/ueventd.rc` path that pre-T `first_api_level` devices were still using).

## Why pstore misleads

pstore survives a reboot but not a cold power-off, and the pmsg ring is 256K–512K
(`android,ramoops-pmsg-size`). A loop wraps it many times, so what remains is the tail of the last
cycle — real-looking errors, none causal.

- Don't conclude from a logged exception that it was thrown. `getServiceOrThrow` appears in the stack
  trace of a caught-and-logged warning exactly as it does in a crash. Read the AOSP source.
- Don't chase `zygote received signal 9`. `SigChldHandler` has zygote SIGKILL *itself* when
  system_server dies. One per loop iteration is expected and says only that system_server died.
- Don't chase a restarting service nothing binds to.

## Live adb instead

`adbd` and `logd` do not depend on `system_server`, so they run through the loop.

**First check USB adb can work on this kernel.** adbd drives FunctionFS with AIO, which arrived in
Linux 3.15. Older kernels return `EINVAL` and the host sees a device stuck `offline`:

```sh
grep -A12 'ffs_epfile_operations' <kernel>/drivers/usb/gadget/f_fs.c   # no .aio_read/.aio_write = impossible
```

AOSP removed the blocking fallback when adb became a mainline module, so there is no property to
flip — backport FFS AIO, or restore a blocking path in adbd.

**Wireless adb is unaffected** — plain TCP, never touches FunctionFS. On an old-kernel device it is
the cheaper route, but networking has to work first.

If USB adb is viable, two things block it: `sys.usb.config` stays `none` until the framework sets
it, and on `userdebug` `ro.adb.secure=1` needs a prompt the framework never draws. The `bringup`
option (`forge/options/bringup/`) clears both from the build config — `WITH_ADB_INSECURE` (adb.secure
0, device stays debuggable, adb on USB from init) and `persist.logd.logpersistd=logcatd` (every
buffer kept under `/data/misc/logd/`, `adb shell logpersist.cat` to read it). Enable it per build
with `EXTRA_OPTIONS="bringup"` in `device.conf.local`; the tag gains `-bringup`.

Don't use `PRODUCT_ADB_KEYS` instead. It puts a personal `adbkey.pub` (`user@host` inside) in the
repo, and it is redundant once `ro.adb.secure=0`.

> An image built with `bringup` accepts adb from any host. Never distribute one.

```sh
adb wait-for-device logcat -b all > loop.txt
```

## More pmsg ring, if needed

Rebalance the existing reservation rather than touching the memory map:

```
buffer-size 0x200000 = console 0x100000 + ftrace 0x10000 + pmsg 0x80000 + <dump records>
```

- Do move slack from dump records to pmsg. `console-ramoops` already has the kernel state.
- Don't set a zone to `0` on pre-4.x kernels. Shrink it instead.

## Once you can see

1. Native crash in system_server (tombstone) — the real answer if present
2. Uncaught Java exception during a boot phase
3. A HAL blocking `getService()` forever — `tools/check-hal-readiness.sh`
4. Watchdog kill (60 s; find the blocked lock)

Everything else is noise until those four are clear.
