# Options

An **option** is one capability the forge carries. It works on any device, and adding one does not
touch a single device tree.

That distinction is the whole point of this directory:

| | what it is | where it lives |
|---|---|---|
| **option** | a capability any device could want — nav icons, GApps, root | `forge/options/<name>/` |
| **preset** | a *name* for a set of options, plus a build tag | `PRESETS` in `device.conf` |
| **device patch** | a fact about one phone — a kernel config, a HAL fix, an SoC quirk | `overlay/patches/` |

A preset has no behaviour of its own. It is a saved selection, nothing more. One build command
produces one image; the preset just names which options that image gets.

## Layout

```
forge/options/<name>/
    option.conf          name, description, COMPAT, and optionally KERNEL_CONFIGS / KERNEL_PATCHES
    patches/<branch>/    git am onto synced projects -- BRANCH-SCOPED, see below
    fetch.sh             pull a prebuilt (APK, blob) at sync time
    assets.list          file copies and removals
    tree/                files staged verbatim into the AOSP tree
    product.mk           makefile fragment; the generator wraps it in the ifeq
    build-env            VAR=value lines exported into the build environment while the option is on
    require.sh           checked before the build; non-zero stops it
    post-patch.sh        run after device patches; place files a patch just created a home for
    post-build.sh        run after a successful build; non-zero fails it
    reference/           optional: source material, not shipped
```

Every part is optional. There is one mechanism, not two: what used to be a "feature" (patches
applied at sync) and what used to be an "option" (a makefile fragment gated at build time) are parts
of the same thing now.

## Why patches are branch-scoped and nothing else is

`patches/` is per-LineageOS-branch because patches are diffs against upstream source, and upstream
changes per release. That is not hypothetical: `themed-icons` carries five distinct versions
(19.1 through 24.0); `nfc-off` and `livedisplay-off` carry six each. An option enabled on a branch it
has no patches for uses its other parts (fetch, `product.mk`, hooks); one with nothing else to
contribute on that branch is a hard error, not a silent skip.

Everything else — `product.mk`, `tree/`, `assets.list`, the hooks — is text we wrote, so it applies
unchanged everywhere.

## When each part runs

| part | when | why there |
|---|---|---|
| `patches/`, `fetch.sh` | before device patches | they are commits and downloads |
| `post-patch.sh` | **after** device patches | it drops files INTO a directory a device patch creates. `fetch.sh` cannot: it runs first, so a copy guarded on that directory silently never runs — which is how F-Droid shipped in no image at all while the build reported success |
| `assets.list`, `tree/`, `product.mk` | **after** device patches | an asset overwrites what a patch just created, and `git am` will not apply a patch adding a file already sitting untracked in the tree |

Only the options this build selected are staged, and `vendor/extra` is cleared first — a stale
overlay directory from a previous option set looks exactly like a fresh one.

Every part is optional, and options do not all have the same shape. `nav-icons` is a makefile
fragment and some files. `root` is neither: nothing about Magisk is a product-config question, it
is a boot image that has to be patched after the build produced one. An option is a **capability**,
not specifically a makefile edit.

`require.sh` exists so a missing input is found at minute 0 instead of minute 300. `root` used to
check for its Magisk APK *after* the compile — and an earlier version of that check fell out of an
`if`/`elif` silently and shipped an unrooted image under a rooted tag.

## How it reaches the build

`apply-overlay.sh` stages every option's `tree/` into the AOSP tree and generates
`vendor/extra/product.mk` from their `product.mk` fragments, each wrapped in its own switch.

LineageOS already inherits `vendor/extra/product.mk` on every device —
`vendor/lineage/config/common.mk` does `inherit-product-if-exists` on it. So an option reaches
every device and every branch **with no patch to anything**.

Only the selected options are staged (`vendor/extra` is wiped first), and each is then gated again
at build time by its `WITH_*` variable. What is available is a forge question; what is switched on
is a per-build question, and they should not be the same question.

