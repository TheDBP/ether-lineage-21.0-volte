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
- Enforced by `tools/check-sigpipe.sh`, which the pre-commit hook runs when a shell file is
  staged. Hooks are not version-controlled, so a fresh clone has none: run
  `tools/install-hooks.sh` once per clone or the guard is not running at all.

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
  SystemUI.apk" as a win for the replacement icons, when stock ships those same three names.

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

## 34. `timeout` on the docker wrapper kills the wrapper, not the build

`timeout 590 ./forge/docker/aosp.sh ...` exits 143 on the host and the container keeps building: the
signal reaches `docker run`'s client, not the process inside. A preflight that "timed out" is still
holding the tree and `out/`, and the next build you start races it. Wait on `docker ps` to drop the
container (or `docker stop` it) before touching the tree; never read a host `timeout` as the build
having stopped.

## 35. Disassembling a stripped 32-bit ARM blob without saying which instruction set

A stripped vendor `.so` has no `$a`/`$t` mapping symbols, so `llvm-objdump -d` picks ARM and decodes
Thumb code into *plausible garbage*: no call sites, branch targets into the middle of unrelated
symbols, stray `svclt`/`blls`. It does not warn, and the output looks like a disassembly, so you
conclude the blob never calls the thing you were looking for. Decode both ways
(`--triple=thumbv7-linux-android`, `--triple=armv7-linux-android`) and keep whichever actually
resolves calls -- `blob-log-tags.py` does this. Forcing the wrong one can also abort llvm-objdump
outright (`LLVM ERROR: tBcc: expected 3 operands`), which is an answer about the triple, not a
broken file. Also remember 32-bit vendor code is usually PIC: a literal is a pc-relative *offset*
followed by `add rN, pc`, so resolving an address means applying the pc bias (+8 ARM, +4 from the
word-aligned address in Thumb), not reading the literal directly.

## 36. A legacy blob in a shared UID gets modern compat behaviour

`CompatChanges.isChangeEnabled(change, uid)` is evaluated per **UID**, and for a shared UID it is
true if the change is enabled for ANY package in it. So a 2016 blob declaring
`sharedUserId="android.uid.system"` inherits every targetSdk-gated behaviour change from the modern
platform apps it shares with, and its own `targetSdkVersion` buys it nothing. Seen on the V20: LG's
`UnifiedSettingsApp` (targetSdk 26) died on the Android 14 `RECEIVER_EXPORTED` requirement
(`@EnabledSince(UPSIDE_DOWN_CAKE)`), which should not apply to it at all.

Pair that with `android:persistent="true"` and one bug becomes an infinite loop: init restarts the
app forever, so a single `registerReceiver` throw produced 86 crashes per boot, waking the screen and
burying real crashes in the log. When triaging a crash-looping OEM blob, check `sharedUserId` and
`persistent` in its manifest before its code -- and check whether anything needs it at all, since a
blob list generated from a stock dump carries carrier apps the port will never use.

## 37. A pre-Treble OEM binary from /system/bin that links vendor libs

Stock ROMs from before Treble put everything in `/system`, so an OEM daemon living in
`/system/bin` happily linked `/system/vendor/lib64`. Restage it at the same path on a Treble build
and the linker refuses:

    CANNOT LINK EXECUTABLE "/system/bin/<daemon>": library "libqmi_client_qmux.so" not found

The library is present -- a `/system/bin` executable runs in the *system* linker namespace, which
cannot see `/vendor/lib64`. Put anything that links vendor libs in `/vendor/bin` (where the SoC's
own daemons already live), not where stock had it. Check with `llvm-readelf -d <bin> | grep NEEDED`
and resolve each against both namespaces before assuming a library is missing.

Two more traps in the same restage:
- **init cannot exec a plain `vendor_file`.** `avc: denied { execute } ... comm="init"` then
  `cannot execv(...): Permission denied`. An init service's binary needs an `exec_type` label and a
  domain; until the policy exists, test by running it from a root shell (`u:r:su:s0` is permissive
  on userdebug) rather than from init, or pin `seclabel u:r:su:s0` in the rc.
