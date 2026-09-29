# Gotchas

Rules, not stories. Numbers are stable — other docs cite them ("GOTCHAS 13").

Start with `README.md`; come here when a build fails in a way that makes no sense.

---

## 1. A script dies with no error message (SIGPIPE under `pipefail`)
`producer | grep -q` / `| head` SIGPIPEs the producer (exit 141); `pipefail` turns that into a silent,
size-dependent failure.

- Don't pipe into an early-exiting reader. Capture, then test: `x="$(producer)"; case "$x" in *N*)`
- Do use `n="$(producer | grep -c N || true)"` when you need a count.
- Newest file: `x="$(ls -t g 2>/dev/null || true)"; x="${x%%$'\n'*}"`
- Enforced by `tools/check-sigpipe.sh` and the pre-commit hook.

## 2. A module you added just isn't in the ROM
A module or `PRODUCT_COPY_FILES` referenced from an un-included makefile does not ship, with no error.

- Do verify new prebuilts land in the image, not just that the build passed.

## 3. The default wallpaper doesn't change
The drawable in an auto-generated framework-res RRO does not reliably reach the live wallpaper on
first boot.

- Do ship the image as a file and point `ro.config.wallpaper` at it. `WallpaperManager` reads the
  property before the drawable.

## 4. The ROM ships two of something
`out/target/product` keeps modules that are no longer in the install set, and the next build
repackages them.

- Do `installclean` when the module set changes. The config fingerprint in `_build_rom.sh` triggers it.

## 5. The boot animation plays in a small box on black
`desc.txt` declares the canvas size; the player centres it and never scales.

- Do match the first line to the device's panel resolution, and scale the frames to it -- a
  1080x1920 canvas on a 1440x2560 panel is the same box on black. The OEM extractor does both from
  the tree's `TARGET_SCREEN_WIDTH/HEIGHT`.

## 6. Image build fails on `useradd -u 1000`
Ubuntu 24.04 ships a default `ubuntu` user at uid/gid 1000.

- Do `userdel -r ubuntu` in the Dockerfile first.

## 7. Don't move a build step to the host
The container owns the toolchain. Host-side steps drift from it and break reproducibility.

## 8. A swapped-in Google app does nothing
NikGapps ships some apps as dex-less stubs.

- Do check the APK has classes.dex before treating it as a working replacement.

## 9. lineage-23.0 forces `LD=ld.lld` on kernels
23.0's `kernel.mk` sets `LD=ld.lld`; 22.2 set only `CC`. Any kernel with `CONFIG_LTO_CLANG=y`
(msm-4.9, msm8996) then fails to link.

## 10. `AUDIO_FEATURE_ENABLED_*` is dead
qcom audio reads soong config only.

- Don't set the old makefile variables and expect an effect.

## 11. Vendor blobs vs platform ABI at 23.0
Blobs built against an older platform ABI will not load.

- Do check the blob's expected ABI before assuming a branch bump is config-only.

## 12. Android 12 removed netd's no-eBPF fallback
A kernel without `bpf()` needs the fallback restored, or netd crash-loops.

## 13. A component validated on one device is not validated
The `linux` option and its kernel config fragments were verified on bonito (4.9) and then broke differently on
every other device. Each was a branch- or kernel-specific assumption from a single sample.

| assumption | reality |
|---|---|
| `TARGET_KERNEL_CONFIG_EXT` merges fragments | 23.0 only. On 22.2/19.1 `kernel.mk` never reads it — accepted and **silently ignored**. |
| kernel BoardConfig lives under `device/$DEVICE` | The V20 declares `TARGET_KERNEL_SOURCE` in `device/lge/msm8996-common`. |
| `make foo.config` merges a fragment | `%.config` is 3.18+. ether's 3.10 fails. Append `CONFIG_` lines to the base defconfig instead. |
| extra cgroup options are harmless | `HUGETLBFS`/`CGROUP_HUGETLB` break the vmlinux link on 3.10 arm64. |

- Do check the mechanism exists on the target branch before using it:
  ```sh
  grep -c 'ALL_KERNEL_DEFCONFIG_SRCS += $(KERNEL_DEFCONFIG_EXT)' vendor/lineage/build/tasks/kernel.mk
  grep -c '^%\.config:' <kernel>/scripts/kconfig/Makefile
  ```
- A silent no-op is the worst outcome available; it looks exactly like success.

## 14. Never regenerate patches from a tree apply-overlay has touched
`apply-overlay.sh` edits `BoardConfig.mk` in place, so regenerating bakes the forge's own build-time
edit into the series, which then re-applies forever. A patch generated on top of an earlier iteration
of itself also carries context that does not exist at `BASE_REF`.

