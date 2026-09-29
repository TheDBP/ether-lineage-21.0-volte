# termoneplus

TermOne Plus (`com.termoneplus`) as the terminal emulator. LineageOS 20.0+ ships none: AOSP dropped
`packages/apps/Terminal` after 13, and `terminal-visible` only covers 18.1/19.1.

The maintained fork of the classic Android Terminal Emulator: a local shell and nothing else, ~6 MB,
targetSdk 36, GPL-3.0. F-Droid build, F-Droid's signature, so F-Droid updates it in place.

It is its own option rather than part of `root` or `linux`: it needs neither (a terminal is useful
unrooted), and both of those are useful from `adb shell` without it. It is the way *in* to both from
the phone -- `su`, then `linux` for the chroot -- so `libre` and `full` carry it.

## Why not Termux

Termux is the better-known choice and stays on F-Droid as a one-tap install. It is not bundled
because it targets SDK 28 by design (Android 10+ forbids apps targeting 29+ from executing binaries
in their data directory, which is Termux's whole model), so Play Protect flags it on every GApps
build, and its 114 MB userland duplicates what the `linux` chroot already provides.

## Shape

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES in config/common.mk; prebuilts/termoneplus/
                                   module (20.0: Android.mk; 22.2+: jni/Android.mk, Android.bp is fetched)
fetch.sh                           pulls the APK into vendor/lineage/prebuilts/termoneplus at sync time,
                                   unpacks lib/arm64-v8a/ beside it, on 22.2+ writes Android.bp
require.sh                         APK present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      shipped APK byte-identical to the fetched one; every unpacked library beside it
```

Same shape as `k9` (and so `nextcloud`); those READMEs explain the fetch, the per-branch module
choice and the native-library rule. The terminal's pty handling is JNI (`libterm-system.so` and
three helpers), and every release so far packs them compressed, so the fetcher unpacks them and the
module installs them as `app/TermOnePlus/lib/arm64/` -- without that every launch dies in
`UnsatisfiedLinkError`.

## No 21.0 patches

Nothing has been built on 21.0 yet. Enabling `termoneplus` there fetches the APK but adds no
module, so the build compiles and then fails in `post-build.sh` (no `TermOnePlus.apk` in the
image). Add a `lineage-21.0` patch first (the 20.0 one is the starting point).

## Updating

Nothing to bump for a new release -- the next build fetches it. Change
`prebuilt/fetch-termoneplus.sh` only when the author rotates the signing key (confirm with
upstream first).