- **init parses rc files only at boot.** Editing `/system/etc/init/*.rc` and running
  `start <svc>` reuses the old definition; reboot or you will debug a path you already fixed.
- **A stock image ships both ABIs.** `/vendor/lib` and `/vendor/lib64` hold same-named libraries;
  extracting the wrong one gives `is 32-bit instead of 64-bit` at link time. Match the daemon:
  `file -b` on both before pushing.

## 38. One `allowxperm` turns that whole domain/class into a whitelist

`allow <domain> <target>:<class> ioctl;` permits every ioctl. Add a single
`allowxperm <domain> <target>:<class> ioctl { 0xNNNN };` and the kernel switches that
domain/class pair to whitelist mode: the one command you named is allowed and **every other ioctl
is now denied**. Tightening one call therefore silently removes all the others.

Seen on the V20 moving the IMS stack off `permissive radio`. The permissive audit showed
`ioctlcmd=c304` on the QMI socket, so the rule named `0xc304` -- and the first enforcing boot denied
`0xc302`, which the same QMI path also uses. The symptom was not an obvious failure: calls still
connected, registration still worked, and audio was silent, because the denied ioctl broke the query
that sets up the modem's voice session. Fixed by allowing the whole `0xc300-0xc30f` IPC-router
family.

Two lessons that generalise:
- When you must add an xperm rule, allow the **family** the driver uses, not the one command you
  happened to observe. A permissive-boot audit can only log the ioctls that were actually issued in
  that run, so the list is a lower bound, never the set.
- A permissive audit cannot reveal this class of bug at all: whitelist mode does not exist until
  your rule does. Budget one enforcing boot to find what the audit structurally could not.


## 39. A CarrierConfig key is not what decides whether IMS features are offered

`persist.dbg.volte_avail_ovr`, `persist.dbg.vt_avail_ovr` and `persist.dbg.wfc_avail_ovr` are read
FIRST by `ImsManager.is{Volte,Vt,Wfc}EnabledByPlatform()`, and a value of `1` makes each return true
outright -- `config_device_*_available` and the matching `carrier_*_available_bool` are never
consulted. Settings asks through `ImsMmTelManager.isSupported()`, so a feature you "turned off" in a
CarrierConfig RRO goes on being offered while `dumpsys carrier_config` shows your key as `false`.
Checking the key you set is not checking the thing that decides.

Worse, these are `persist.` properties. With nothing in the tree setting them, their value is
whatever some earlier boot wrote to `/data/property` -- a bring-up `setprop` survives every
subsequent flash, so the handset in front of you behaves differently from a fresh install of the
same build, in a way no file in the repo explains. Seen on the V20: Wi-Fi calling and video calling
kept appearing for a whole build cycle after the RRO was correct.

- Do set all three explicitly in the device's prop makefile, including the ones you want off. Any
  value but `1` means "no override"; `0` reads as deliberate where absent reads as unconsidered.
- Do confirm from the decision, not the input: `ImsMmTelRepository: [N] isSupported(capability=C,
  transportType=T) = false` in logcat. `capability` 1=VOICE 2=VIDEO, `transportType` 1=WWAN 2=WLAN,
  so VT is (2,1) and Wi-Fi calling is (1,2).
- Don't expect the tree value to win on a device that already has a stale one: `/data/property` is
  loaded after `build.prop`. `setprop` it once on that handset, or wipe data.

The same shape recurs wherever a debug override precedes the real configuration: find the first
return in the platform's own accessor before you spend a build cycle on the input you assumed it
reads.

## 40. A QMI service object is version-gated, and failing it looks like a permission problem

Every generated QTI IDL ships `<svc>_get_service_object_internal_v01(major, minor, tool)` and
returns **NULL unless all three match the library exactly**. An OEM binary built against an older
vendor tree therefore gets a NULL service object on a newer ROM.

What makes this expensive is that every downstream symptom is an *absence*:

- the QMI client comes back `-1` with **`qmi_err_code=0`** — no error, because no QMI transaction
  was ever attempted;
- no `IPC_RTR ... permission failure` in dmesg;
- no `avc: denied`;
- no output from the QMI libraries at all.