- Don't regenerate from a dirty tree. `git status --porcelain` should show only build artifacts.
- Do check afterwards: `grep -rl 'forge_container\|added by rom-forge' overlay/patches/ | wc -l` must be 0.

## 15. `repo sync --force-sync` deletes anything that is not a manifest project
Vendored trees are pruned, and the build fails several stages later with something unrelated-looking
("no BoardConfig defines TARGET_KERNEL_SOURCE").

- Do declare them: `VENDORED_PROJECTS="vendored/device_nextbit_ether:device/nextbit/ether"`.

## 16. Reading build logs without fooling yourself
- Don't grep the whole `logs/sync.log` — it is appended across runs. Scope to the last `====` marker:
  `n=$(grep -n '^==== ' logs/sync.log | tail -1 | cut -d: -f1); sed -n "${n},\$p" logs/sync.log`
- Don't treat `sync failed at every parallelism level` as throttling. Two attempts one second apart is
  a parse error.
- Don't put `--` inside an XML comment. `repo sync` dies with "not well-formed".
- `error: refs/tags/cm-7.x does not point to a valid object!` from a `--reference` store is benign.
- Don't infer build state from log strings. The build is the container — `docker ps` is the only
  unambiguous signal.

## 17. Writing scripts that grep AOSP source
- Do force `LC_ALL=C`. `comm` silently drops entries when inputs were sorted under different collations.
- Do use `type[[:space:]]+`. Policy is hand-written and `type  foo, bar;` with two spaces occurs.
- Do allow hyphens in SELinux names — `thermal-engine`, `mm-pp-daemon`. `[a-z][a-zA-Z0-9_]+` splits
  them and produces both false negatives and phantom fragments.
- Do scan `*_contexts` as well as `.te`. A label in `file_contexts` fails the build even when no `.te`
  rule names the type.
- Don't use trailing `&&` under `set -e`. `[ -f x ] && grep ...` aborts the script with no output.
- Do ask "is it defined in a directory this device compiles?", not "is it in the tree?" `SEPolicy.mk`
  wires subtrees per SoC.
- Do check for missing `te_macros`. `checkpolicy` reports them as a bare `syntax error` naming the
  macro. Match unanchored and comment-stripped — calls are often indented inside `userdebug_or_eng()`.
- Do account for macro-declared symbols — `vendor_restricted_prop(vendor_mpctl_prop)`, not
  `type vendor_mpctl_prop;`. Grepping the literal form tempts a duplicate declaration.
- Do re-check "removed" symbols against a wider sweep. `ALOGE_IF` moved to `system/logging`;
  `PROT_READ` lives in bionic.
- Do report `$(filter $(UM_PLATFORMS),...)` as unknown. It cannot be resolved statically.
- Do key triage on the diagnostic text with paths and numbers stripped.
- Don't grep a build log for a marker that also appears in the echoed command line. Match
  `^MKA_RESULT=[0-9]`.

## 18. `refresh-patches.sh` direction
The tree is the source of truth; `overlay/patches/` is generated output.

- Don't edit a patch file by hand. The next refresh reverses it. Change the commit in the tree.
- The script exports to a temp dir and only swaps it in if the result is sane: some-patches-to-none is
  refused, any other reduction needs `--force`, `BASE_REF` must resolve and be an ancestor of HEAD.
  `--dry-run` shows the diff.

## 19. An option asset and a device patch fighting over one file
`git am` will not apply a patch that *adds* a file already sitting untracked in the tree.

- An option's `patches/` and `fetch.sh` run **before** device patches; its `assets.list`, `tree/` and
  `product.mk` run **after**. Overwriting a patched file is fine; racing to create it is not.

## 20. Removing a makefile block with a regex
`ifeq` blocks nest. A non-greedy regex ending at `\nendif\n` stops at the inner `endif` and orphans
the outer one: `device.mk:302: extraneous 'endif'`.

- Do count `ifeq`/`ifneq`/`ifdef`/`endif` depth.
- Don't treat "the series applies" as verification. Parse the result too.

## 21. `local a="$1" b="$a"` does not work
bash declares every name in a `local` statement — unsetting them — before assigning any, so `$a` on
the right is the new empty local.

- Do split into two statements.

## 22. A tree that builds is not a tree that can be built from scratch
`out/soong/.intermediates` can hold a stale artifact that hides a source file which cannot compile.

- Do rebuild from clean before believing a tree is good.

## 23. A prebuilt APK is in the image but the app is missing
`BUILD_PREBUILT` with `LOCAL_CERTIFICATE := PRESIGNED` rewrites the archive — it uncompresses every
embedded `.so` — and an APK Signature Scheme v2 signature covers the whole file, so the re-zip
invalidates it. PackageManager rejects the package during the boot scan and logs nothing. The build
succeeds; the app is simply absent. Fennec went from 127,545,689 bytes fetched to 242,684,607
installed this way.