A variable that a makefile tests with `ifdef` at parse time (`WITH_ADB_INSECURE` in
`vendor/lineage/config/common.mk`) cannot be set from `product.mk`: `inherit-product` only records
the path, and `vendor/extra/product.mk` is read after `common.mk` has finished. Put it in
`build-env` instead; `_build_rom.sh` and `_build_target.sh` export those lines when the option is
on and unset them when it is off.

## The switch name is derived, never declared

`nav-icons` → `WITH_NAV_ICONS`. Lowercase to uppercase, `-` to `_`. There is no field for it in
`option.conf`, because a declared name is a name that can disagree with the directory it is in.

## Adding one

Create the directory. That is the whole procedure — no device patch, no per-branch patch, and
nothing new for `refresh-patches.sh` to re-export or lose.

Then name it in whichever presets should have it (or in `COMMON_OPTIONS` if every build wants it):

```sh
PRESETS="
  full   tag=turbo        options=gapps,root,nav-icons
  clean  tag=turbo-clean  options=nav-icons
"
```

## Verifying one landed

```sh
./forge/docker/aosp.sh bash -lc \
  'cd /aosp && source build/envsetup.sh && lunch <target> && \
   WITH_NAV_ICONS=true get_build_var DEVICE_PACKAGE_OVERLAYS'
```

The option's directory should appear only when its switch is set.

## Options that contribute to the kernel

Most options end up in product config. Some belong to the kernel instead — `linux` needs namespace
and cgroup support compiled in. Those declare it in `option.conf`:

```sh
KERNEL_CONFIGS="container"
KERNEL_PATCHES="cgroup-noprefix-symlinks"
```

which are folded into the same `KERNEL_EXTRA_CONFIGS` / `KERNEL_EXTRA_PATCHES` lists a device can
set directly, so nothing downstream needs to know an option was involved.

## Sub-switches

A few `WITH_*` values in `device.conf` are not options. They only ever *narrow* what an option does
and mean nothing on their own. `WITH_LINUX_FHANDLE` and `WITH_LINUX_CGROUP_PATCH` are per-device
escapes for a kernel that cannot take part of `linux`; `WITH_GAPPS_EXTRAS=false` narrows `gapps` to
MindTheGapps, for an Android version NikGapps has not released for. Making them options would imply
you could enable them without their option, which is meaningless.

A sub-switch that removes contents has to announce itself on every build. `gapps` without the app
swaps produces an image that is correct, tagged the same, and different in the hand -- so both
bootstrap.sh and the option's `require.sh` print what was dropped rather than passing in silence.

## App options fetch at build time

An app option never carries the APK; `fetch.sh` downloads it at sync time into
`vendor/lineage/prebuilts/<option>/`, gitignored there. Fetch the build F-Droid *currently* suggests,
verified by signer certificate (`prebuilt/lib-fdroid.sh`, `fdroid_fetch_latest`), not a pinned
versionCode + file hash: the image should carry the app as it is on the day it is built. Pin only
with `FDROID_PINS` on the command line, to reproduce a release or hold back a bad update.

A subset of a bundle is its own option sharing the fetcher and the patch: `nextcloud-core` is
`prebuilt/fetch-nextcloud.sh` with `NEXTCLOUD_MODULES` set and a verbatim copy of `nextcloud`'s
patch. The fetcher removes bundle APKs it was not asked for, since each module is guarded on its
APK and a stale one would ship. The two are mutually exclusive (`require.sh` checks, and the second
patch would fail to apply).

Two options that install the same thing must say so in `require.sh`: `firefox` and `fulguris` both
carry `overrides: ["Jelly"]`, so a build with both would have two modules claiming the stock
browser's slot. The check costs a line and turns a confusing image into a stopped build.

Because the manifest moves with each fetch, the module cannot mirror its `<uses-library>` list:
20.0 modules set `LOCAL_ENFORCE_USES_LIBRARIES := false`, 22.2+ `enforce_uses_libs: false`.