That reads exactly like a permission or transport problem, and it is neither. On the V20 it cost
four wrong theories — missing `qmuxd`, a hardcoded `rmnet0` port name, the `sec_config` GID rule
for that service, and the device RIL owning the transport — each of which explains silence just as well.

- Do run `tools/android-cc.sh tools/native-probes/qmi-idl-probe.c --push` and scan. It prints the
  `(major, minor, tool)` the ROM's `libqmiservices.so` will accept, with the OEM binary out of the
  picture. On the V20: the stock helper asks WMS `(1,24,6)`; the 24.0 ROM accepts only `(1,35,6)`.
- Do fix it by putting the **stock** `libqmiservices.so` ahead of the ROM's on that one daemon's
  library path. That is correct rather than a workaround: the modem is the stock one, so the stock
  IDL is its matching encoder. The newer IDL arrived with the newer userspace, not with the radio.
- Don't scan a narrow minor range and conclude the service is absent — NAS on that same device
  answers at minor 249, WMS at 35.

The general lesson is older than QMI: when a failure reports *nothing* — no error code, no denial,
no log — suspect a check that returns a null object before any work is attempted, rather than a
layer that is refusing you. Refusals are noisy; gates are quiet.

## 41. A home-screen widget that only appears after you poke at the phone

LineageOS ships a DeskClock widget in Launcher3's `res/xml/default_workspace_*.xml` on 22.2 and
newer. On a freshly wiped phone it is common for it not to render until something unrelated is done
to the device -- opening Settings, granting the launcher notification access, launching an app. The
notification-access step people reach for is a coincidence; nothing in Launcher3 ties the
notification listener to widget binding. There are two real mechanisms, and they are distinguished
by one number.

`AutoInstallsLayout.verifyAndInsert` writes every default-layout widget as *pending*, not bound:

    Favorites.RESTORED = FLAG_ID_NOT_VALID | FLAG_PROVIDER_NOT_READY | FLAG_DIRECT_CONFIG   // 1|2|32 = 35

`WidgetInflater` resolves that on each model load: it calls `findProvider`, and only if the provider
comes back non-null does it clear `FLAG_PROVIDER_NOT_READY`, allocate an id and bind. If the
provider is null it leaves the row at 35 and returns a placeholder -- it does **not** delete the row,
because the delete branch is guarded on `FLAG_PROVIDER_NOT_READY` already being clear. So a widget
whose provider was not enumerable at the first model load stays a placeholder until some unrelated
event reloads the model. Preinstalled apps never send `PACKAGE_ADDED`, so nothing schedules a retry.

Separately, `AppWidgetServiceImpl.setMaskedByStoppedPackageLocked` masks a hosted widget whose
provider package is in the stopped state, and only `Intent.ACTION_PACKAGE_UNSTOPPED` clears it. After
a factory reset a preinstalled app that has never been launched *is* stopped, so its widget binds
correctly and still draws blank. Note that provider *enumeration* does not filter on this -- it
filters on `provider.zombie` and the category only -- so masking and the pending case are
independent failures with the same symptom.

Read the number before theorising:

    adb shell content query --uri content://com.android.launcher3.settings/favorites \
        --projection appWidgetId,appWidgetProvider,restored

`restored=35` is the pending case: the provider was not found at load, and a model reload is the fix.
`restored=0` with a blank widget is the masking case; confirm with `dumpsys package <provider pkg> |
grep -i stopped` and fix it by launching the app once. Neither is fixed by a build property, and
neither is caused by anything in this repo -- the widget comes from upstream's default layout, which
`minimal-home` keeps on 22.2 and newer and removes on 20.0 and older.

## 42. An ImsService that throws takes com.android.phone with it

A compat ImsService runs its calls on a binder thread serving com.android.phone. Binder marshals
the builtin unchecked exceptions -- IllegalStateException, IllegalArgumentException,
NullPointerException, SecurityException, UnsupportedOperationException -- across the transaction
and rethrows them in the *caller*, and `ImsServiceControllerCompat` catches none of them. So a
throw from your implementation is not an error your service reports; it is a fatal crash in the
framework's phone process.