- Do set `LOCAL_SDK_VERSION` alongside `PRESIGNED`. That selects `do_not_alter_apk`: copy, then check
  alignment only.
- Don't reach for Soong `preprocessed: true` instead — it does not exist on `android_app_import`
  before 14, and A13's `app_import` skips JNI uncompression only for testcases installs.
- Do compare the installed APK against the fetched one after a build. Any difference means it cannot
  install.
- On 14+ with `preprocessed: true`, Soong's `check_prebuilt_presigned_apk.py` fails
  `Contains compressed dex files and is privileged` for a priv-app whose dex is compressed, and
  `does not actually have any issues` if `skip_preprocessed_apk_checks` is set on one that passes.
  Set the flag from the APK's contents, never by hand (`fdroid_bp_module` does).

## 24. CPU hotplug against a userspace that assumes stable topology
This kernel deletes a CPU's entire `cpufreq/` directory when it goes offline. A `read()` of
`cpufreq/stats/time_in_state` already in flight then blocks in uninterruptible sleep until the
hotplug completes. BatteryStats reads exactly that file while holding its global lock, so the UI
stalls for seconds and the watchdog eventually SIGKILLs system_server. Android dropped hotplug
support years ago and assumes the topology is fixed.

- Don't let a thermal driver hotplug cores. Do mitigate by capping frequency, which thermal-engine
  already does.
- Do suspect a D-state thread holding a lock when the UI freezes while the CPU is idle. The watchdog
  log names the monitor and the holder.

## 25. Measuring touch means measuring the digitizer
`input swipe` goes through uinput and never reaches the touch controller. It reported 2.6% janky
frames where real fingers reported 15.6% on the same device.

- Do measure with real touches, and only inside one contact — track `ABS_MT_TRACKING_ID` per
  `ABS_MT_SLOT`, or a second finger lifting looks like the gesture ending.
- Do use `tools/measure-touch-rate.sh`, which does both.
- Don't read a bad result as hardware before checking the system was healthy when it was taken. A
  15 Hz reading turned out to be a wedged system, not a slow panel.

## 26. Counting occurrences is not checking support
`grep -c Preprocessed app_import.go` returned 2 on Android 13, which was read as "the property
exists". It does not — those matches were an internal field and a different module type. The build
then failed with `unrecognized property "preprocessed"`.

- Do check the property is in the exported struct, or just try it in a throwaway build.
- Don't count symbols and call it verification. The same mistake reads "8 `ic_sysbar_*` resources in
  SystemUI.apk" as "our icons won", when stock ships those same three names.

## 27. An RRO on a resource the target does not declare overlayable is silently dropped
Apps that ship `res/values/overlayable.xml` only let overlays touch the listed resources; anything
else is refused at idmap time (`STATE_NO_IDMAP`) and the build never says so. DocumentsUI's
`launcher_label` was overlaid for three branches and never took.

- Do check the target's `overlayable.xml` before writing an RRO, and on device `cmd overlay list`:
  `[x]` is live, `---` is refused (`cmd overlay dump <pkg>` for the state).
- Don't trust "the RRO built and is installed". Patch the string instead when it is not overlayable.

## 28. A changed TARGET_BOOTANIMATION does not rebuild the boot animation
`vendor/lineage/bootanimation`'s genrule gets the prebuilt path as a soong_config string and runs a
bare `cp`; the file is not a declared input, so ninja reuses the previous `bootanimation.zip`
forever. A rescaled OEM animation shipped at the old size while the extractor log said "scaled".

- Do verify from the image: `unzip -p out/.../system/product/media/bootanimation.zip desc.txt`
  must show the panel size. The extractor log only proves the asset was written.
- The `oem` option's `post-patch.sh` drops the genrule outputs every build so the copy re-runs.

## 29. init's updatable-crash path is what actually reboots a vendor device

A vendor service that exits badly five times before `sys.boot_completed` makes init set
`sys.init.updatable_crashing`, and apexd answers that with "Native process '<name>' is crashing.
Attempting a revert" and reboots. After boot the same counter applies inside a four-minute window,
so a service that dies every ~40 s keeps rebooting a *booted* phone. The service need not be
important; it needs to exit non-zero.

Rank restarts before blaming the loudest crash:

```
grep "init: starting service" logcat | sed "s/.*service '\([^']*\)'.*/\1/" | sort | uniq -c | sort -rn
```

