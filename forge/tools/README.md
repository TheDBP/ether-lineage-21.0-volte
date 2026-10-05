# rom-forge tools

Port-assessment scripts, plus the machinery `bootstrap.sh` calls.

Bash and `grep`/`awk`/`comm`. Need a synced tree, not a built one. Run on the host or in the
container.

## Quick reference

| tool | run it | what you get |
|---|---|---|
| `check-platform-support.sh` | before porting | what upstream no longer gives this SoC — the cheapest, most predictive check |
| `find-orphaned-sepolicy-types.sh` | before porting | SELinux types the device references that the new branch deleted |
| `find-removed-platform-symbols.sh` | before porting | C/C++ platform constants it lost |
| `abi-gap.sh` | when a prebuilt will not load, or loads and misbehaves | the symbols a blob imports that the running platform no longer exports, demangled. The runtime counterpart to `find-removed-platform-symbols.sh`: that one catches what will not compile, this one what will not link |
| `find-soong-namespace-drift.sh` | before porting | Soong namespaces the device must now import, modules and HIDL libraries the branch deleted (including what the blobs link against), makefile paths that moved |
| `triage-build-log.sh` | after a failed build | a wall of errors collapsed into a few classes |
| `check-image-labels.sh` | when packaging fails | every unlabeled path at once, instead of one per build |
| `image-labels.sh` | after a build, before flashing; when an avc denial names a tcontext that looks wrong | the SELinux label the image builder actually wrote on a path (or a whole subtree) inside a built ext4 image. A path no file_contexts rule knows falls through to the partition catch-all with no build error — `/system/vendor/odm/...` on a vendor-in-system device became `vendor_file`, and system_server died behind an endless boot animation |
| `check-lmkd-source.sh` | after a kernel build, before flashing (Android 16+) | whether the kernel gives lmkd a pressure source it can use: `CONFIG_PSI` or `CONFIG_ANDROID_LOW_MEMORY_KILLER`. Android 16+ lmkd dropped the vmpressure fallback and the memory controller moved to cgroup2, so a 4.4/4.9 kernel with neither option has lmkd exiting at startup -- and the symptom is nowhere near it: 3 s stalls in every `ProcessList.writeLmkd()`, an ANR cascade, networkstack killed, system_server dying with "Lost network stack" every ~80 s. One defconfig line fixes it where PSI is absent |
| `check-root-mountpoints.sh` | after a build, before flashing (system-as-root) | every top-level directory the image's rc files and fstabs `mount`/`mkdir` into, checked against the root of `system.img`; the root is read-only so a missing one fails silently. Android 17 puts the aconfig flag store under `/metadata`: a device with no metadata partition and no `BOARD_USES_METADATA_PARTITION` has no `/metadata`, aconfigd never runs, and system_server dies in AdvancedProtectionService ("Invalid feature flag") every ~20 s behind the boot animation |
| `check-service-domains.sh` | after a build, before flashing | every init `service` whose binary the image labels without an `*_exec` type — init logs one kmsg line and never starts it; a HAL the manifest still declares then hangs whoever waits for it (system_server, killed by its Watchdog every ~105 s on the vs995 when a patch renamed the IR HAL binary and not its file_contexts line). Follows symlinks, honours `seclabel`, lists absent binaries |
| `check-overlay-precedence.sh` | before a build that adds or moves a device overlay value; when a resource override has no effect | the overlay directories in the order the build resolves them, every resource two of them define with the winner, and the framework dimens they set. The FIRST listed directory wins (package_internal.mk reverses LOCAL_RESOURCE_DIR for aapt2, and the auto-RRO is built the same way), so a `device-common` tree inherited before the device tree's overlay cannot be overridden from it; a common tree pinning `status_bar_height` to 32dp discarded the V20's 160px `status_bar_height_portrait` and 24.0's QS header, sized from that dimen, drew its clock under the camera cutout |
| `check-vendor-needed.sh` | after a build, before flashing | every vendor ELF's DT_NEEDED resolved against what the vendor linker namespace can see (vendor lib dirs + LLNDK), 32- and 64-bit apart; `--import-check` says whether the blob imports anything from the missing lib (dead entry → `overlay/blob-fixups` remove-needed) or really needs it (shim). Catches "CANNOT LINK EXECUTABLE … not found" camera-provider/daemon restart loops from the out tree |
| `ota-extract.sh` | when you need a reference ROM | partitions out of a signed A/B OTA, and optionally flashed to one slot so you can keep a known-good build on the inactive slot |
| `slot-switch.sh` | when you need the other slot's ROM to boot | the device moved to the other slot with the shared `/data` wiped and the setup wizard skipped, because the older ROM stops booting once the newer one has initialised user 0 |
| `check-tree-dirt.sh` | after a build, before trusting the tree | every uncommitted change in a patched project attributed to the forge option that made it, and anything left over reported. A hand edit in a synced tree looks exactly like normal build noise, is never exported as a patch, and dies at the next force-sync |
| [`dedup-shared-inputs.sh`](dedup-shared-inputs.sh) | collapse identical large build inputs across device repos to hardlinks; never touches synced trees | `dedup-shared-inputs.sh --dry-run` |
| `prop-effect.sh` | when a property you set changed nothing | its value, its SELinux type, every binary in the image that reads it, and any domain denied that type. The third is the silent case: a property whose reader cannot see it behaves exactly like one you never set |
| `blob-attach.sh` | when a prebuilt HAL crashes | a vendor binary under `lldb-server` with its library load base printed, so absolute breakpoints work in a stripped blob |
| `fb-capture.sh` | when you need to see the screen and there is no `screencap` | a PNG of `/dev/graphics/fb<N>`, with the line stride read from sysfs rather than assumed. For recovery and early boot; a booted Android returns ENODEV because SurfaceFlinger owns the panel |
| `boot-window-logcat.sh` | when a boot ends in a reboot | the logcat, dmesg and properties of each window adbd is reachable, one set per appearance — the route that does not depend on the ramoops region surviving the reboot |
| `repack-erofs-apex.sh` | when a prebuilt APEX will not mount | that apex rebuilt with an ext4 payload and re-signed, for a kernel with no CONFIG_EROFS_FS -- apexd's "No such device" with everything inside the apex silently absent |
| `make-apex-key.sh` | before the first EROFS repack | the four-file signing key that repack needs, made once on the host because KEYS_DIR is read-only in the container |
| `unpack-block-ota.sh` | when flashing | partition images out of a `payload.bin` OTA, for fastboot-only flashing |
| `check-sigpipe.sh` | before committing | pipelines that will die silently under `set -o pipefail` |
| `dev-shell.sh` | any time | an interactive shell in the build container |
| `publish-kernel-source.sh` | before publishing a build | the kernel you actually shipped, as a normal kernel repo: upstream history with this device's patch series replayed on top. GPL asks for the *corresponding* source, and a link to upstream alone does not answer it once you patch the kernel. Regenerated from base+patches every run, so the published tree cannot drift from what you build |
| `make-keys.sh` | once, before the first release | signing keys in a directory outside every repo; point `KEYS_DIR` at it in `device.conf.local` |
| `new-device-repo.sh` | once, at the start | scaffolds a device repo, vendors `forge/`, and with `--codename` fills in `device.conf` and the local manifest by looking the device up |