What that looks like from the outside is nothing like an IMS bug:

    ImsBridge: slot 0: ims service not registered
    java.lang.IllegalStateException: legacy ims service unavailable
      at MmTelFeatureCompatAdapter.getOldConfigInterface
      at ImsServiceControllerCompat.createMMTelCompat
    am_crash: com.android.phone

and then it repeats, because the phone process restarts, ImsResolver rebinds the service, and the
same call throws again. Measured at one crash every ten seconds. The user-visible symptoms are a
"com.android.phone keeps stopping" dialog that will not go away, SIM settings crashing on open
(Settings asks the dead process for VT state and takes `RuntimeException: Could not find Telephony
Service` on the chin), and a notification every few seconds. None of them points at IMS.

Note that `RemoteException` is not the hazard -- the framework already expects that and handles it,
e.g. `MmTelFeatureCompatAdapter.getOldConfigInterface` catches it and returns null. The hazard is
the unchecked exception you throw yourself to signal a state you could not handle.

The API has its own channel for "this feature is down": the feature state. Return something benign
from the call, put the feature in `STATE_NOT_AVAILABLE`, and arm a waiter for the backing service
to return. Do not take the feature down during startup, though -- before the first READY a missing
backing service is just the bind racing the service registering, and reporting NOT_AVAILABLE there
has the framework give up on a feature that is seconds from working. `linkToDeath` on the backing
binder covers the rest, so a feature does not sit READY over a service that has gone.

The same shape applies to any *ImplBase you hand the framework. Treat every public method as a
boundary that absorbs, logs and degrades, never one that propagates.

## 43. Play quietly takes over the F-Droid apps you preinstall

A ROM that bundles apps from F-Droid alongside GApps will watch the Play Store adopt them. This is
not Play misbehaving: the good builds on F-Droid are *reproducible* ones, carrying the upstream
developer's own signing key rather than F-Droid's. K-9 Mail, KDE Connect and ConnectBot are all
like that. Play sees a package name in its catalogue, a signature that matches its own build, and a
version it can bump, so it updates it. The app then lives in /data as an update to the system app,
and F-Droid is no longer the thing maintaining it.

Note the asymmetry that makes this worth planning for rather than reacting to: Play can take an app
*from* F-Droid, but F-Droid cannot take it back, because its APK and Play's differ in version and
sometimes in build inputs even when the key matches.

Android 14's update ownership is the fix, and sysconfig can claim it for a preinstalled app without
any installer having to run:

    <config>
        <update-ownership package="com.fsck.k9" installer="org.fdroid.fdroid.privileged" />
    </config>

in /system/etc/sysconfig/. `InstallPackageHelper` reads it via
`SystemConfig.getSystemAppUpdateOwnerPackageName` for non-APEX *system* packages, so it works for
anything preinstalled and does nothing for anything else. Enforcement is on by default
(`PackageManagerService.isUpdateOwnershipEnforcementAvailable`, default true).

Two things to get right:

**Name the Privileged Extension, not the F-Droid client.** `PackageInstallerSession` compares the
update owner against the *installer package name*, and the installer of record is whoever holds
`INSTALL_PACKAGES` -- which is `org.fdroid.fdroid.privileged`. `org.fdroid.fdroid` only has
`REQUEST_INSTALL_PACKAGES`. Naming the client still locks Play out, but costs F-Droid the silent
updates the extension exists to provide. Check with
`dumpsys package <pkg> | grep INSTALL_PACKAGES` rather than assuming.

**Shipping the app now implies shipping F-Droid.** Once Play is locked out, something has to deliver
updates, and the ownership claim is inert unless the named installer is actually present. In this
repo that is `REQUIRES=fdroid` on each app option.

One escape hatch exists and is worth checking before relying on any of this: an installer holding
`INSTALL_PACKAGES` can opt packages out with the
`android.app.PROPERTY_LEGACY_UPDATE_OWNERSHIP_DENYLIST` manifest property. Dump the Play Store APK's
manifest and look. The build bundled here declares no such property.

XML comments may not contain `--`, which is easy to trip over when the house style uses it in prose.
Two places catch it and neither covers the other: `apply-overlay.sh` parses every XML under an
option's `tree/`, so a malformed file there fails the overlay rather than the build, and
`check-patch-series.sh` rejects a `--` in an XML comment added by a patch. Anything else, including
a device overlay edited in place, is caught only by aapt2 twelve minutes into the build. The habit
is the actual fix: do not write `--` in prose at all.

