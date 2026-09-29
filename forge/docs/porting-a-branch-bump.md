# Porting a device to a newer LineageOS branch — order of operations

Written after the ether 18.1 -> 20.0 port (2026-09), where eleven build cycles surfaced eleven
causes one at a time, several of which were predictable before the first build.

## Do these BEFORE the first build

```sh
# 1. Which upstream gates silently exclude this SoC? Cheapest predictor there is.
./tools/check-platform-support.sh <NEW_SRC> device/<vendor>/<codename>

# 2. SELinux types the device references that the new branch deleted.
./tools/find-orphaned-sepolicy-types.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename>

# 3. C/C++ constants the new branch removed but the device tree still uses.
./tools/find-removed-platform-symbols.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename>

# 4. Soong namespaces the device must now import (and shadowing order), modules and HIDL libraries
#    the branch deleted -- including what the proprietary blobs are linked against -- and makefile
#    paths that moved. Each hit is one Soong analysis failure, ~20 min apiece on a 24.0 tree.
EXTRA_TREES="vendor/<vendor>/<sibling>" ./tools/find-soong-namespace-drift.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename> [<OLD_SRC>/device/<vendor>/<codename>]
```

Namespace fixes go in BOTH places: `PRODUCT_SOONG_NAMESPACES` in the device .mk and `imports:` in
the device `Android.bp`. Order matters when two namespaces define the same module name -- root and
namespace searches take the first match in list order.

Pre-5.10 kernel on lineage-24.0: the branch removed GCC-assisted kernel builds and their binutils
prebuilts. Check `patches/README.md` for the engine patch and the two manifest projects the device
must add; without them the first symptom is `media/msm_media_info.h: file not found` two hours into
the compile, not a kernel error.

Then build with `KEEP_GOING=true` and triage the whole error surface at once:

```sh
KEEP_GOING=true JOBS=<n> PRESET=clean ./forge/bootstrap.sh
./forge/tools/triage-build-log.sh build_output/logs/build.log
```

Fixing one error per 30-minute cycle is the default failure mode of a port. Don't.

## The kernel gate, once it builds

A userspace two or more releases newer than the kernel fails in init, one missing kernel feature at
a time, and each one looks the same from outside: nothing on USB, back in the bootloader. Take them
as a list, one backport per flash, and never find them with normal boots (each burns a slot retry
and, on bootloaders that hard-reset, leaves no log). Tools in `tools/README.md`, *Bringing a kernel
up*: `check-bpf-objects.py` first (static), `hybrid-bootimg.sh` + `init-harness.sh` for bionic →
`selinux_setup`, `dtbo-ramoops-alt.py` + `pstore-pull.sh` for `early-init` onwards,
`kernel-rebuild.sh --am` to get each patch onto hardware in 20 minutes. Known items for a 4.9 kernel
on Android 17 so far: `MADV_WIPEONFORK` (bionic aborts), the Android-only avtab M-compat shim
(`nlmsg` xperms), `cpuset_v2_mode` (libprocessgroup mounts cpuset with it, no fallback), then eBPF.

## The pattern that costs the most time

**A newer branch drops legacy platforms from a filter, and the failure never points at the filter.**

Seen twice in one port:

| Filter | Symptom |
|---|---|
| `QCOM_BOARD_PLATFORMS` (`qcom_boards.mk`) | Ten "non-existent modules in PRODUCT_PACKAGES" at the *end* of the parse. Bluetooth and the power HAL had been silently gated out by `$(call is-vendor-board-platform,QCOM)` returning false. Nothing errors where the gating happens. |
| `BOARD_SEPOLICY_M4DEFS` exclusion (`device/lineage/sepolicy/qcom/sepolicy.mk`) | `ERROR 'unknown type vendor_hal_perf_default_exec'` in a .te file that looks internally consistent. The m4 defs renamed the domain but not its `_exec` type, and `init_daemon_domain` derives `$1_exec` from the renamed name. |

> **Heuristic:** when something legacy breaks on a newer branch, `git diff` the same file between the
> old and new trees and check whether the old branch **special-cased this platform**. Treat that
> before treating the symptom.

Watch for the inverted form especially — `ifeq (,$(filter <list>,$(TARGET_BOARD_PLATFORM)))` runs
its block when the SoC is **absent**, so being missing from the list means the block **does** apply.

Note upstream is fixing this class: lineage-23.2 replaced the SoC list in that sepolicy gate with a
check on whether `BOARD_VENDOR_SEPOLICY_DIRS` contains a legacy dir — behaviour, not a hardcoded
list. Newer branches may not need the workaround.

## Check the old branch's output image, not your assumptions

When the new branch rejects a `PRODUCT_PACKAGES` entry, look for the artifact in the **old branch's
built image** before deciding what it was:

```sh
find <OLD_SRC>/out/target/product/<codename> -name 'Foo.apk' -o -name 'libfoo.so'
```

On the ether port this split ten rejected entries into four that were never built on the old branch
either (dead weight, safe to delete) and one that genuinely was (a real feature loss to record).
Same error message, opposite conclusions.

## Don't assume a patch is redundant because a file already has one

Two patches touching the same project are usually independent. On the ether port, `vendor/lineage`
needed four unrelated patches; one was dropped at promotion time as a "duplicate" of another and had
to be restored after it caused a build failure.

## Re-point BASE_REF when you rebranch

`device.conf` carries `BRANCH` *and* `BASE_REF`, and renaming the repo or bumping `BRANCH` does not
touch `BASE_REF`. Left stale it names a ref that exists in no project, so `refresh-patches.sh`
skips every one of them:

```
!! <project>: BASE_REF 'm/lineage-22.2' does not resolve in this project -- skipping
```

It prints that per project and exits 0, so the series silently stops being exported and every patch
has to be written by hand. Check both after any rebranch:

```
grep -E '^(BRANCH|BASE_REF)=' device.conf
git -C build_output/src/<any-project> rev-parse --verify "$BASE_REF"
```

## Env plumbing

Anything `_build_rom.sh` reads must be added in **two** places — `bootstrap.sh` hands the container
an explicit env list. Missing the second gives no error, just silently unset behaviour.
