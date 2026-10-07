# Nextbit Robin — LineageOS 21.0 (Android 14) — STAGED, NOT YET BUILT

Android 13 on the **Nextbit Robin** (`ether`, Snapdragon 808 / msm8992, 2016). LineageOS never
carried ether past 18.1, and the one 19.1 tree that existed was deleted from its host; this port
replays onto a copy of that tree recovered from Software Heritage (`vendored/`, also kept flat on
the `main` branch of [ether-trees](https://github.com/TheDBP/ether-trees)), and everything above it
is new.

**It boots and works.** WiFi, Bluetooth, camera, audio, adb, LTE data, SMS, visual voicemail, the
flashlight and VoLTE all function. No Wi-Fi calling — see *Known issues* for what is still open.

## What this build actually changes

The Robin spends most of its life pretending to be much slower than it is — and the LineageOS
device tree, not Nextbit, is mostly to blame. Nextbit's own ROM never throttled the A57 big cores on
die temperature and kept both online; the lineage-18.1 tree that every later port inherits starts
throttling them at **51 °C** and takes them offline at **52 °C**, temperatures the cluster reaches
almost immediately under load. Most of what the `turbo` tag means is going back to Nextbit's policy
with higher ceilings.

Sources: stock = Nextbit `Robin_Nougat_108` (`init.qcom.post_boot.sh`, `thermal-engine-8992.conf`,
boot ramdisk); 18.1 = the `lineage-18.1` device tree's values, carried unchanged by the recovered 19.1 tree this
port replays onto (`vendored/`);
turbo = this build (device patch 0002, kernel patches 0002/0004/0005). Same 3.10 kernel lineage
throughout.

| | stock Nougat | LineageOS 18.1 tree | turbo 20.0 |
|---|---|---|---|
| **Thermal** (`thermal-engine-8992.conf`) | | | |
| A57 frequency throttle (`SS-BIG-CLUSTER`, on `quiet_therm`, the board thermistor) | disabled; only a `pop_mem` 55 °C step-down, no cap | 51 °C → 864 MHz | 88 °C → 864 MHz (unreachable on a board sensor — effectively off) |
| A53 frequency throttle (`SS-LITTLE-CLUSTER`, on `quiet_therm`) | disabled; `pop_mem` 55 °C → 787 MHz | 54 °C → 787 MHz | 88 °C → 787 MHz (as big) |
| A57 core offlined (`HOTPLUG-CPU4` / `CPU5`) | 95 / 95 °C | 52 / 50 °C | never — `core_control` off |
| GPU throttle | step-down from 70 °C on the GPU sensor | 600→180 MHz ladder at 48–53 °C | same ladder at 72–87 °C |
| Battery charge-current throttle | 53 / 55 / 58 / 60 / 65 °C | 49 / 54 / 57 °C | 49 / 54 / 57 °C |
| **CPU** (`init.qcom.post_boot.sh` / `init.nbq.power.sh`) | | | |
| governor, both clusters | `interactive` | `interactive` | `interactive` |
| A53 `hispeed_freq` / `go_hispeed_load` | 960 MHz / 95 | 960 MHz / 90 | 960 MHz / 90 |
| A53 `target_loads` | `65 787200:75 960000:80` | `65 460800:75 960000:80` | `65 787200:75 960000:80` (stock) |
| A57 `hispeed_freq` / `go_hispeed_load` | 1248 MHz / 95 | 1248 MHz / 90 | 1824 MHz / 80 |
| A57 `target_loads` | `20 633600:70 960000:80 1248000:85` | `70 960000:80 1248000:85` | `20 633600:70 960000:80 1248000:85` (stock) |
| touch boost (`cpu_boost`) | 960 little + 960 big, 200 ms | 960 little only, 40 ms | 1248 little + 1824 big, 150 ms |
| A57 cores held online (`core_ctl min_cpus`) | 2 — both pinned | 0 — idle-parked | 2 — both pinned |
| `core_ctl offline_delay_ms` | 100 | 100 | 1 000 000 |
| `msm_thermal core_control` | on | on | off |
| HMP `sched_upmigrate` / `sched_downmigrate` | 95 / 80 (+ shadow 60 / 30) | 95 / 85 | 65 / 45 |
| **GPU** (`kgsl-3d0`) | | | |
| `default_pwrlevel` | 5 (180 MHz) | 5 (180 MHz) | 5 (180 MHz) |
| `msm-adreno-tz` jump-to-max gates (`BUSY_BIN` / `LONG_FRAME` / `CEILING`) | kernel default | 95 / 25 ms / 50 ms | 80 / 16.7 ms / 25 ms |
| **Memory** | | | |
| zram swap | 512 MB lz4, mounted | none | 768 MB, mounted |
| `vm.swappiness` / `vm.page-cluster` | 60 / 3 (kernel default) | 60 / 3 (kernel default) | 100 / 0 |
| lowmemorykiller | adaptive off, `minfree 18432…80640` | adaptive on, `vmpressure_file_min 81250` | as 18.1 |
| `dalvik.vm.heapgrowthlimit` / `heapsize` | 192m / 512m | 288m / 768m | 288m / 768m |
| **Kernel config** | | | |
| `RT_GROUP_SCHED` | (stock kernel) | on | off — `SCHED_FIFO` works inside cgroups |
| `MEMCG` / `BLK_CGROUP` | (stock kernel) | off | on |

Die protection is the same in all three and not in the table: per-core tsens rules (`SS-CPU0-1` …
`SS-CPU5`) at 85 °C, `pop_mem` at 80 °C in the two LineageOS columns (55 °C on stock), and behind
them the kernel's own `msm_thermal` backstops, which no config can switch off: 100 °C forces the
A57s to 768 MHz, 115 °C resets the SoC. The `quiet_therm` rows above are a board thermistor, i.e.
skin temperature; the A57 `target_loads` row is the one where 18.1 hurt most — with both big cores
pinned online and tasks migrated to them early, a 384–633 MHz A57 (slower than an A53 at 960) had to
reach 70 % load before it would move.

Unchanged in all three and not worth a row: A53/A57 `scaling_min_freq 384 MHz`, no max cap,
`timer_rate 20000`, `min_sample_time 40000`, `above_hispeed_delay 19000`, `io_is_busy 1`, cpubw
`bw_hwmon` / mincpubw `cpufreq`, `read_ahead_kb 128`, kernel default I/O scheduler (`noop` — the
`sys.io.scheduler=bfq` prop has no consumer).

`msm_thermal` `core_control` is off entirely, not just raised to 90 °C: this kernel deletes a
CPU's `cpufreq/` directory when the core goes offline, so an in-flight `time_in_state` read blocks in
uninterruptible sleep while BatteryStats holds its global lock, and the watchdog kills system_server.
thermal-engine mitigates by capping frequency instead.

The zram row is not a preference. Nextbit shipped 512 MB of swap; the LineageOS tree dropped it,
and AOSP stopped calling `swapon_all` from `init.rc` anyway, so nothing this tree declared would have
mounted. On a 3 GB phone, the alternative to swap is killing processes.

Beyond the tuning, this build restores or adds:

- **The rear LED cluster.** `RobinLed` pulses the rear "cloud" LEDs at a rate scaled to how many
  notifications are waiting, and doubles as a charge gauge. The lights HAL gives the rear cluster up
  so there is exactly one writer to it. The stock boot chase runs again too: Android 13 refuses a
  vendor rc that triggers on `init.svc.bootanim`, so that action now lives in a system rc.
- **Correct still photos.** The stock HAL asks the JPEG encoder to rotate, which that encoder cannot
  do, so captures fell back to software and came out with the sensor's dimensions transposed and the
  frame repeated in bands. Preview was always correct, which is what made it look like a working
  camera.
- **adb over USB**, on a kernel with no FunctionFS AIO — which is otherwise impossible.
- **Fulguris, F-Droid and K-9 Mail**, each on its own switch; and **the Nextcloud bundle** — Files,
  Talk, push, Deck, Passwords, Notes, CalDAV/CardDAV and Tasks — for the phone that was sold on
  living in the cloud.
- **The Robin's look** — the Nextbit teal (#009D94) as the system accent, seeded as a Monet preset
  so it survives wallpaper changes; nav-bar glyphs redrawn as scalable tintable vectors (recreations,
  not extracted artwork, so they ship on every build); a hotseat-only home screen; no Google feed
  page; themed icons; dark theme by default; NFC and LiveDisplay tiles in Quick Settings.
- **Optionally the phone's own assets** — the original Nextbit sounds, wallpapers and boot animation,
  reclaimed at build time from your own copy of the stock ROM. Off unless you ask for it.

## Status

| | |
|---|---|
| WiFi | connects, DHCP, internet |
| Bluetooth | enables and stays on |
| Camera | captures correctly; front/back switch is immediate |
| Audio | working |
| LEDs | rear cluster: notification pulse, charge gauge, boot chase |
| Flashlight | working — driven through the CCI flash subdev, not the PMIC (`FLASHLIGHT.md`) |
| LiveDisplay | colour calibration works; monochrome mode has no visible effect |
| adb | USB (wireless via Developer options, as stock) |
| Cellular | LTE data, SMS, visual voicemail, VoLTE (verified on T-Mobile US); no Wi-Fi calling or video calling — see *Known issues* |

**This tree is staged, not proven.** It starts as an exact copy of the working 20.0 series
([ether-lineage-20.0-volte](https://github.com/TheDBP/ether-lineage-20.0-volte)) with the branch,
base ref and lunch target pointed at 21.0. The 75 patches have **not** been rebased onto 21 and
nothing here has been built or flashed. Everything below describes the 20.0 build it came from and
should be read as the starting point, not the state.

21 is the last version this device will get: LineageOS 22 needs a kernel of at least 4.19 and this
one is 3.10.

**20.0 ships first; 21 follows straight after, and 21 is the end of the line.** LineageOS 22 needs a
kernel of at least 4.19 (`NetBpfLoad` exits on anything older) and the Robin's is 3.10.

## The one thing to understand

Nearly every bug on this port had the same root cause: **a 2016 kernel meeting a 2022 userspace**.
Android 13 assumes a kernel far newer than 3.10, and each assumption failed differently:

| assumed | arrived in | what broke |
|---|---|---|
| cgroup v2 | Linux 4.5 | `libprocessgroup` — nothing booted |
| `bpf()` syscall | Linux 3.18 | netd crash-loop, then `system_server` aborting repeatedly per boot |
| `IFA_FLAGS` netlink attribute | Linux 3.14 | **WiFi** — every address notification silently discarded |
| FunctionFS AIO | Linux 3.15 | USB adb impossible |
| RT bandwidth per cgroup | — | `SCHED_FIFO` unavailable system-wide; Bluetooth aborted |


## Known issues

- **No Wi-Fi calling.** VoLTE works; Wi-Fi calling does not, and every layer outside the modem
  firmware has been eliminated. The framework delivers the enable correctly, and the modem's own EFS
  already carries the T-Mobile ePDG address, the IKEv2 parameters and a PDN policy permitting IWLAN
  for the IMS bearer. The modem acknowledges the setting and then never attempts a tunnel — no ePDG
  DNS, no IKE, no ESP — and errors on the QMI request that would configure handover. What remains is
  a flag inside the firmware build. Full account in `VOLTE-BRINGUP.md` §8.
- **No video calling.** Switched off deliberately rather than broken: `lib-imsvt.so` imports
  `IOMXObserver` and `IGraphicBufferAlloc`, platform interfaces deleted when OMX moved to
  HIDL/Codec2, among 61 unresolved symbols. Removed subsystems are not shimmable.
- **`CNEService` crashes on every Wi-Fi/mobile transition.** Android 7 blob calling
  `INetworkPolicyManager.getNetworkQuotaInfo`, removed in 12. Restarts itself; nothing depends on it.
  Fix: drop the APK from `proprietary-files.txt`, keep `cnd`.
- **LiveDisplay monochrome does nothing.** Colour calibration works; the monochrome toggle has no
  visible effect.
- **`use_sched_load` reads back 0** after the tuning writes 1, on both clusters, also when written
  by hand as root. Harmless.
- **`vendor.qcom.PeripheralManager` never registers.** Nothing depends on it.

## Installing

Prebuilt images are on the [Releases](https://github.com/TheDBP/ether-lineage-21.0-volte/releases) page, as
the `libre` preset and, from the same build, `clean`:

- `libre` — LineageOS plus F-Droid, Fulguris, K-9 Mail, KDE Connect, TermOne Plus, ConnectBot,
  Linphone and the Nextcloud
  bundle (Files, Talk, NextPush, Deck, NC Passwords, Notes, DAVx5, Tasks). The Robin was sold as
  the cloud-first phone; this is that, pointed at a server you own.
- `clean` — LineageOS with only the shared defaults, nothing bundled.

Neither has Google apps, root, or any of Nextbit's own artwork.

You need: a Robin on stock Nougat (`Robin_Nougat_108` or later) or on LineageOS 18.1 — both
tested; other starting points untested — and `adb` and `fastboot` from Android platform-tools. Each
preset is two files: the ROM zip and a `<name>-recovery.img` (Lineage recovery from the same build)
— no TWRP. Everything on the phone is erased.

1. **Unlock the bootloader** (skip if already unlocked). Settings → About → tap *Build number* five
   times; Developer options → enable *OEM unlocking* and *USB debugging*. Then
   `adb reboot bootloader` and `fastboot oem unlock`, confirm on the phone. The phone wipes itself
   and reboots.
2. **Flash and boot the recovery.** Back in the bootloader (`adb reboot bootloader`, or hold
   Volume Down while powering on):
   `fastboot flash recovery lineage-20.0-<date>-UNOFFICIAL-turbo-libre-ether-recovery.img`, then
   `fastboot boot lineage-20.0-<date>-UNOFFICIAL-turbo-libre-ether-recovery.img` (the
   `turbo-clean` one for that preset). (This bootloader ignores `fastboot reboot recovery` and boots the system; boot the image directly.)
3. **Factory reset.** *Factory reset → Format data / factory reset*. Required coming from stock or
   another ROM, and again on any update that changes signing keys.
4. **Sideload the ROM.** *Apply update → Apply from ADB*, then on the computer
   `adb sideload lineage-20.0-<date>-UNOFFICIAL-turbo-libre-ether.zip`. Signature verification
   takes about a minute before the install starts.
5. **Reboot** to system. First boot takes about a minute; the rear LEDs chase while the animation
   plays. A lingering animation with no chase means something is wrong, not slow.

Updating from one of these builds to a newer one: `adb reboot recovery`, step 4, reboot; no wipe.
The zip does not write the recovery partition — repeat step 2 with the new image if you want the
recovery from the same build.

Want Google apps or root? Build the `full` preset yourself (below); those images are not
published.

## Building

> **VoLTE needs the Robin's stock ROM, which cannot be shipped here.** It is Nextbit's own Nougat
> IMS stack rebuilt to bind to a modern `ImsService` — proprietary blobs, so this repo carries the
> recipe and none of the ingredients.
>
> Leave it out and **the build still works** — it just ships without VoLTE, says so while it runs,
> and names the image `-novolte`. Asking for `volte` explicitly without the zip stops the build
> rather than handing you an image that cannot place a call.
>
> Drop a `Ether_Stock_ROM_*.zip` (Nextbit `Robin_Nougat_108` or later) in the **root of this repo**;
> the name must match that glob. The first build stages the IMS blobs out of it automatically (~2
> min) and later builds skip straight past. To re-stage, delete `build_output/src/vendor/ims-blobs`.
>
> `STOCK_ROM=` and `STOCK_ROM_URL` do **not** apply to this: those feed the `oem` option only. The
> IMS staging looks in the repo root and nowhere else.
>
> Why it is staged by the build rather than listed as a prerequisite, and what the staging does:
> [VOLTE-BRINGUP.md](VOLTE-BRINGUP.md) §7.

One command, one image.

```sh
PRESET=clean ./forge/bootstrap.sh    # plain LineageOS + the tuning (IMS included, as everywhere)
PRESET=libre ./forge/bootstrap.sh    # + F-Droid, Fulguris, K-9, the Nextcloud bundle, still no Google
PRESET=full  ./forge/bootstrap.sh    # + GApps, root, Fulguris, F-Droid, K-9, the Nextcloud bundle
PRESET=robin ./forge/bootstrap.sh    # the Nextbit look and root, no Google
```

Output lands in `build_output/src/out/target/product/ether/`.

`PRESET` names a saved set of options; `OPTIONS="root nav-icons"` picks them directly. `OPTIONS`
**replaces** the list rather than adding to it — `COMMON_OPTIONS` is not merged in, so an ad-hoc set
is the whole set.

Options live in the forge (`forge/options/`) and work the same on every device. What lives in this
repo's `overlay/patches/` is only what is true of this phone.

To publish a build use `./forge/tools/release.sh` rather than uploading a zip by hand — it refuses
anything carrying GApps or reclaimed manufacturer assets, and checks the image rather than the label.
See [rom-forge docs/RELEASING.md](https://github.com/TheDBP/rom-forge/blob/main/docs/RELEASING.md).

## Presets

One build command produces one image. A preset is a saved selection of options — it has no
behaviour of its own.

| preset | tag | adds over `clean` |
|---|---|---|
| `clean` | `turbo-clean` | nothing — this is the baseline |
| `libre` | `turbo-libre` | `fdroid`, `k9`, `kdeconnect`, `nextcloud`, `connectbot` |
| `robin` | `turbo-robin` | `oem`, `root` |
| `full` | `turbo` | `gapps`, `fdroid`, `k9`, `kdeconnect`, `nextcloud`, `connectbot` |
| `stock` | `stock` | synthetic: **not** the shared set. Device patches plus `setup-mobile-data` and nothing else — the smallest thing that boots and works |

Every preset except `stock` also carries the shared set, which is what makes this build look and
behave the way it does regardless of which preset you pick:

`advanced-restart` `dark-default` `google-feed-off` `home-defaults` `linux` `livedisplay-off` `minimal-home` `nav-icons` `setup-mobile-data` `setupwizard-lineage` `setupwizard-nag-skip` `teal-skin` `teal-wallpaper` `themed-icons`

`oem` is in no preset. `EXTRA_OPTIONS` adds an option to whichever preset you build, and every
option added that way appends its name to the tag:

```sh
EXTRA_OPTIONS=oem PRESET=full ./forge/bootstrap.sh      # tag turbo-oem
```

Set `EXTRA_OPTIONS="oem"` in `device.conf.local` (gitignored) to get it on every build from this
checkout. Those images carry reclaimed manufacturer assets and are for your own phone.

## Options

Every option this device uses, and what each one does. They live in `forge/options/`, so they
work on any device rather than being wired into this tree.

<!-- options:start device -->

| option | what it does |
|---|---|
| `bringup` | adbd from boot with no authorisation prompt, plus persistent logcat, so a build that never reaches the lock screen can still be traced. **Never hand out an image built with this** — it accepts adb from any host. |
| `connectbot` | ConnectBot: an SSH client with saved hosts, keys and port forwarding. |
| `dark-default` | Default to dark theme. |
| `drm-trace` | Diagnostic: kernel trace of whoever disables a DRM plane or CRTC, for a panel that dies while the framework still thinks it is on. Its kernel patch needs atomic KMS, which this 3.10 kernel does not have, so here it warns and is skipped. |
| `fdroid` | F-Droid app store + Privileged Extension (silent installs/updates). |
| `firefox` | Firefox (Fennec F-Droid) as the browser, replacing Jelly. Mutually exclusive with `fulguris`. **In no preset**: it overrides Jelly, and stages 320 MB against Fulguris's 9. |
| `fulguris` | Fulguris as the browser, replacing Jelly. A WebView browser, 9 MB where Fennec stages 320 MB. Mutually exclusive with `firefox`. **In no preset**: it overrides Jelly, so a preset carrying it ships the only browser in the image, and its first run asks you to accept terms with nothing else able to open them. |
| `gapps` | Google apps: Play Store and GMS from MindTheGapps, plus Google's versions of the stock apps. |
| `k9` | K-9 Mail (the Thunderbird for Android codebase) as the mail client. |
| `kdeconnect` | KDE Connect (phone <-> desktop: notifications, clipboard, files, remote input). |
| `linphone` | Linphone: a SIP client, for voice over data where the device has no VoLTE. |
| `linux` | On-device Linux environment (chroot + Docker): container kernel config and cgroup fixes. The cgroup symlink patch is off here: this 3.10 kernel predates kernfs. |
| `nav-icons` | Nextbit Robin style nav-bar icons, drawn as scalable tintable vectors. |
| `nextcloud` | Nextcloud bundle: Files, Talk, NextPush, Deck, NC Passwords, Notes, DAVx5, Tasks — the current F-Droid build of each. ~600 MB against `nextcloud-core`'s ~270. Check the partition before adding either. |
| `nextcloud-core` | Nextcloud, the four that make the phone a client: Files, Talk, NextPush, DAVx5 — the current F-Droid build of each. Mutually exclusive with `nextcloud`, which already carries these four. |
| `oem` | The manufacturer's own boot animation, wallpapers and sounds, reclaimed from its stock ROM. Needs that phone's own stock ROM and a pack that understands its layout — see `forge/docs/OEM-ASSETS.md`. |
| `root` | Magisk baked into the boot image, so the zip flashes pre-rooted. Pulls in `termoneplus`. The image flashes pre-rooted, so treat it like one. |
| `setup-mobile-data` | Mobile data usable during setup, instead of a sign-in page with no way online but Wi-Fi. |
| `syncthing-fork` | Syncthing-Fork: continuous file sync between your own devices, no server or account. |
| `teal-wallpaper` | Teal-shag default wallpaper (baked into framework-res). |
| `termoneplus` | TermOne Plus terminal emulator (F-Droid build). |
| `volte` | The manufacturer's own IMS stack, rebuilt from its stock firmware, so the phone can place calls over LTE. Turns itself on when the phone's stock firmware is present and off when it is not, marking the build tag `-novolte` — see `forge/options/volte/README.md`. |

<!-- options:end -->
## Device patches

75 patches across 20 upstream projects, applied at build time from `overlay/patches/`. Nothing
here is a fork: each is a single commit against the upstream tree, replayed on every build, so
upstream stays upstream and what we changed stays legible. One patch per thing it enables. Each entry
below: what broke → what the patch does → what it costs.

The device series is ordered in families rather than chronologically, so related work reads together: port and tuning, panel density, device features, modem bring-up, display and camera, wifi and USB, audio, IMS and VoLTE, the IMS capability advertisement, then CNE and the property/denial batches. No patch undoes an earlier one, with one deliberate exception noted on `0030`.

### `build/make`

- **build: warn instead of failing on a presigned APK with compressed libs** — the compression
  check ran on the copy-verbatim path and, on failure, pushed a presigned APK onto the rewriting
  path, which broke its v2 signature; PackageManager then dropped it silently at boot (no Firefox,
  no F-Droid, no Contacts, two dead dock tiles). Warn and copy verbatim: an APK with
  `extractNativeLibs=true` is entitled to compressed libs.

### `build/soong`

- **soong: expose `preprocessed` on `android_app_import`, so a presigned APK ships untouched** —
  uncompressing libs/dex and zipaligning rewrote the archive and invalidated the whole-file v2
  signature (Firefox 127 MB → 242 MB, Sig Block gone, not installed). Backports the later Soong
  property so the file is installed byte-for-byte.

### `device/lineage/sepolicy`

- **sepolicy: exclude pre-UM platforms from the `vendor_` m4 renames again** — 20.0 dropped the
  filter, so msm8992 got a half-rename (`vendor_hal_perf_default_exec` unknown) and the policy did
  not compile. Restores the 19.1 exclusion list; the deleted `qcom/legacy-vendor` dir is not
  restored because its only rule names a `pps` type 20.0 lacks.

### `device/nextbit/ether`
- **0001 Android 13 port — drop what 20.0 removed, pick the OSS WCNSS client** — modules 20.0
  deleted or folded (`audio.a2dp.default`, Snap, cryptfshw, `libhidltransport`,
  `libcnefeatureconfig`, the local libhidl shim, dead manifest entries) each failed the build or
  boot. Removes them; sets `WCNSS_QMI_OSS` because 20.0's `wcnss-service` no longer falls back to
  the open-source path and would link proprietary QMI libs this tree lacks.
- **0002 turbo tuning — thermal ceilings, big-cluster governor, real zram swap** — what the tag
  means; values in the table above. Restores Nextbit's ladders where 18.1 was more conservative
  than stock; `swapon_all` is called from `init.qcom.rc` because AOSP's `init.rc` stopped doing it
  and the declared 768 MB zram never mounted; perfd's sepolicy rule lives here because without it
  the scheduler tuning silently does not apply.
- **0003 tag the build turbo (`TARGET_UNOFFICIAL_BUILD_ID`)** — "turbo" in the zip name and
  `ro.lineage.version`; `TURBO_BUILD_ID` overrides it per preset.
- **0004 sepolicy for modem bring-up, wifi, LiveDisplay and logging** — 2016 blobs against a 2022
  policy: rild/qmuxd, netmgrd/wcnss_service property access, LiveDisplay → mm-pp-daemon, and their
  file/property contexts. Denials were silent (no modem, no LiveDisplay, no logs). vendor_init's
  rule is the compilable subset — the original named a type 20.0 lacks.
- **0005 320 dpi** — the 5.2" 1080p panel is 424 dpi; upstream's 480 rendered a size too large.
  320 is the bucket that buys usable width, and xxhdpi assets still apply.
- **0006 `def_font_scale` 115% for the 320 dpi panel** — read by the SettingsProvider patch via
  `loadFractionSetting`. 320 dpi buys 540 dp of width, which dense layouts need, at the cost of
  physically small text on 5.2 inches.
- **0007 RobinLed — the rear cloud LED as a notification and battery indicator** — a
  NotificationListener that pulses at a rate scaled to outstanding notifications and shows charge
  level; liblight gives the rear cluster up so there is one writer. The boot chase moves to a
  system rc because A13 drops vendor-rc triggers on `init.svc.bootanim`, and writes the resolved
  sysfs path because init cannot read the `sysfs_leds`-labelled link.
- **0008 Firefox and F-Droid prebuilt modules, each on its own switch** — gated on the forge
  option (`WITH_FIREFOX` / `WITH_FDROID`) and on the APK being present, so a stale APK never leaks
  into a build and a missing one never fails the parse. Firefox overrides Jelly; it is no longer
  tied to `WITH_GAPPS`.
- **0009 default wallpaper via `ro.config.wallpaper`, OEM pack overrides it** — the property points
  at whatever the wallpaper option staged, sidestepping the framework-res RRO not reaching first
  boot. No option: unset, upstream default. `WITH_OEM`: points at `OEM_DEFAULT_WALLPAPER`.
- **0010 QS tile layout and RobinLed listener access** — NFC and LiveDisplay tiles in the default
  QS layout (fresh install only); auto-granted listener access for `com.nextbit.robinled`. Accent
  overlay dropped (Monet preset via `teal-skin` instead); dead DeskClock widget override dropped;
  no theme default here (the forge's `dark-default` sets it in `frameworks/base`, and a device
  overlay would silently win).
- **0011 drive the flashlight through the flash subdev, not the PMIC** — the torch never emitted light
  while every write succeeded and the tile reported on, because `QCameraFlash` was writing PMIC sysfs
  nodes that nothing on this board is wired to. Three stacked faults; full account in `FLASHLIGHT.md`.
- **0012 volume panel by the keys** — the volume dialog moves to the left edge, offset −150 dp, so it
  appears beside the physical keys rather than centred. The rocker sits at about 34% of screen height;
  −150 dp is a measured correction to a first fit of −180 dp. First-boot default only, Settings wins.
- **0013 bring the modem up, and stop rild crashing on the way** — no working peripheral manager.
  (a) The 2016 `libperipheral_client.so` stack-allocates two `Parcel`s at 2016's `sizeof`; the
  current one is larger and the store hits the stack canary, so rild aborted on every start. A shim
  scoped to `libril-qc-qmi-1.so` returns failure from the five `pm_client_*` entry points, which the
  RIL handles by skipping ESOC setup the internal modem does not need. (b) Nothing called
  `subsystem_get("modem")`; `ether_modem_hold` (class core) opens and holds `/dev/subsys_modem`
  — rild cannot, it is uid radio and the node is 0640 system — so PIL loads the firmware and
  `smdcntl0`/qmux appear.
- **0014 stop asking the JPEG encoder to rotate — it cannot** — `needJpegRotation()` returned true
  unconditionally; the hardware encoder refused, the software fallback transposed the dimensions
  and banded the frame. Rotation is already covered by `CAM_QCOM_FEATURE_ROTATION` in the CPP.
- **0015 stop mm-pp-daemon spinning a core on an uninitialised poll fd** — the daemon polls two
  descriptors and initialises one; `POLLNVAL` returns at once, ~6700 calls/s, 98 % of a core from
  boot (stock has the same bug). Shim rewrites fds that `fcntl()` rejects with `EBADF` to -1.
  Injected via `TARGET_LD_SHIM_LIBS` on `libdisp-aba.so` with `-z global` so it precedes libc;
  `LD_PRELOAD` is ignored under `AT_SECURE` after the domain transition.
- **0016 stop the camera daemon aborting on a double mutex destroy** — the ISP blob destroys a
  mutex twice; A7 bionic returned an error, A13 bionic aborts (eight tombstones a boot). Shim
  scoped to `mm-qcamera-daemon` makes `pthread_mutex_destroy` a no-op — safe, the struct is
  caller-owned with nothing to leak. Cost: real mutex misuse in that one daemon goes unreported.
- **0017 let the gatekeeper and composer HALs read the properties they poll** — gatekeeper reads a
  `system_prop` at startup; denied, `IGatekeeper/default` never registers and `system_server` waits
  forever (boot animation with no crash). The composer HAL polls the bootanim property; denied reads
  spin at hundreds per second for the whole hang.
- **0018 disable PMF so the WPA handshake can complete** — the framework asks for `RequirePmf=false`,
  but the AOSP template sets a global `pmf=1` and wpa_supplicant upgrades that to *required* whenever
  the AP advertises MFP. The prima/qcacld driver cannot do PMF, so msg 3/4 never arrives and the
  handshake times out — reported as "pre-shared key may be incorrect", which it is not. 19.1 worked
  because it used the HIDL supplicant HAL; 20.0's AIDL one does not pass `RequirePmf` through as
  `ieee80211w=0`. Cost: no WPA3-SAE, which this driver cannot do anyway.
- **0019 let wcnss_filter hold a wakelock** — `/sys/power/wake_lock` needs `CAP_BLOCK_SUSPEND`;
  sepolicy allowed it, the rc never asked. Every acquire failed EPERM (~1/s) and BT traffic could
  not keep the SoC awake. `capabilities BLOCK_SUSPEND` on the service.
- **0020 enumerate once when switching USB to adb** — `init.nbq.usb.rc` duplicated AOSP's
  `sys.usb.config=adb` block (configfs is 0 here), so every switch enumerated twice (18d1:4EE7 then
  2C3F:0009) with a full adbd transport tear-down between. Device copy removed; mtp/ptp/rndis/midi/
  diag stay, they have no AOSP counterpart.
- **0021 let the ACDB calibration paths be set** — `vendor_init` was refused `audio_prop`, so the
  seven `persist.audio.calfile*` paths `init.qcom.rc` sets from this device's own ACDB data all read
  back empty, and the audio HAL had been running on generic calibration since the port began.
- **0022 IMS daemons, JNI symlinks and denial-derived sepolicy** — `init.target.rc` carries the four
  IMS services from ether's own stock ramdisk with the two-stage property handshake they expect, plus
  the sepolicy their denials asked for. `device.mk` also stages the IMS blobs from the stock ROM at
  product-config time rather than expecting someone to have run `extract-ims-blobs.sh`: that
  directory sits outside `vendor/extra` so the overlay clear never touches it, and a tree where the
  script had run kept producing ROMs with IMS while a fresh clone produced ROMs without and said
  nothing. A hard include means a build that could not stage them stops.
- **0023 the 7.1 legacy IMS AIDL surface, generated and verified on the wire** — all fourteen legacy
  interfaces, generated from the stock 7.1 binary rather than typed: `IImsCallSession` (28
  transactions), `IImsCallSessionListener` (30), `IImsUt` (18), `IImsVideoCallProvider` (11) and the
  rest — 148 in total, plus seven parcelables whose wire order is not their declaration order. AIDL
  numbers transactions by declaration order and the far end is compiled 2016 code, so the order is
  load-bearing; a verifier checks the *built* apk against the stock binary so a mistake cannot pass.
- **0024 ImsBridge — bind the 7.1 `ims.apk` to the modern telephony stack** — `ims.apk` implements
  `com.android.ims.internal.IImsService`, the pre-P binding Android 9 deleted.
  `frameworks/opt/telephony` still carries the compat path, so the bridge presents a modern
  `ImsService` and delegates to the legacy one, absorbing the shape difference that 7.1 is
  serviceId-keyed while an MMTelFeature instance already implies a session. Six sub-interfaces get a
  wrapper apiece: `CallSessionWrapper` delegates all 28 legacy call-session methods onto
  `ImsCallSessionImplBase`, whose no-op defaults cover everything 13 added (RTT, transfer, call
  quality) that 7.1 has no notion of, and `CallSessionListenerAdapter` carries the 30 callbacks back.
- **0025 ship the rebuilt `ims.apk` and let ImsResolver find the bridge** — three things that do not
  work apart: the apk imported rather than copied (AOSP rejects APKs in `PRODUCT_COPY_FILES`), signed
  with the platform key because it declares `sharedUserId=android.uid.phone`, and the resolver config
  that points at the bridge.
- **0026 ship nanopb 0.2.8 for the QTI RIL blob** — `libril-qc-qmi-1.so` imports
  `pb_encode`/`pb_decode` rather than carrying its own nanopb, and its descriptors were generated
  against 0.2.8, the version 7.1.1 shipped. Modern nanopb inserted `PB_LTYPE_BOOL` and shifted every
  other `PB_LTYPE_*`, so a newer copy decodes every field as the wrong type.
- **0027 load the VT natives** — `libimsmedia_jni.so` imports a two-argument
  `android::Surface::Surface`; 13 has only the three-argument form, so the symbol resolves nowhere and
  ImsMedia's static initialiser takes the process down at `ImsService.onCreate`. A shim lets `init()`
  build its singletons. It is only safe because `extract-ims-blobs.sh` separately rewrites the blob's
  allocation — `sizeof(Surface)` grew 3560 → 8168 bytes. Video calling itself is not coming back: 61
  unresolved symbols against subsystems that no longer exist. The boolean that turns it off is set
  with the other capability booleans, in 0031.
- **0028 do not block on incoming-call delivery (legacy IMS deadlocks the main thread)** —
  `ImsPhoneCallTracker.onIncomingCall` defaults to `executeAndWait()`, i.e.
  `CompletableFuture.runAsync(task, mExecutor).join()`, which deadlocks against the legacy bridge's
  binder thread and loses the call.
- **0029 wire up the IWLAN data path, which this modem never uses** — kept for the record rather than
  because it works: the modem stores and acknowledges the configuration (`wifi_call: 2`) and never
  registers an ePDG. 0031 is what actually turns the feature off; the full account is
  `VOLTE-BRINGUP.md` §8.
- **0030 read back what the vendor IMS config will actually admit** — the vendor `ImsConfigImpl`
  validates every item against a fixed set and refuses everything else as "Invalid API request for
  item". A sweep behind `persist.ether.ims.configprobe` reads every item, and a refused
  `setProvisionedValue` is now logged instead of reading as a completed set.
- **0031 advertise what this modem can actually do over IMS** — the three device-capability booleans,
  the per-carrier legs, and the CarrierConfig bundle, in one patch because they are one decision
  expressed in four files. The device leg is unqualified and deliberately not under an `mcc`/`mnc`
  directory: `isVolteEnabledByPlatform()` ANDs it with the carrier leg, so qualifying it by carrier
  refused every network except the two we had directories for. Android also resolves those qualifiers
  from the SIM, not the serving network — Mint reads 310240 while the network reads 310260 — so both
  directories carry only genuinely per-carrier values. volte true; vt false, because `lib-imsvt.so`
  cannot be shimmed back; wfc false, because the modem never attempts an ePDG tunnel and a newer
  modem build will not load. A toggle that appears and then fails every time is worse than none.
- **0032 let the Connectivity Engine read its own configuration** — CNE tells the RIL which data
  technology to prefer and is the only path by which IWLAN becomes a candidate at all. It could not
  read one of its own `persist.cne.*` properties; the measured result was `pref data tech` moving from
  `UNKNOWN` to `LTE`.
- **0033 finish the CNE property access** — `CNEService` reads the same properties `cnd` does, and
  giving them their own type moved them out of its reach too, so the framework half of CNE lost access
  that relabelling was never meant to take. Same rule, same type. The app is hosted in the
  `.dataservices` process, which is why it does not show up as "cne" in `ps` and is easy to believe
  dead. `persist.vendor.cnd.iwlan` is set here, worth doing only now that CNE can read that space.
- **0034 label the properties fifteen denials were actually asking for** — fifteen avc denials on
  property reads across ten domains. A denial names the domain and the type but never the property, so
  it read as fifteen separate bugs; labelling the prefixes fixed them as one.
- **0035 grant the two boot denials that can be expressed, explain the two that cannot** —
  `robinled_app` traversing `/data` (search only, no listing and no read of anything inside), and
  `ueventd` reading `/proc/device-tree/compatible`, given its own type and `genfscon` rather than
  granting read on all of `proc`. `storaged`'s read of `sysfs_disk_stat` cannot be written from a
  device tree at all: the rule needs a platform-private domain *and* a vendor-declared type, and
  neither policy segment may name both — attempting it fails the build with `unknown type storaged`.
  `init`'s write to `discard_max_bytes` is not granted either, because the file is read-only on this
  kernel and the writer is upstream AOSP's own `init.rc`.

### `frameworks/base`

- **hwui: never block a binder thread on the RenderThread's draw lock** — launcher/SystemUI froze
  for exactly 4 s. This Adreno lacks `EGL_EXT_buffer_age`, so RenderThread dequeues inside `draw()`
  under `mFrameMetricsReporterMutex`; SurfaceFlinger's oneway `onTransactionCompleted` blocked on
  that lock on a binder thread, never sent `BC_FREE_BUFFER`, and the binder driver parked every
  later oneway — including the release RenderThread was waiting for — until the 4000 ms dequeue
  timeout. `onSurfaceStatsAvailable` now posts to the RenderThread. Invisible on drivers that
  dequeue in `getFrame()`, which is why upstream never saw it.
- **SystemUI: tolerate a null list from `getPackagesForOps`** — `AppOpsService` returns null on a
  first boot after a wipe; SystemUI NPE'd three times in `KeyguardService.onCreate`.

### `frameworks/libs/net`

- **bpf: do not abort when a pinned map cannot be opened** — no `bpf()` syscall on 3.10, so the
  `BpfMap` pinned-path constructor aborted `system_server` the first time anything asked for
  interface stats (fifteen restarts a boot, then RescueParty). Leaves the fd invalid so the
  existing `isValid()` checks run. `createMap()` still aborts. Cost: no per-UID accounting, no BPF
  firewall.
- **netlink: do not require `IFA_FLAGS`, which predates Linux 3.14** — the parser rejected every
  `RTM_NEWADDR` from a 3.10 kernel, so IpClient never saw the address, provisioning never
  completed, and WiFi dropped after 18 s holding a valid lease. Falls back to the 8-bit flags in
  `ifaddrmsg`. This was the actual WiFi blocker.

### `frameworks/native`

- **binder: ignore a threadpool shrink instead of aborting** — the passthrough audio HAL configures
  a pool of 16, then the A11 vendor HAL asks for fewer; `setThreadPoolMaxThreadCount` treated the
  shrink as fatal, `IDevicesFactory` never registered, and the watchdog killed `system_server` on
  the boot animation. Keeps the larger bound (a few idle threads).

### `hardware/qcom-caf/msm8994/display`

- **msm8994 display: drop libbfqio (removed from LineageOS after 18.1)** — the HAL still linked the
  compat shim and ckati failed (`hwcomposer.msm8992 missing libbfqio`). Same change upstream made
  for msm8996. Cost: the vsync thread loses realtime IO priority.

### `hardware/ril`

- **0001 libril: stop exporting nanopb so the QTI blob can bind its own** — `libril-qc-qmi-1.so`
  carries no nanopb; it imports `pb_encode`/`pb_decode` and hands over message descriptors generated
  against nanopb 0.2.8, the version 7.1.1 shipped. Between 0.2.8 and 0.3.x nanopb inserted
  `PB_LTYPE_BOOL` at 0x00 and shifted every other `PB_LTYPE_*` up, so the platform's newer nanopb
  decodes every field of those descriptors as the wrong type. Not exporting the symbols lets the blob
  bind the 0.2.8 copy that ships beside it.

### `kernel/nextbit/msm8992`

- **0001 uapi: drop the `sockaddr_storage` alias that collides with A13 bionic** — A13's bionic
  declares the struct itself, so the exported header's alias became a redefinition and
  `libbt-vendor` would not compile. Alias removed as upstream Linux later did; `#ifndef __KERNEL__`,
  so the kernel is unaffected.
- **0002 enable the memory and blkio cgroup controllers** — A13 libprocessgroup mounts both at early
  init; neither was in the defconfig (18.1 never needed them).
- **0003 give pmsg more of the 2 MB pstore reservation** — 512 K pmsg wrapped after two boot-loop
  cycles and lost the first crash. Raised to 832 K from spare dump-record space; ftrace left at 64 K
  (a zero-size zone is an untested path in this driver).
- **0004 disable `RT_GROUP_SCHED` so `SCHED_FIFO` works in cgroups** — child cgroups default to
  zero RT runtime, so no Android process could use `SCHED_FIFO`; Bluetooth aborted in
  `timer_create` on every enable (camera-daemon was in the same position). What current Android
  kernels do.
- **0005 let the GPU governor react to UI, not just sustained 3D** — msm-adreno-tz's jump-to-max
  needed >95 % busy, >25 ms frames, 50 ms accumulated: game constants. Measured 30 s of UI: 69.7 %
  at 180 MHz, 0 % above 367 MHz, dropping frames. Now 80 % / one vsync / 25 ms; 180 MHz floor
  unchanged.

### `packages/apps/Settings`

- **0001 Settings: do not poll VoNR on a radio that predates NR** — opening SIM settings ANRs on
  msm8992. `NrAdvancedCallingPreferenceController.init()` creates its `TelephonyCallback` before any
  capability check, and `onStart()` registers it whenever it is non-null, so the callback runs even
  though `getAvailabilityStatus()` has already returned `CONDITIONALLY_UNAVAILABLE`.

### `packages/modules/Bluetooth`

- **Bluetooth: allow disabling the LE vendor capabilities query** — old WCNSS controllers echo
  vendor HCI opcodes with the OGF dropped; HciLayer's strict match aborted on every enable once
  APCF commands started. `bluetooth.core.le.vendor_capabilities.enabled=false` skips the query.
  Cost: no offloaded scan filtering or batch scanning; alternative was no Bluetooth.

### `packages/modules/Connectivity`

- **0001 tolerate a kernel with no eBPF instead of crash-looping netd** — 19.1's netd fallback
  re-homed: A13 moved socket tagging here. `BpfHandler::init()` probes instead of requiring; on
  failure `tagSocket`/`untagSocket` return 0. No legacy qtaguid path exists on A13 to fall back to.
  Cost: no per-UID data usage, no BPF firewall, no tethering offload.
- **0002 do not throw on ENOSYS from a kernel with no eBPF** — `maybeThrow()` turned every ENOSYS
  (113 a boot) into a `ServiceSpecificException` that unwound network setup before
  `networkCreate()`; WiFi got a lease and never provisioned. Log and continue.
- **0003 report empty stats, not an error, when there is no eBPF** — fourth layer: the stats parser
  turned ENOSYS into `IOException` → `IllegalStateException` out of `updateLinkProperties()`, same
  symptom. Both parse entry points return 0 with no stats.

### `packages/modules/adb`

- **adb: a USB path that works on a kernel without functionfs AIO** — 3.10 has no FFS AIO, so
  adbd's default connection submitted reads that never completed ("unauthorized" forever). Restores
  a blocking `UsbFfsBlockingConnection` behind `BlockingConnectionAdapter` (own reader/writer
  threads, so a host that stops draining never blocks the fdevent loop); treats a zero-length bulk
  read as framing, not EOF; closes by signalling each blocked thread until it leaves its syscall
  (`sigaction` without `SA_RESTART`, `unix_read_interruptible`/`adb_writev`, because the wrappers
  retry on EINTR). This f_fs returns ENODEV after a DISABLE until reopened, so every enumeration is
  a fresh transport.

### `system/bpf`

- **0001 bpfloader: do not reboot when bpfloader fails on a kernel without eBPF** — the 19.1
  one-liner, rebased past an A13 comment block that broke the context.
- **0002 bpfloader: publish `bpf.progs_loaded` even when the kernel has no eBPF** — the 19.1
  `break` still applied cleanly but A13 added a map self-test after it that returns before
  `SetProperty`, so every `waitForProgsLoaded()` caller hung and the device sat on the boot
  animation. Self-test gated behind `bpfUnsupported`; untouched on hardware with eBPF.

### `system/core`

- **0001 libprocessgroup: describe a cgroup-v1-only layout for msm8992** — 3.10 cannot mount
  `cgroup2`; the v2 root in `cgroups.json` failed and ueventd died 3.5 s in
  (`bootstrap-apexd-failed`). v2 root dropped; `freezer` re-declared as an Optional v1 controller
  at `/dev/freezer`. `/vendor/etc/cgroups.json` cannot do this — it merges, it cannot remove.
- **0002 libprocessgroup: treat a missing cgroup hierarchy as a no-op, not an error** — with the
  path empty, `createProcessGroup` tried `/uid_0` on the read-only rootfs and service start is
  fatal on that error. Return success when nothing is configured.
- **0003 libprocessgroup: give recovery a cgroup-v1-only profile too** — `cgroups.recovery.json`
  declared only the v2 root, so recovery could not boot at all (ueventd exited 4×, `InitFatalReboot`).
  v2 root dropped, `cpuset` declared Optional v1.
- **0004 libprocessgroup: signal the process group when there is no cgroup hierarchy** — the
  empty-path shortcut treated every service as already dead, so `stop`/`restart` were no-ops; in
  recovery adbd never released the FFS endpoints and sideload failed with `EBUSY`. Signals the
  process group directly (init gives every service its own).

### `system/netd`

- **0001 netd: restore the Android 11 no-eBPF fallback (A13 half)** — `BandwidthController` builds
  the legacy `xt_owner`/`xt_qtaguid` rules when BPF is absent instead of referencing pinned
  objects that do not exist (iptables-restore failed wholesale, netd exited). Probes for
  `XT_BPF_ALLOWLIST_PROG_PATH` directly; netd has no `TrafficController` on A13 to ask.
- **0002 netd: do not exit when there is no cgroup v2 root** — `main.cpp` exited before
  `libnetd_updatable_init()`, so the Connectivity degradation never ran: 107 restarts in ten
  minutes, framework never finished booting. `cg2_path` left empty and passed through.

### `vendor/apn`

- **0001 US: add the missing IMS APN for 310240 (Mint)** — 310240 carries six APN rows and not one is
  `type=ims`, so a Mint SIM has no IMS PDN to attach to. 310260 (T-Mobile proper, which this SIM
  registers on as an EHPLMN) has eight, but Android matches APNs on the SIM's own operator numeric, so
  none of them are reachable. The visible effect is that `imsdatadaemon` never finishes starting.

### `vendor/lineage`

- **0001 lineage: restore `B64_FAMILY` (msm8992/msm8994) for the ether port** — 20.0 removed the
  pre-UM families, so `QCOM_HARDWARE_VARIANT` fell back to msm8992 (no such CAF dir) and every
  msm8994 CAF module vanished (`missing libstagefrighthw / libqdMetaData`). Restores the family,
  variant, `TARGET_USES_QCOM_BSP` and `GRALLOC_USAGE_HW_2D`; not `TARGET_USES_QCOM_BSP_LEGACY`
  (no references remain).
- **0002 lineage: add msm8992/msm8994 to `QCOM_BOARD_PLATFORMS`** — `is-vendor-board-platform`
  lives in a different file; without it modules gated on it are never defined and the only symptom
  is "non-existent modules in PRODUCT_PACKAGES" (`libbt-vendor`, `power-service-qti`).
- **0003 soong: create `generated_kernel_includes`' genDir before running `headers_install`** —
  RuleBuilder `rm -rf`s the genDir and never recreates it, so the kernel's `cd $(KBUILD_OUTPUT)`
  check fails. `mkdir -p` first; path stays absolute because `make -C` chdirs.
- **0004 lineage: restore `-fuse-ld=lld` in `HOSTCFLAGS` for pre-4.18 kernels** — `ld` is not on
  the sbox PATH; 20.0 sets lld only in `HOSTLDFLAGS`, which Kbuild ignores for single-file host
  tools like `fixdep`. 19.1 set both; 3.10 needs both.

### `vendor/qcom/opensource/power`

- **power: make the msm8992 duration constants file-local** — 20.0 added
  `kMaxLaunchDuration`/`kMaxInteractiveDuration` to `power-common.c` while every per-SoC file still
  defines its own; duplicate symbol at link. `static` in `power-8992.c` (latent for seven other
  legacy SoCs; only this one is patched).

## Layout

| | |
|---|---|
| `device.conf` | what this device is, and its presets |
| `overlay/patches/` | patches for this phone, one per feature |
| `overlay/local_manifests/` | extra projects the manifest does not carry |
| `vendored/` | trees whose upstreams are deleted, recovered from Software Heritage: the 19.1 device tree the patches apply to, and the pre-rename qcom `sepolicy-legacy` — see `vendored/README.md` |
| `forge/` | the shared build engine, vendored (do not edit here) |

The upstream trees this port depends on that are at risk of disappearing are kept at
[ether-trees](https://github.com/TheDBP/ether-trees): the 18.1 kernel, device tree and CAF HALs
as full-history mirror branches, the recovered 19.1 device tree and `sepolicy-legacy` flat on
`main`. No proprietary blobs are mirrored.

## Support

This is unpaid work on phones their makers abandoned. If a build saved one from the drawer, [a donation](https://www.paypal.com/donate/?hosted_button_id=7U8PDZLK7742Q) keeps the next one coming.

## License

Apache-2.0 — see `LICENSE`. The patches under `overlay/patches/` modify Apache-2.0 (AOSP/LineageOS) and GPL-2.0 (kernel) code and carry those licenses; `vendored/` keeps its upstream licenses.

The kernel in every published image is GPL-2.0. Its complete corresponding source is the
`mirror/android_kernel_nextbit_msm8992/lineage-18.1` branch of
[ether-trees](https://github.com/TheDBP/ether-trees) with the five patches under
`overlay/patches/kernel/nextbit/msm8992/` applied on top.