## 44. A persistent app does not exist until the user unlocks

`android:persistent="true"` has ActivityManager start a process at boot and keep restarting it. It
does not start it *early*. Unless the app is also `android:directBootAware="true"`, AMS will not
launch it until credential-encrypted storage unlocks, which means until someone types the PIN.

This is invisible on a phone with no screen lock, because such a device unlocks itself during boot.
The moment a PIN, pattern or password exists, every reboot has a window with no app at all, and the
app then starts cold against a system that has been running for as long as the lock screen sat
there. For an IMS implementation that window is a reboot with no IMS, followed by a registration
attempt whose preconditions are nothing like the ones at boot.

The tell is a bug that appears only once a PIN is set. Do not go looking at the keyguard; the PIN only
revealed an ordering your app always had.

    dumpsys user | grep State          # RUNNING_LOCKED vs RUNNING_UNLOCKED
    ps -A | grep <pkg>                 # zero processes while RUNNING_LOCKED
    aapt2 dump xmltree <apk> --file AndroidManifest.xml | grep -iE "directBootAware|persistent"

Measured on a V20 after a reboot, with the lock screen still up: user 0 `RUNNING_LOCKED`, and the
`persistent` IMS app at **zero processes**. Note the manifest is the authority here, not
`dumpsys package`, whose flag list shows `PERSISTENT` but says nothing either way about direct boot.

Making the app direct-boot-aware is only correct if it can genuinely run with no CE storage, so no
`SharedPreferences`, no database, nothing under `getFilesDir()`. If it cannot, keep the window and
make the work retry instead of firing once at startup.

## 45. A property that reads back empty is not necessarily unset

`getprop foo.bar` prints an empty line both for a property that was never assigned and for one the
shell domain is not allowed to read. The two are indistinguishable at the prompt, and reading the
empty output as an assignment that did not take sends you off rewriting a `.mk` that was already
correct. Three separate detours have come from this, on three different properties.

Before concluding a property is unset:

    dmesg | grep avc | grep <the property's context>

and check that something grants `get_prop` on that context to `shell`. Confirm the value from the
domain that actually consumes it, or from `init`'s own view, not from `adb shell`.

Corollary for the write side: `gen_build_prop` rejects a duplicate assignment outright, so you
cannot override a sysprop by assigning it a second time and expecting the later one to win. Change
it where it is set, or set it from `/product`, which init loads last.

## 46. A working AIDL fingerprint HAL reports no hardware, because of one leftover array

Symptom: no fingerprint option anywhere in Settings. Not greyed out, absent. Enrolment is reachable
only by intent, and it finishes immediately.

`AuthService` decides between the AIDL and HIDL paths from a framework-res array:

    new FingerprintSensorConfigurations(
        !(hidlConfigStrings != null && hidlConfigStrings.length > 0))

where `hidlConfigStrings` is `config_biometric_sensors`. A non-empty array means
`resetLockoutRequiresHardwareAuthToken = false`, which routes everything to HIDL:
`FingerprintProvider` logs "Adding HIDL configs", wraps each sensor in a `HidlToAidlSensorAdapter`,
and that adapter calls `IBiometricsFingerprint.getService()`. On a device whose HAL is AIDL there is
no such service, so every operation returns `BIOMETRIC_ERROR_HW_UNAVAILABLE` (1) and
`BiometricEnrollActivity` has nothing to offer the user.

`config_biometric_sensors` is a HIDL-era declaration. A device on the AIDL HAL must not carry it at
all; the HAL declares its own sensors through `IFingerprint`. Delete it from the device overlay
rather than trying to correct its contents.

    logcat -s FingerprintProvider AuthService

Working looks like "Adding AIDL configs: 1" and "Adding HIDL configs: 0". The array being present is
easy to inherit without noticing, because it is correct for the same device on an older branch.

## 47. Two builds are never the same experiment, so A/B needs a pinned manifest

