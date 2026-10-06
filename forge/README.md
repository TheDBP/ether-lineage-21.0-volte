# rom-forge

The build engine behind these ROMs. Syncs, patches, compiles and packages a LineageOS build inside
Docker — the host needs only Docker, git and disk. No JDK, no Python, no repo tool.

**Setting up a phone? Start with the template instead**, which has this vendored and a guided setup:

```sh
git clone https://github.com/TheDBP/rom-forge-device-template.git my-phone
cd my-phone && ./start-here.sh
```

This repo is the engine itself — read it when you want to know how the build works, change what it
does, or update `forge/` inside an existing device repo.

---

## What people use this for

| I want to… | Do this |
|---|---|
| Set up a new phone from scratch | Clone the [device template](https://github.com/TheDBP/rom-forge-device-template) and run `./start-here.sh`. |
| Build one **without** Google apps, to share | `PRESET=clean ./bootstrap.sh` |
| Build one with GApps, root and every tweak | `PRESET=full ./bootstrap.sh` |
| Build **plain LineageOS**, to compare against | `PRESET=stock ./bootstrap.sh` |
| Change how Android behaves out of the box | Enable **options** — see [Customizing the ROM](#customizing-the-rom). |
| Push a phone onto a **newer** Android than upstream supports | Read [docs/porting-a-branch-bump.md](docs/porting-a-branch-bump.md) **first**. |
| Work out whether a port is even feasible | `tools/check-platform-support.sh` — no build required. |

## Working examples

These are real device repos built with this engine. Copy one rather than starting from a blank
`device.conf`:

| Repo | Device | Branch | State |
|---|---|---|---|
| [ether-lineage-20.0-volte](https://github.com/TheDBP/ether-lineage-20.0-volte) | Nextbit Robin | 20.0, VoLTE working | Daily driver. Upstream stopped at 18.1, so everything above that is a 75-patch series in the repo. |
| [ether-lineage-21.0-volte](https://github.com/TheDBP/ether-lineage-21.0-volte) | Nextbit Robin | 21.0, staged | Starts from the 20.0 series. 21 is the end of the line: 22 needs a 4.19 kernel and this one is 3.10. |
| [bonito-lineage](https://github.com/TheDBP/bonito-lineage) | Pixel 3a XL | 24.0 | Android 17 on an Android 15 kernel and Android 12 blobs. Boots in ~30 s with the hardware working: camera both sensors, VoLTE and VoWiFi, fingerprint, NFC, GPU memory reporting. Upstream stopped at a stale 23.0, so this went straight to 24. |
| [vs995-lineage](https://github.com/TheDBP/vs995-lineage) | LG V20 (Verizon) | 24.0, with VoLTE | 24.0 boots enforcing on the 4.4 kernel and carries VoLTE (LG's 2016 IMS stack bridged onto A17): MO and MT calls with two-way audio. Building it needs the stock LG firmware you supply. |

---

## Build your first image, step by step

This assumes you have never built Android before. Follow it in order.

### 1. What you need

- A Linux machine with **Docker**, **git**, and a lot of disk — **250 GB free per device**, plus
  16 GB RAM. Everything else (Java, Python, the `repo` tool) lives inside the container.
- A phone LineageOS already supports. The forge builds LineageOS *for* a device; it does not create
  support for a new one.
- Time. The first build downloads the whole Android source tree and compiles it from scratch.

### 2. Get a device repo

```sh
git clone https://github.com/TheDBP/rom-forge-device-template.git my-phone
cd my-phone
./start-here.sh
```

`start-here.sh` checks your machine, detects the phone if it is plugged in, and writes
`device.conf` for you. If you would rather do it by hand, see *Setting up a device* below.

### 3. Decide what goes into the build

Three independent switches:

| switch | what it adds | what it needs from you |
|---|---|---|
| **GApps** | Google Play Services and the Play Store | nothing — the URL is derived from the branch; `GAPPS_URL` only overrides it |
| **OEM assets** | the manufacturer's boot animation, sounds and wallpapers | a stock ROM the forge already has a pack for — currently only the Nextbit Robin ([docs/OEM-ASSETS.md](docs/OEM-ASSETS.md)) |
| **root** | a Magisk-patched boot image, plus a standalone `boot-magisk.img` | nothing |

A **preset** is a saved set of options plus a build tag, so you do not retype them. One build
command produces one image; a preset just names the combination you want:

```sh
PRESETS="
  full   tag=turbo        options=gapps,root,nav-icons
  clean  tag=turbo-clean  options=nav-icons
"
```

That defines two builds: `full` (everything) and `clean` (plain LineageOS). Option names come from
`forge/options/` — naming one that has no directory there is an error, not a word quietly ignored.

`oem` is deliberately absent. Which manufacturer's art an image carries is a separate choice from
what apps it has. Add it to whichever preset you are building with `EXTRA_OPTIONS=oem`, or once in
`device.conf.local`, which is gitignored:

```sh
EXTRA_OPTIONS=oem PRESET=clean ./forge/bootstrap.sh   # builds tag turbo-clean-oem
```

### `stock` — the reference build

Every device has a `stock` preset without declaring one. It is the empty option set: LineageOS as
upstream ships it, carrying only the `overlay/patches/` that make the hardware run, and none of the
theming, apps or behaviour changes.

```sh
PRESET=stock ./forge/bootstrap.sh          # tag: stock
```

It is the only preset that takes neither `COMMON_OPTIONS` nor `EXTRA_OPTIONS` — "stock plus the
dozen things we always add" would not be stock, and a stock image quietly carrying `oem` art would
be a lie in its own filename. Asking for it with `EXTRA_OPTIONS` set prints a note saying it was
ignored.

Its value is answering one question quickly: **is this ours or upstream's?** A bug that reproduces
on a stock build is LineageOS's; one that disappears is something we added, and the option list is
then the search space. That is a single flash instead of an argument.

Declare your own `stock` row in `PRESETS` and it wins over the built-in one.

The `-oem` suffix is derived, not typed: every option `EXTRA_OPTIONS` adds that the preset does
not already have appends `-<name>` to the tag. `release.sh` proves an artifact by the tag in its
filename, so an image holding reclaimed assets must never be able to wear the shareable tag.

**If this is your first build, use `clean`.** It has the fewest moving parts — no GApps zip to
source, no stock firmware to extract — so if something breaks it is the build, not your inputs.

### 4. Build it

```sh
PRESET=clean ./forge/bootstrap.sh
```

That is the whole command. It syncs the source, applies patches, compiles, and packages. The first
run is much longer than later ones, which reuse the synced tree and ccache.

Useful on a first attempt:

```sh
KEEP_GOING=true PRESET=clean ./forge/bootstrap.sh
```

`KEEP_GOING` compiles past the first error instead of stopping, so one run surfaces every problem
rather than one per cycle.

### 5. Find the result

```
build_output/artifacts/<zip name>.zip   (+ -recovery.img, -boot.img, .sha256)
```

That copy survives the next build; the one in `build_output/src/out/target/product/<codename>/` is
deleted by the next preset's installclean. If you enabled root you also get `boot-magisk.img` in
`out/`.

### 6. Flash it

1. Boot the phone into recovery
2. Install the zip
3. Factory reset (first install only — not needed when updating)
4. Reboot

### 7. Change something

Everything the forge changes is a patch. To add your own, edit the source directly and commit it:

```sh
cd build_output/src/device/<vendor>/<codename>
# edit files
git commit -am "my change"
```

Then rebuild. Your commit is already in the tree, so the next build picks it up.

### 8. Save your change so it survives

A rebuild re-syncs the source, which throws away uncommitted work **and** commits that are not
captured as patches. To keep a change permanently:

```sh
./forge/tools/refresh-patches.sh
```

This walks the projects you have committed to and rewrites `overlay/patches/` to match. From then
on, every build replays your change automatically — including on a fresh clone on another machine.

Run it on a clean tree, with no half-applied patches and nothing uncommitted. See GOTCHAS 14 for
what happens otherwise.

### 9. Building something other than the default

```sh
./forge/bootstrap.sh                            # the first preset in device.conf
PRESET=clean ./forge/bootstrap.sh               # a named set of options
OPTIONS="gapps root" ./forge/bootstrap.sh       # an ad-hoc set, no preset needed
PRESET=full OPTIONS=nav-icons ./forge/bootstrap.sh   # a preset's tag, your options
```

**One run builds one image.** Building two means running it twice, which costs almost nothing: the
57 GB of compiled intermediates in `out/` are reused between runs, and the only thing a second run
repeats is a one-to-four-second overlay pass.

Optional extras — an on-device Linux environment (the `linux` option), F-Droid, Firefox, Google
apps — are options; see *Options and presets* below.

---


## Setting up a device

Device setup lives in its own repo, not here. The forge is the engine; each phone gets a small repo
holding that phone's config and patches, with `forge/` vendored inside it.

**Start from the template** — it is already scaffolded, with `forge/` vendored and an interactive
setup script:

```sh
git clone https://github.com/TheDBP/rom-forge-device-template.git my-phone
cd my-phone
./start-here.sh
```

`start-here.sh` checks the host, identifies the phone (over adb or by codename), finds the upstream
device tree, picks a branch that is actually the newest code, and fills in `device.conf`.

**Or scaffold one by hand**, if you would rather not clone the template:

```sh
./tools/new-device-repo.sh --codename bonito ~/bonito-android
cd ~/bonito-android && ./bootstrap.sh
```

Either way you end up with the same layout, and `forge/` inside it updates independently:

```sh
./forge/tools/sync-forge.sh
```

**Or keep the device inside the forge checkout** (`devices/<name>/`, gitignored):

```sh
./tools/new-device-repo.sh --codename bonito --device bonito
./bootstrap.sh --device bonito
```

Same files, same build; nothing is vendored. Version-control `devices/<name>/` yourself if you want
it kept.

What goes in `device.conf`, how to find your lunch target, what to do when no device tree exists —
all of that is documented in the template repo, which is where someone setting up a new phone
should start.


## What actually happens when you run it

`bootstrap.sh` walks six stages, numbered 0–5, and tells you which one it is on:

```
>> [0/5] fetching pinned Magisk APK (sha256-verified)
>> [1/5] building image aosp-bonito:24.04 (ubuntu 24.04 + JDK 21)
>> [2/5] repo init
>> [3/5] repo sync
>> [4/5] apply overlay patches
>> [5/5] build the ROM(s)
== DONE ==
```

Each stage logs to `build_output/logs/` (`sync.log`, `apply.log`, `build.log`, …), so when something
fails you can read that stage on its own instead of scrolling a single enormous transcript.

## Customizing the ROM

Two kinds of change, and the line between them is the only thing you really have to learn.

**1. Options** — anything that could apply to more than one phone. Google apps, root, F-Droid,
Firefox, NFC off by default, themed icons, a different browser. Each is a directory under
`forge/options/<name>/`, and adding one **touches no device tree at all**. Name them in
`device.conf`:

```sh
COMMON_OPTIONS="themed-icons nfc-off fdroid"   # every build on this device gets these

PRESETS="
  full   tag=turbo        options=gapps,root   # plus the common set
  clean  tag=turbo-clean  options=
"
```

Edit an option once in the forge and every device picks it up on the next `sync-forge.sh` — you
never copy a fix between devices. See [options/README.md](options/README.md).

**2. Device patches** — facts about *one* phone: a kernel config, a HAL fix, an SoC quirk. These
live in `overlay/patches/<project>/` and are `git am`'d onto the projects named in
`PATCHED_PROJECTS`. If something here would make sense on another phone, it belongs in an option
instead.

A binary blob is the one thing a patch cannot carry readably, so edits to prebuilts — a `DT_NEEDED`
on a framework library the vendor linker namespace cannot load, a stale SONAME — go in
`overlay/blob-fixups`, one line per edit (`<path> remove-needed libandroid.so`), applied with
patchelf after the patches by `tools/blob-fixups.sh`.

That is the whole model.

### Reclaiming a phone's own assets

There is also a way to put a manufacturer's boot animation, wallpapers and sounds back on a Lineage
build, reclaimed from that phone's stock firmware — the `oem` option. It works, but it understands
exactly one firmware family so far, so for most devices it is not yet an answer.
See [docs/OEM-ASSETS.md](docs/OEM-ASSETS.md) if your phone is the one.

### Keeping a 2016 phone able to make calls

Carriers have been shutting down the 2G/3G circuit-switched voice these devices fall back to, so on
a handset whose VoLTE the platform does not provide, VoLTE is the difference between a phone and a
tablet. Where the OEM put the IMS stack in its own app, the `volte` option rebuilds that stack from
the phone's own stock firmware — which the user supplies, because none of it may be redistributed.

It is the one option that turns itself on: present firmware means on, absent means off with the
image tagged `-novolte`, and asking for it without the firmware stops the build rather than shipping
something that cannot call. See [options/volte/README.md](options/volte/README.md) for why that
default is shaped that way, and [docs/debugging-volte.md](docs/debugging-volte.md) for doing the
port itself.

### Options and presets

Three words that are easy to blur:

| | what it is | where it lives |
|---|---|---|
| **option** | a capability any device could want — nav icons, GApps, root | `forge/options/<name>/` |
| **preset** | a *name* for a set of options, plus a build tag | `PRESETS` in `device.conf` |
| **device patch** | a fact about one phone — a kernel config, a HAL fix | `overlay/patches/` |
| **blob fixup** | a DT_NEEDED edit to one prebuilt the OEM shipped — a framework lib the vendor namespace cannot load | `overlay/blob-fixups` |

A preset has no behaviour of its own. It is a saved selection, nothing more:

```sh
PRESETS="
  full    tag=turbo         options=gapps,root,nav-icons
  clean   tag=turbo-clean   options=nav-icons
  styled  tag=turbo-styled  options=nav-icons
"
```

`gapps`, `oem` and `root` are not special — they are options like any other, and were positional
booleans only because they existed before options did. Adding a new one never changes the shape of a
preset row.

An option owns its whole implementation: its makefile fragment, the files it stages, its patches,
its hooks. It reaches the build through `vendor/extra/product.mk`, which LineageOS inherits on every
device, so **adding one touches no device tree at all**. See [options/README.md](options/README.md).

Three things worth knowing:

- **Every option not named by the build is off**, with one deliberate exception. Nothing is
  inherited from the environment or from a previous run, so a build is otherwise exactly the set you
  asked for. The exception is `volte`, which turns itself on when the device's stock firmware is
  present — a phone that cannot place a call is not a sensible default. It announces itself on
  stdout either way, and a build without it is tagged `-novolte`.
- **The option set is part of the build fingerprint**, so changing it triggers the `installclean`
  that makes the change actually take. Otherwise you would get a repackage of the last build's
  staging with no sign anything was wrong.
- **An option naming no directory under `forge/options/` is an error.** A typo would otherwise be
  silent: the switch would simply never be set, and the image would build fine without whatever you
  asked for.

The switch still has to be *used* somewhere — a device whose makefiles never read `WITH_NAV_ICONS`
will set it and nothing will happen.

## Optional: Linux on the device

Add `linux` to `COMMON_OPTIONS` or a preset in `device.conf`:

```sh
COMMON_OPTIONS="... linux"
```

Builds a container-capable kernel. The Magisk module that goes with it, `linux-chroot-<version>.zip`
(Ubuntu Base in a chroot, plus `lx-docker`; scripts only, ~7 KB), is written next to the ROM on
every build whether or not the option is on — installing it on the phone is opt-in, and nothing
mounts at boot.

Kernels vary in what they support, so there are two escape hatches:

```sh
WITH_LINUX_CGROUP_PATCH=false   # kernels predating kernfs (3.10)
WITH_LINUX_FHANDLE=false        # devices whose VINTF matrix requires CONFIG_FHANDLE=n
```

See `modules/linux-chroot/README.md` for what works and what does not.

## Working inside the container

```sh
./forge/tools/dev-shell.sh              # interactive shell, tree mounted
./forge/docker/aosp.sh bash -lc "..."   # run one command
```

Useful when you want to poke at the tree with the same toolchain the build uses.

## When something breaks

**Do not fix one error per build cycle.** A port fails in clusters, so collect them all first:

```sh
KEEP_GOING=true ./bootstrap.sh                      # mka -k: keep going past errors
./forge/tools/triage-build-log.sh build_output/logs/build.log   # collapse into distinct causes
```

Then:

- Read the failing stage's log in `build_output/logs/`, not the console scrollback.
- `logs/sync.log` and `logs/build.log` are **appended across runs** — scope to the last `====` marker
  before you believe an error (GOTCHAS 16).
- `tools/triage-build-log.sh` turns a wall of build output into a short list of causes.
- `tools/measure-touch-rate.sh` reports the digitizer's real in-contact rate, with a HEALTHY/DEGRADED
  verdict. Use it before blaming the renderer for UI lag — on this hardware the renderer was fine
  and the stall was a CPU-hotplug bug holding a lock (GOTCHAS 24).
- `docs/TOOLS.md` is the full tool index — every tool, what it does, how to run it, and any doc
  that mentions it. It is generated by `tools/gen-tool-index.py` from the tools themselves, so it
  cannot fall behind them; `docs/tools.yaml` is the same data for anything that would rather not
  parse Markdown. `propagate-forge.sh` runs the `--check`, so an engine change cannot reach the
  device repos with an index that lies or a tool missing from `tools/README.md`.
- `GOTCHAS.md` is the accumulated list of things that have gone wrong here and why.

**Check before you build, not after.** Two scripts answer questions that would otherwise need a
full build-flash-boot cycle each:

```sh
./forge/tools/check-hal-readiness.sh <src> <device-tree-path>   # HALs declared with nothing to serve them
./forge/tools/check-bpf-readiness.sh --src .      # code that abort()s when a kernel feature is absent
./forge/tools/check-bpf-readiness.sh --log boot.txt   # what the device actually tried and got ENOSYS
```

On an old device the second one is the high-value check: a pre-4.x kernel logs every unimplemented
syscall as `comm[pid]: syscall N`, which makes the kernel log an *exhaustive* list of what userspace
attempted. See [docs/debugging-a-boot-loop.md](docs/debugging-a-boot-loop.md).

**If the container image fails to build**, it is usually a slow or unreachable distro mirror rather
than anything you changed. Editing the Dockerfile for one device invalidates the layer cache for
every Ubuntu version it supports, so an unrelated change can force a full apt install. The forge
retries, then falls back to an existing image with a loud warning:

```sh
SKIP_IMAGE_BUILD=1 ./bootstrap.sh    # reuse the existing image, skip the attempt entirely
STRICT_IMAGE=1 ./bootstrap.sh        # fail instead of falling back (you changed the Dockerfile)
```

## Repo layout

```
bootstrap.sh          the orchestrator
device.conf.example   every key, documented
docker/               Dockerfile, container runner, build + packaging steps
tools/                build machinery and port-assessment scripts (see tools/README.md)
lib/                  shared shell libraries (preset + option parsing)
options/              build options -- one capability each, usable on any device (see its README)
kernel-configs/       kernel fragments (e.g. container.config)
kernel-patches/       generic kernel patches applied across devices
modules/              on-device Magisk modules (linux-chroot)
templates/            source templates instantiated into device trees by tools/ (ims-bridge: the compat
                      ImsService over an OEM legacy IMS app, see tools/new-ims-bridge.sh)
prebuilt/             fetchers for Magisk, F-Droid, Firefox, Fulguris, K-9, KDE Connect, TermOne Plus,
                      Nextcloud, Linphone, ConnectBot
GOTCHAS.md            known traps, indexed by symptom
```

### Documentation

| Doc | Read it when |
|---|---|
| [docs/porting-a-branch-bump.md](docs/porting-a-branch-bump.md) | Moving a device to a newer Android. Checks to run **before** the first build. |
| [docs/debugging-a-vendor-blob.md](docs/debugging-a-vendor-blob.md) | A prebuilt HAL that worked on the old branch and crashes on the new one |
| [docs/debugging-a-dead-panel.md](docs/debugging-a-dead-panel.md) | The screen goes black and stays black while the framework still reports the display on. |
| [docs/debugging-volte.md](docs/debugging-volte.md) | Porting an OEM IMS stack onto a newer Android, and debugging one that registers but carries no call. Needs the device's stock firmware -- the doc opens with what to extract and how. Covers the compat-ImsService bridge, the four-rung silent-call ladder, the QMI GID rule that costs audio, and locking the stack down from permissive. |
| [docs/debugging-mobile-data.md](docs/debugging-mobile-data.md) | LTE registers, SMS and IMS work, but every data call fails with an error that explains nothing — on your ROM, the official one and a swapped modem alike. Ask the modem directly (QMI), read its own log (DIAG F3), and find the bootloader-to-modem flag in SMEM. |
| [docs/lineage-branches.md](docs/lineage-branches.md) | Choosing which branch to target — and avoiding a higher branch number that is actually older code. |
| [docs/debugging-a-boot-loop.md](docs/debugging-a-boot-loop.md) | It builds but will not boot. Start with `/data/tombstones`, not pstore — and why USB adb may be impossible on your kernel. |
| [docs/RELEASING.md](docs/RELEASING.md) | Publishing a build without handing out someone else's assets by accident. |
| [docs/OEM-ASSETS.md](docs/OEM-ASSETS.md) | Reclaiming wallpapers, sounds and boot animations from a stock ROM. One firmware family supported so far. |
| [GOTCHAS.md](GOTCHAS.md) | Something broke and you want to know if it has broken before. |
| [tools/README.md](tools/README.md) | What each script does, and the machinery outside `tools/` that a build actually fails in. |
| [options/README.md](options/README.md) | What an option is, how to add one, and why a preset has no behaviour of its own. |

---

## Prior art, and how this differs

This is not the first system for building custom Android ROMs, and the two below are worth knowing
about before you pick one.

**[docker-lineage-cicd](https://github.com/lineageos4microg/docker-lineage-cicd)** is the popular
one, and the most likely alternative for most people. A Debian container with everything needed to
build LineageOS, a cron job that builds a list of device codenames from environment variables, OTA
support, and optional microG injection. Several active forks. If what you want is *unattended builds
of upstream LineageOS*, use it — it does that job better, and it has years of production use behind
it.

The difference is what it does not try to do: customization happens through
`local_manifests/*.xml`, so the ROM is whatever your manifests point at. There is no layer for
"apply this change to all my phones".

**[hashbang/aosp-build](https://github.com/hashbang/aosp-build)** is closer in shape to this
project, and the more interesting comparison. It also runs entirely in Docker, also keeps patches
outside the source tree, and its `make diff` exports working-tree changes back out as patchfiles —
the same round trip as `refresh-patches.sh` here. Its priority is **determinism**: hash-locked
manifests, reproducible output you can verify byte-for-byte against someone else's build.

This project's priority is **composable customization** instead. The practical difference is the
`options/` directory: a capability is written once and works on every device, reaching the build
through `vendor/extra/product.mk`, which LineageOS already inherits everywhere — so adding one
touches no device tree at all. The usual alternative is to fork the device tree per phone, or carry
a rebased patchset per phone, and then hand-copy changes between them.

Where those approaches are unavoidable, the patches stay — but `overlay/patches/` should then hold
only facts about *that phone*: a kernel config, a HAL fix, an SoC quirk. Anything portable belongs
in an option, and the split is the point.

Two other things here that the alternatives do not have, for whatever they are worth: a release path
that inspects the built image rather than its label, and refuses to publish Google's apps or
reclaimed manufacturer art ([docs/RELEASING.md](docs/RELEASING.md)), and [GOTCHAS.md](GOTCHAS.md), which is a list of traps that
have actually cost time rather than a list of features.

**Also worth a look:** [Akipe/awesome-android-aosp](https://github.com/Akipe/awesome-android-aosp)
collects AOSP and ROM development resources generally, and
[aospdtgen](https://github.com/SebaUbuntu/aospdtgen) generates a LineageOS-compatible device tree
from a stock ROM dump, which is a good starting point for a device nobody has ported yet.

## How it is shared

`forge/` is vendored into each device repo rather than submoduled, pinned by commit in
`forge/FORGE_REF`:

```sh
./forge/tools/sync-forge.sh          # pull the latest engine into this device repo (run from the device)
./tools/propagate-forge.sh           # push this engine out to every device repo (run from the forge)
```

`sync-forge.sh` pulls; `propagate-forge.sh` pushes. Use the second after committing an engine change
so no device is left on a stale copy.

Vendoring keeps history squashable and makes "which forge is this?" a single grep.

## Support

This is unpaid work on phones their makers abandoned. If a build saved one from the drawer, [a donation](https://www.paypal.com/donate/?hosted_button_id=7U8PDZLK7742Q) keeps the next one coming.

## License

Apache-2.0 — see `LICENSE`. The option and kernel patches modify Apache-2.0 (AOSP/LineageOS) and GPL-2.0 (kernel) code and carry those licenses.