Called for you by `bootstrap.sh`, listed here so you know what they are:

| tool | what it does |
|---|---|
| `apply-overlay.sh` | installs local_manifests, applies the selected options and this device's patches, vendors recovered trees (`VENDORED_PROJECTS`), merges kernel fragments (`KERNEL_EXTRA_CONFIGS`) and kernel patches (`KERNEL_EXTRA_PATCHES`) |
| `blob-fixups.sh` | by apply-overlay.sh, or by hand | `remove-needed` / `add-needed` / `replace-needed` / `set-soname` on prebuilt blobs from the one-line-per-fact list `overlay/blob-fixups`, with the tree's own patchelf; idempotent, verifies each edit took, `--check` reports what is still unapplied. For a blob whose DT_NEEDED names a framework lib the vendor linker namespace is never linked to (libandroid.so, libandroid_runtime.so) -- check `nm -D --undefined-only` shows no import from it first |
| `extract-gapps-apps.sh` | matches APKs in a GApps zip by package name via aapt2, stages them as `android_app_import` prebuilts with `overrides:` so they replace the Lineage equivalents |
| `release.sh` | publishes the redistributable preset and refuses anything else — see [docs/RELEASING.md](../docs/RELEASING.md) |
| `run-one.sh` | builds one device repo and refuses if another build is already running; timestamped log, one start/finish line for a queue to read |
| `extract-nextbit-oem-assets.sh` | pulls sounds, wallpapers and the boot animation out of a Nextbit Robin stock ROM (nav-bar icons are the `nav-icons` option, redrawn, not extracted) (`OEM_ASSET_PACK=nextbit-robin`) — see [docs/OEM-ASSETS.md](../docs/OEM-ASSETS.md) |
| `sync-forge.sh` | vendors `forge/` into a device repo at a pinned commit |
| `refresh-patches.sh` | regenerates `overlay/patches` from your commits — **clean tree only** (GOTCHAS 14) |
| `measure-touch-rate.sh` | how fast the touchscreen really reports, measured inside one contact on the real digitizer — injected input never reaches it (GOTCHAS 25) |
| `bench-launch.sh` | cold app-launch times over adb (min/median/max of N runs) — for A/B-ing a tuning change on one phone, meaningless across phones or ROMs |
| `symbolize-odex-pcs.py` | names the bare `services.odex` PCs in an ANR/tombstone native dump from an oatdump listing — dex-preopted framework code ships without debug info, so debuggerd prints only file offsets |
| `check-hal-readiness.sh` | HALs the manifest declares with nothing to serve them — finds them before a build-flash-boot cycle does |
| `check-bpf-readiness.sh` | what a kernel without eBPF (or other modern syscalls) will break; `--src` scans code, `--log` reads what the device actually got |
| `propagate-forge.sh` | pushes an engine change out to every device repo beside this one, fast-forwarding each branch to its remote first |
| `kernel-rebuild.sh` | boot image only, ~20 min, with the last full build's exact option set (`out/.turbo_config`) so `out/` neither reconfigures nor installcleans; `--am <patch>` puts an overlay kernel patch on the live tree first |