## An option that does less on some branches

An option is allowed to contribute nothing but a fetch on one branch and a patch on another —
`fdroid` patches `vendor/lineage` on 22.2, while on 19.1 the device tree already builds it and the
option only has to place the APKs. The error case is an option that can contribute **nothing at all**
on the branch being built; doing less is a legitimate shape.

## Option placement across devices

`COMMON_OPTIONS` is unioned into every preset by `forge_preset_options`, so anything put there
lands in `clean` too. App packages do not belong in it — that is how `clean` builds once shipped
F-Droid. The look-and-behaviour set (`dark-default`, `home-defaults`, `nav-icons`, `teal-*`,
`themed-icons`, `pong-notification`, …) is COMMON on every device: it is the brand, not a
per-device taste.

Two intentional differences remain:

- `nav-icons` is COMMON everywhere for a different reason on the Robin (its own nav bar) than
  elsewhere (borrowed) — see the comment above `COMMON_OPTIONS` in ether's `device.conf`.
- `setupwizard-lineage` (Lineage's SetupWizard over Google's on GApps builds) is COMMON on ether
  only; it has 18.1–20.0 patches and none for 22.2/23.2, so bonito and vs995 `full` builds run
  Google's wizard. To be revisited, not an oversight.

## REQUIRES: one option pulling in another

`option.conf` may name other options it cannot sensibly ship without:

```
REQUIRES=termoneplus
```

`bootstrap.sh` appends them to `BUILD_OPTIONS` before anything is staged, skipping any already
present. The case it exists for is `root`: a rooted image with no terminal is a trap every preset
kept having to remember, and forgetting it produced a build that looked complete and wasn't.

Resolution is a **single pass**, deliberately. If an option needs a chain deep enough to require
recursion, the options are wrong -- split them or merge them rather than teaching this to recurse.
An unknown name is a hard error, not a warning: silently dropping a requirement is exactly the
failure the field exists to prevent.

## Every option the forge ships

Generated from `options/` on disk by `tools/gen-option-index.py`; `tools/propagate-forge.sh` checks
it, so it cannot drift from the options that exist. `any` in the branch column means the option
needs no branch-specific patch at all — only its patches are branch-scoped, so an option with none
for your branch still works if it contributes anything else (`fdroid` has no `lineage-20.0` patch
and ships in that build, because there it only has to fetch the APK).

<!-- options:start -->