The top entries are the boot killers; a tombstone count will point you at a different, innocent
process. `oneshot` in the service's .rc stops init restarting it, which keeps the counter at one
and lets a device boot so you can debug the crash on a live system instead of in a reboot loop.

## 30. One symptom, several stacked causes

`bpf.progs_loaded` had four independent breakages behind each other on a 4.9 kernel, each hiding
the next, every one presenting identically: the health HAL blocked in `HealthLoop::UeventInit()`,
so BatteryService hung in `IHealth.registerCallback()` and the watchdog killed system_server at 66 s
with only "Blocked in handler on main thread" to show for it.

Fixing one and seeing no change does not mean the fix was wrong. Re-measure the *mechanism*
(here: is the property set?) rather than the symptom, or you will revert good work.

Anything calling `bpf::waitForProgsLoaded()` blocks forever until that property is set, and the
property is only set by the last link of netbpfload -> uprobestatsbpfload -> platform bpfloader ->
netbpfload "done". Any break in that chain hangs unrelated subsystems.

## 31. A guard written after the call that aborts is dead code

```c
auto map = bpf::BpfMapRO<uint64_t, uint64_t>(path);
if (!map.isValid()) { LOG(ERROR) << ...; return false; }   // never runs
```

`BpfMapRO`'s constructor `Abort()`s when the map is not pinned, so the author's graceful path can
never execute. Check the pin path with `access()` first. The same shape shows up wherever a
constructor validates: the object aborts before anyone can ask whether it is valid.

## 32. Regenerating a patch file does not update the live tree

`overlay/patches/` is what a fresh bootstrap applies; `build_output/src/` is what incremental
builds compile. Rewriting a patch leaves the tree on the old version, and the two drift silently —
you can test a build for days that a fresh bootstrap would never reproduce.

After changing a patch, resync the project: back up any uncommitted forge-option edits
(`BoardConfigLineage.mk`), `git reset --hard <base>`, `git am overlay/patches/<project>/*.patch`,
restore the backup. Then the tree and the series agree.

---

## 33. GApps installs but Play Services does not exist (APEX payload is EROFS)
SetupWizard hangs on "Just a sec" forever; `SecurityException: Failed to find provider
com.google.android.gsf.gservices`; Google processes crash-loop. Play Store, GSF and SetupWizard are
all installed, so it does not look like a packaging problem.

```
apexd: Mounting failed for package /product/apex/com.google.android.gmssystem.prodvic.apex: No such device
```

"No such device" is `ENODEV` — the kernel does not know the filesystem. Android 15+ builds APEX
payloads as **EROFS**, and MindTheGapps ships GmsCore only inside that apex. A kernel without
`CONFIG_EROFS_FS` cannot mount it, the apex never activates, and everything inside it is absent at
runtime with no further symptom.

Only **prebuilt** apexes are affected: apexes the tree builds itself use the platform payload type,
so on such a device 90 of them mount and exactly one fails. Check the payload magic, not the name:

```sh
unzip -p <apex> apex_payload.img | dd bs=1 skip=1024 count=4 2>/dev/null | od -An -tx1   # e2e1f5e0 = EROFS
adb shell 'grep -c apex /proc/mounts'      # how many actually mounted
```

Do not read `ls /apex` as shell to count them — it returns nothing without permission and reads as
zero. `/proc/mounts` is the honest source.

Fix: `APEX_EROFS_UNSUPPORTED=true` in `device.conf` (needs `KEYS_DIR` and
`tools/make-apex-key.sh`), which repacks the payload as ext4 and re-signs. The general fix is
backporting EROFS to the kernel.

Two traps in the repack itself, both of which produce an apex that signs and verifies and still
will not mount:

- **Sign with `signapk -a 4096 --align-file-size`, never `apksigner`.** apexd loop-mounts
  `apex_payload.img` straight out of the zip, so its data must start on a 4096-byte boundary.
  apksigner rewrites the zip and leaves it wherever. The symptom is only `Invalid argument` from
  apexd; the real cause is in the kernel log — `blk_update_request: I/O error, dev loopN, sector 2`
  then `EXT4-fs (loopN): unable to read superblock`. Running `zipalign` first does not help,
  because signing undoes it. `signapk` needs `LD_LIBRARY_PATH=out/host/linux-x86/lib64` or it dies
  loading conscrypt.
- **ext4 is not compressed and EROFS is.** The payload grows — 146.5 MB to 206 MB for GmsCore —
  so `/product` grows with it and `check_partition_sizes` can fail the build outright. Budget for
  it before repacking.

When comparing a broken apex against a reference, compare against one that MOUNTS, not against the
original prebuilt: on such a device the original is broken too, so it agrees with your broken copy
and "proves" the wrong thing.