Bringing a kernel up to a newer branch (the *kernel gate* of a port — see
[docs/porting-a-branch-bump.md](../docs/porting-a-branch-bump.md)), in the order you reach for them:

| tool | run it | what you get |
|---|---|---|
| `check-bpf-objects.py` | before the first boot, on the built `.o`/`.bpf` files | every BPF map/program/helper the old kernel cannot load, with the kver-gated ones marked skipped; a cycle in a program's control flow (pre-5.3 verifiers reject it) and, given the live kernel's `available_events` from recovery, every `tracepoint/` program whose event it does not have |
| `check-dt-needed.py` | before the first boot, on the out tree | every ELF whose `DT_NEEDED` nothing in the image provides — a prebuilt copied in by path that the branch's libraries have moved out from under, which the linker reports as `exited with status 1` and, when the user is `vold`, as a reboot loop with no adbd |
| `rc-fatal-services.py` | before the first boot, on the out tree | the dozen services marked `critical`/`reboot_on_failure` — the only ones whose death becomes a loop — with their binaries checked; the names to grep a console dump for and to dry-run from recovery |
| `hybrid-bootimg.sh` | before the first boot | new kernel + old *recovery* ramdisk: recovery/fastbootd on the candidate kernel, so the phone stays reachable |
| `init-harness.sh` | from that recovery | the new ramdisk's `/init` run as PID 1 of a throwaway pidns on the live kernel; each FATAL in kmsg is a gap, no slot-retry burnt. Covers bionic → `selinux_setup` → start of second stage |
| `dtbo-ramoops-alt.py` | for anything past that | a debug dtbo whose live ramoops ring survives a clean reboot; normal-boot, then read it from recovery — the only way to see `early-init` die (cgroups, apexd-bootstrap) on a device whose bootloader wipes pstore |
| `boot-console-wrap.sh` | when it loops or hangs with no USB and pstore does not survive the bootloader | a boot image whose PID 1 saves the previous iteration's console-ramoops to a spare region of `misc` and arms a watchdog in its own mount namespace that dumps `dmesg` there every few seconds and, at the timeout, sets the BCB and reboots to recovery — so a hang is read like a loop; `pull` reads it back from recovery |
| `pstore-pull.sh` | from recovery, after | every pstore record, plus the raw ring unrolled if the kernel did not expose it; `pmsg-ramoops-*` decoded to logcat text (`pmsg-decode.py`) |
| `pixel-ramoops-pull.sh` | Pixel 3/3a class, after a *panic* | the encrypted klog the bootloader saved, decrypted with your own key |
| `super-loop-mount.sh` | from recovery | a logical partition of the inactive slot mounted rw without device-mapper — edit `init.rc`, push a binary, chroot into it |
| `usb-watch.sh` | during a boot attempt | timestamped USB/adb/fastboot transitions: how long until the bootloader, whether adbd ever appeared |
| `prop-denials.sh` | when a property read is denied | which properties that domain actually wants that carry the refused type, so you label prefixes instead of granting `default_prop` and handing it everything unlabelled |
| `check-patch-series.sh` | after regenerating patches | pairs where a later patch undoes an earlier one — one change written twice, which a replayed series cannot express |
| `diag-efs.sh` | when a modem feature never runs | the modem's own EFS/NV items, read and written over `/dev/diag`. Tells "the modem refused" from "the modem was never told", which look identical from outside |
| `mcfg-items.py` | when a feature works on one device and not another with the same modem | the EFS items a Qualcomm MCFG provisions, with values, without flashing it — diff carrier provisioning instead of cross-flashing firmware |
| `diag-f3.sh` | when the modem refuses something and the RIL only says "failed" | the modem's own F3 debug log (file:line + message, what QXDM shows) captured over `/dev/diag` for N seconds and decoded — every modem-side decision, with the source line that made it |
| `diag-f3/diag-f3-parse.py` | on a raw capture | the HDLC stream from `diag-f3-capture` decoded to `ts ssid file:line message` lines; `diag-f3.sh` runs it for you |
| `freestanding-arm64.sh` | sourced by `diag-f3.sh`, `qmi-sni.sh` | one function: cross-compile a libc-free arm64 helper in the cached container and push it to `/data/local/tmp` |
| `qmi-sni.sh` | when a data call fails and you need the modem's answer, not the RIL's | START_NETWORK_INTERFACE sent as a direct QMI WDS client, one TLV varied at a time; the raw error and call-end TLVs tell a modem policy refusal from a network reject |
| `qmi-services.py` | before porting IMS, or when an OEM hook is suspected | the QMI service table per processor, named (IMSS/IMSA/IMSP/IMS_RTP on the modem means a modem-side IMS stack; none means AP-side), and the service id + message ids an OEM QMI client lib carries |
| `smem-poke/` (module, build with `kmod-build.sh`) | when a modem/bootloader handshake flag is suspect | the SMEM vendor items the bootloader fills in for the modem, dumped from the AP — and one word rewritten live to test a theory before patching the kernel |
| `kmod-build.sh` | when you need a kernel module against the last build | an out-of-tree module built in the forge container with the ROM's exact kernel make env; a host `make O=KERNEL_OBJ` rebuilds the vdso and corrupts the build output |
| `kmod-rebase-crcs.py` | when insmod says "disagrees about version of symbol" | the module's `__versions` CRCs rewritten from the target kernel's Image, so a module from your tree loads on an official nightly built with another toolchain |
| `pmsg-decode.py` | when a boot never reached adb | the previous boot's logcat out of a pstore pmsg record, tombstones included |
| `gen-tool-index.py` | after adding a tool or a doc | `docs/TOOLS.md` and `docs/tools.yaml` regenerated; `--check` fails if either is stale or a tool is missing from this table |