`repo sync` tracks branch heads. The build you ran yesterday and the "same" build today can differ
by dozens of upstream commits across more than 1200 projects. Measured in a single day on
lineage-24.0: frameworks/base moved 6 commits, Settings 3, vendor/lineage 4. So a feature that
worked last week and fails today is not evidence about your patch series, and bisecting your own
commits over a moving tree produces confident nonsense.

Record what each build was made of:

    repo manifest -r -o manifest.xml

`bootstrap.sh` does this automatically after every successful sync, into
`build_output/manifests/manifest-<stamp>.xml`, with `latest.xml` pointing at the newest. To rebuild
the exact tree a previous build used:

    PIN_MANIFEST=build_output/manifests/manifest-<stamp>.xml ./forge/bootstrap.sh

Two traps in the replay, both of which cost a build to find:

`repo manifest -r` writes every project it can see, **including the ones `local_manifests` add**, so
the snapshot is already the complete set. Re-initialising with it while the local manifests are
still installed declares those projects twice and repo rejects the whole file:

    fatal: duplicate path vendor/gapps in /aosp/.repo/manifests/pinned.xml

Remove the local manifests for a pinned sync; `bootstrap.sh` regenerates them from the option set
every run, so nothing is lost.

And repo remembers the override in its own config, while `bootstrap.sh` only runs `repo init` when
`.repo` does not exist yet. So a pin set once leaks into every later build, silently syncing an old
upstream while reporting nothing unusual. Clear it with `repo init -m default.xml` when no
`PIN_MANIFEST` is given.

There is a third place it bites, and it is not at sync time. The ROM build runs
`repo manifest -o - -r` itself to write `/product/etc/build-manifest.xml`, so a duplicate kills that
target around 50% into the build, long after sync looked fine. `apply-overlay` reinstalls the local
manifests on its second pass, which undoes anything the pin did earlier, so the removal has to be
repeated immediately before the build.

Verifying that a snapshot *writes* is not verifying that it *restores*. Test the replay path end to
end, including a build, or the feature is decoration.

Note the asymmetry when you have no snapshot to pin, because it determines what you may conclude.
Checking an older patch series out onto today's upstream tests that series against a tree it has
never seen. If the feature works, your series was the cause. If it does not, you have learned
nothing, since upstream is now a second variable. Only the positive result is conclusive. Say so
before spending an hour on the build, not after.

## 48. A HAL service named for a version is named for the *module* it accepts

Lineage ships two fingerprint HAL services that differ in one constant:

    .../biometrics/fingerprint/2.0/   kVersion = HARDWARE_MODULE_API_VERSION(2, 0)   HIDL, registers @2.1
    .../biometrics/fingerprint/aidl/  kVersion = HARDWARE_MODULE_API_VERSION(2, 1)   AIDL, IFingerprint

The `2.0` in `android.hardware.biometrics.fingerprint@2.0-service` is the **legacy libhardware
module version it opens**, not the HIDL interface it serves: its vintf fragment declares
`<version>2.1</version>`. So when `hardware/interfaces/biometrics/fingerprint/2.0` disappears from
a newer branch, that service is not affected and has not been removed. Deleting the interface
directory and retiring the service are different events, and a device tree that moves off the
service because the interface went away has moved for no reason.

Getting this backwards is expensive, because the failure is not a build break. `openHal()` version
check fails, returns `nullptr`, and `createSession` hands the null to the session constructor with
no guard:

    Session::Session: mDevice->set_active_group(mDevice, ...)
    signal 11 (SIGSEGV), fault addr 0xc0        # set_active_group's offset, from a null base

The HAL dies on first use, the framework logs `HAL deaths since last reboot: 1`, and the Settings
enrolment screen keeps its consent button disabled forever, because it waits on a challenge that
can never arrive. Everything else looks healthy.

**Do not relax the version check to make it fit.** The two legacy APIs are not ABI compatible:

    2.0:  int (*enumerate)(struct fingerprint_device*, fingerprint_finger_id_t* results, uint32_t* max_size)
    2.1:  int (*enumerate)(struct fingerprint_device*)

which is why the 2.0 service casts to its own `enumerate_2_0` typedef. Calling the one-argument form
on a 2.0 module leaves the blob writing templates through whatever is in the second argument
register. Silent corruption, not a clean error. Check every member against both headers before
assuming a version gate is merely conservative.

