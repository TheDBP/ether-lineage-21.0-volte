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
for that service, and "our RIL owns the transport" — each of which explains silence just as well.

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