## Assessing a port

`OLD_SRC` is a checkout on a branch where the device built; `NEW_SRC` is the target branch. Both
must be on disk. Keep the old tree until the port lands.

```sh
# What does upstream no longer give this SoC?
./tools/check-platform-support.sh <NEW_SRC> device/<vendor>/<codename>

# Which SELinux types did the new branch delete?
./tools/find-orphaned-sepolicy-types.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename>

# Which C/C++ constants did it lose?
./tools/find-removed-platform-symbols.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename>

# Which namespaces, modules, blob dependencies and include paths did it move or delete?
# (OLD tree's device dir as 4th arg when NEW_SRC has no synced device tree yet; EXTRA_TREES for sibling blob dirs)
EXTRA_TREES="vendor/<vendor>/<sibling>" ./tools/find-soong-namespace-drift.sh <OLD_SRC> <NEW_SRC> device/<vendor>/<codename> [<OLD_SRC>/device/<vendor>/<codename>]
```

Each `[OUT]` gate means the device no longer gets whatever that block configures. The three outputs
are the work list.

## Triaging a build

```sh
mka -k -j12 bacon 2>&1 | tee build.log     # -k keeps going and collects every failure
./tools/triage-build-log.sh build.log      # collapse them into classes
```

Use `-k` on a new port: failures cluster. A run reporting 274 failed edges resolved to two fixes,
270 of them a single missing BoardConfig flag.

## When packaging fails

```sh
./tools/check-image-labels.sh <SRC> <codename> device/<vendor>/<codename> [<reference-out>]
```

`e2fsdroid` refuses to build `system.img` unless every path has a label, reports one path per run,
and fails at ~99% of the build. Pass a `REFERENCE_OUT` from a device that builds to filter benign
cases.

## Why these exist