Pick the implementation that matches the blob, and check the FCM level permits it:
`compatibility_matrix.7.xml` still allows `format="hidl"` fingerprint `2.1-3`, while level 8 lists
AIDL only. A device on an old blob and a new target level needs a real shim, not a looser check.

## 49. An RRO can override a resource but cannot add one

`PRODUCT_ENFORCE_RRO_TARGETS` converts a device overlay from something compiled into the target APK
into a runtime overlay, and the two are not equivalent. A static overlay contributes resources; an
RRO can only *replace* a resource the target already defines. Anything new it declares is not
reachable by name from the target package.

The overlay APK really does contain the new resources. What it cannot do is make them resolvable
**by name in the target package**: the idmap only maps names the target already defines, so a lookup
like `getIdentifier("robin_edge", "drawable", "org.lineageos.backgrounds")` returns 0 while
`robin_edge` sits in the overlay unreferenced. Measured on a vs995 build, reclaiming manufacturer
wallpapers into Lineage's `Backgrounds`:

    RRO:               array/partner_wallpapers overridden, 17 entries   (works, the name exists)
                       drawable/robin_* all 12 present                   (present, unreachable)
    base APK:          zero of the reclaimed drawables                   (nothing to map onto)
    /product/media:    every PNG present, because PRODUCT_COPY_FILES is unaffected

After excluding the package from enforcement, the same build compiles 36 drawables into the base
APK, 12 of them the reclaimed ones, and ships no RRO for it.

This is silent in the worst way, because the half that does work makes the result look intentional.

So the picker is handed a list of wallpapers it cannot resolve and renders nothing. No error, no
blank tiles, no missing-resource warning; the entries simply are not in the grid. And the raw files
*are* on the device, which sends you looking at the copy rules instead of the overlay. Those files
feed `ro.config.wallpaper` and the picker never reads them.

The tell is one device working and another not with the same assets: a tree that does not set
`PRODUCT_ENFORCE_RRO_TARGETS` compiles the overlay in and behaves correctly.

The supported escape is per overlay, matched by path prefix in `package_internal.mk`:

    PRODUCT_ENFORCE_RRO_EXCLUDED_OVERLAYS += vendor/extra/overlay/oem-assets/packages/apps/Backgrounds

Exclude only the package that needs to add resources. An overlay that merely overrides existing
ones is doing exactly what an RRO does well, so leave it runtime and keep the generic image.

Check the result on the artifact rather than the device: `aapt2 dump resources <apk>` on the built
APK shows whether the resources are compiled in, and a leftover
`<Target>__<product>__auto_generated_rro_vendor.apk` means it is still an RRO.

Use the `aapt2` from **the same tree** as the APK. An older one run against a newer APK does not
error; it prints a plausible-looking dump with the resource names missing and a nonsense
`entryCount`, which reads exactly like "the resources are not there" and has produced a wrong
diagnosis twice. `out/host/linux-x86/bin/aapt2` of the tree that built it.

## 50. Your own adb command text is in logcat, and your grep counts it

`adbd` logs every shell request verbatim:

    I adbd : adbd service requested 'shell,v2,...,raw:logcat -d -b all | grep -c "Security-Client"'

So the needle you are hunting is written into the haystack by the act of hunting. `grep -c` then
returns at least 1 and the thing looks present. Two cases, both real: an ANR count that was the
string `am_anr` inside the command, and a `Security-Client` count of 1 across four captures whose
real count was zero, which inverted the conclusion about whether the IMS stack was offering a
security agreement at all.

It is worse than a simple off-by-one, because the false hit looks exactly like a true one and
survives being re-run. Any `grep -c` over `logcat` that you then reason from must exclude the
echo:

    logcat -d -b all | grep "Security-Client" | grep -v adbd | wc -l

Two habits that avoid it entirely: pull the log to the host once and grep the file (the echo is
still in there, so still filter, but at least the evidence stops moving), and prefer matching the
log line's own shape, e.g. the tag or level column, over a bare substring. When a count is load
bearing, print the matching lines rather than the count and read them.