| option | what it does | branches with patches |
|---|---|---|
| `advanced-restart` | Advanced restart in the power menu. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `bringup` | adbd from boot with no authorisation prompt, plus persistent logcat, so a build that never reaches the lock screen can still be traced. **Never hand out an image built with this** — it accepts adb from any host. | any |
| `connectbot` | ConnectBot: an SSH client with saved hosts, keys and port forwarding. | 20.0, 22.2, 23.2, 24.0 |
| `dark-default` | Default to dark theme. | 20.0, 21.0, 22.2, 23.2, 24.0 |
| `drm-trace` | Diagnostic: kernel trace of whoever disables a DRM plane or CRTC, for a panel that dies while the framework still thinks it is on. | any |
| `fdroid` | F-Droid app store + Privileged Extension (silent installs/updates). | 22.2, 23.2, 24.0 |
| `firefox` | Firefox (Fennec F-Droid) as the browser, replacing Jelly. Mutually exclusive with `fulguris`. **In no preset**: it overrides Jelly, and stages 320 MB against Fulguris's 9. | 22.2, 23.2, 24.0 |
| `fulguris` | Fulguris as the browser, replacing Jelly. A WebView browser, 9 MB where Fennec stages 320 MB. Mutually exclusive with `firefox`. **In no preset**: it overrides Jelly, so a preset carrying it ships the only browser in the image, and its first run asks you to accept terms with nothing else able to open them. | 20.0, 22.2, 23.2, 24.0 |
| `gapps` | Google apps: Play Store and GMS from MindTheGapps, plus Google's versions of the stock apps. | 18.1, 19.1, 20.0, 21.0, 22.2, 23.2, 24.0 |
| `google-feed-off` | Google feed (-1 screen) off by default. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `home-defaults` | Home screen defaults: no icon labels, no auto-add. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `k9` | K-9 Mail (the Thunderbird for Android codebase) as the mail client. | 20.0, 22.2, 23.2, 24.0 |
| `kdeconnect` | KDE Connect (phone <-> desktop: notifications, clipboard, files, remote input). | 20.0, 22.2, 23.2, 24.0 |
| `linphone` | Linphone: a SIP client, for voice over data where the device has no VoLTE. | 20.0, 22.2, 23.2, 24.0 |
| `linux` | On-device Linux environment (chroot + Docker): container kernel config and cgroup fixes. | any |
| `livedisplay-off` | LiveDisplay off by default. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `minimal-home` | Minimal home screen: hotseat only, no second page. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `nav-icons` | Nextbit Robin style nav-bar icons, drawn as scalable tintable vectors. | 20.0, 21.0, 22.2, 23.2, 24.0 |
| `nextcloud` | Nextcloud bundle: Files, Talk, NextPush, Deck, NC Passwords, Notes, DAVx5, Tasks — the current F-Droid build of each. ~600 MB against `nextcloud-core`'s ~270. Check the partition before adding either. | 20.0, 22.2, 23.2, 24.0 |
| `nextcloud-core` | Nextcloud, the four that make the phone a client: Files, Talk, NextPush, DAVx5 — the current F-Droid build of each. Mutually exclusive with `nextcloud`, which already carries these four. | 20.0, 22.2, 23.2, 24.0 |
| `nfc-off` | NFC off by default. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `oem` | The manufacturer's own boot animation, wallpapers and sounds, reclaimed from its stock ROM. Needs that phone's own stock ROM and a pack that understands its layout — see `forge/docs/OEM-ASSETS.md`. | any |
| `openvpn` | OpenVPN for Android (de.blinkt.openvpn) as a bundled VPN client. | 20.0, 22.2, 24.0 |
| `pong-notification` | Pong as the default notification sound (LineageOS default is Argon). | 20.0, 22.2, 24.0 |
| `root` | Magisk baked into the boot image, so the zip flashes pre-rooted. Pulls in `termoneplus`. The image flashes pre-rooted, so treat it like one. | any |
| `setup-mobile-data` | Leave mobile data alone during setup (older Lineage turns it off and never back on). | 20.0 |
| `setupwizard-lineage` | Use Lineage SetupWizard over Google's (WITH_GAPPS). | 18.1, 19.1, 20.0 |
| `setupwizard-nag-skip` | Skip recovery/metrics/backup setup pages. | 18.1, 19.1, 20.0, 22.2, 23.2, 24.0 |
| `syncthing-fork` | Syncthing-Fork: continuous file sync between your own devices, no server or account. | 20.0, 22.2, 23.2, 24.0 |
| `teal-skin` | Teal accent — fixed #009D94 Monet preset seed. | 19.1, 20.0, 22.2, 23.2, 24.0 |
| `teal-wallpaper` | Teal-shag default wallpaper (baked into framework-res). | any |
| `terminal-visible` | Show the Terminal app in the launcher. | 18.1, 19.1 |
| `termoneplus` | TermOne Plus terminal emulator (F-Droid build). | 20.0, 22.2, 23.2, 24.0 |
| `themed-icons` | Themed (monochrome) app icons on by default. | 19.1, 20.0, 22.2, 23.2, 24.0 |
| `volte` | The manufacturer's own IMS stack, rebuilt from its stock firmware, so the phone can place calls over LTE. Turns itself on when the phone's stock firmware is present and off when it is not, marking the build tag `-novolte` — see `forge/options/volte/README.md`. | any |

<!-- options:end -->