Porting to a newer branch fails one way: upstream deleted something the device tree still
references, silently. The providing block is gated behind a platform list that no longer names the
SoC, or a header dropped the constant. The build then fails far from the cause, one item per run,
because `checkpolicy` and the compiler stop at the first error.

## Worked example: ether, lineage-18.1 → 19.1

What the tools report, on a real port:

| Tool | What it would have said up front |
|---|---|
| `check-platform-support.sh` | `device/qcom/sepolicy-legacy/SEPolicy.mk` no longer lists `msm8992`, so the whole legacy qcom vendor policy is gone. Also flags the inverted `BOARD_SEPOLICY_M4DEFS` gate — the reason importing a newer vendor policy trips AOSP neverallows. |
| `find-orphaned-sepolicy-types.sh` | `adsprpcd_file`, `qdisplay_service`, `sysfs_graphics`, `perfd`, `debugfs_rmt`, `time_data_file`, … — six build cycles' worth, in one pass. |
| `find-removed-platform-symbols.sh` | AOSP 12 dropped the vendor section of `system/camera.h`; the bundled QCamera2 HAL uses eight of those constants. |
| `find-soong-namespace-drift.sh` | 22.2→24.0 on a Pixel 3a: five `hardware/google/pixel/*` subdirs became namespaces the device never imported; `hardware/qcom/wlan` gained a namespace that shadows the imported `legacy` one; dumpstate 1.1, health.storage 1.0, `hardware.google.light@1.0-service`, `check_dynamic_partitions`, `disable_configstore` gone; the fingerprint blob links `android.frameworks.stats@1.0`, deleted; `vendor/lineage/config/device_framework_matrix.xml` moved. Seven build cycles, one pass. |
| `triage-build-log.sh` | 274 edges → `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES` + a kernel toolchain flag. |

## Fixing what they find

Restore, do not redesign. Copy the original definition and its context entry verbatim from the old
tree:

- a SELinux type without its `file_contexts` / `genfs_contexts` / `property_contexts` line parses
  fine and labels nothing, so the domain is inert at runtime;
- a C constant must keep its original value — prebuilt blobs and the framework already agree on those
  numbers, so renumbering breaks the ABI silently. Put them in a device-local compat header
  force-included via `LOCAL_CFLAGS += -include <header>`, which leaves vendor sources diffable
  against upstream.

Script-writing traps that produced wrong answers here are collected in **GOTCHAS 17**.

## The pieces that are not in `tools/`

Not everything the forge runs lives here. These get invoked for you, but they are where a build
actually fails, so they are worth knowing by name.

| | |
|---|---|
| `bootstrap.sh` | the orchestrator — reads `device.conf`, then `device.conf.local` if present, syncs, applies the overlay, builds |
| `lib/presets.sh` | resolves a preset name into an option list and a build tag. `EXTRA_OPTIONS` is unioned in here, and the tag suffix for each option it adds (`-oem`, `-nextcloud`) is derived here rather than written by hand |
| `docker/prefetch.sh` | downloads the build's network inputs into `/dl` in-container, so they overlap `repo sync` instead of running after it. A set-but-failed download is fatal, deliberately |
| `docker/_build_rom.sh` | runs the build inside the container and calls each enabled option's `require.sh` before and `post-build.sh` after |
| `prebuilt/lib-fdroid.sh` | the F-Droid fetch: resolves the suggested build of a package, verifies package name, ABI and the pinned signer certificate, unpacks native libraries the APK packs compressed, writes the Soong module file |
| `prebuilt/fetch-firefox.sh`, `fetch-fulguris.sh`, `fetch-fdroid.sh`, `fetch-k9.sh`, `fetch-kdeconnect.sh`, `fetch-termoneplus.sh`, `fetch-nextcloud.sh`, `fetch-linphone.sh`, `fetch-connectbot.sh`, `fetch-syncthing-fork.sh` | the per-option fetchers on top of it: package, signer pin, module names |
| `prebuilt/lib-app-checks.sh` | the `require.sh` / `post-build.sh` checks those options share: APKs present and named in the module file; shipped byte-identical, libraries installed beside |
| `prebuilt/fetch-magisk.sh` | downloads Magisk for the `root` option's boot-image patch |

An option can also carry its own hooks, which `_build_rom.sh` runs by name:

- `require.sh` — before the build. Non-zero stops it. `gapps` uses this to refuse a build whose app
  swaps were never staged, rather than shipping Lineage's apps under a GApps tag.
- `post-build.sh` — after a successful build. Non-zero fails it. `root` patches the boot image here;
  `firefox` checks the APK it shipped can still install.
