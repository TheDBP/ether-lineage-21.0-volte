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
changes per release. That is not hypothetical: `themed-icons` has three distinct versions across
19.1, 20.0 and 22.2; `nfc-off` and `livedisplay-off` have two each. An option enabled on a branch it
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
