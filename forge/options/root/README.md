# root

Magisk patched into the built boot image, so the zip flashes pre-rooted.

## Shape

This option has no `product.mk`. Nothing about it is a product-config question — the boot image
only exists *after* the build, so this is a `post-build.sh` hook. It is the reason options have
hooks at all: a capability is not always a makefile edit.

`require.sh` runs before the compile and fetches the pinned Magisk APK if it is missing. That
ordering matters. The check used to live after the build, so a missing APK was discovered at the
end of a multi-hour compile — and an earlier version of it fell out of an `if`/`elif` without
printing anything, shipping an **unrooted image under a rooted tag**. Wrong contents, exit 0, no
diagnostic.

## What the hook does

Runs Magisk's own `boot_patch.sh` headlessly. `magiskboot` is the x86_64 build (it runs on the
build host); the embedded payload — `magiskinit`, `magisk`, `init-ld` — is arm64 and runs on the
phone.

A-only and A/B devices differ. An A-only OTA zip carries `boot.img` as a plain entry, so it can be
patched and swapped back in, giving one pre-rooted zip. An A/B zip is payload-based: there is no
`boot.img` entry, and inserting one would mean regenerating and re-signing `payload.bin`. On A/B
the built image is patched and shipped standalone for fastboot, and the zip stays stock.

## MAGISK_APK

Pins a specific APK. If it is set and the file is missing, that is an error — the option will not
quietly substitute a different one. It used to, which turned "point it at a bogus path to see what
happens" into "download Magisk and rewrite a finished zip".

## The prebuilt

The APK is fetched and sha256-verified by `forge/prebuilt/fetch-magisk.sh`, never vendored. It is
gitignored, and `sync-forge.sh` excludes it.

## It brings a terminal

`REQUIRES=termoneplus`. Root without a terminal is most of the way to useless, and leaving the
pairing to each preset meant remembering it seven times. Adding `root` now adds TermOne Plus too,
in any preset or via `EXTRA_OPTIONS`.

TermOne Plus is no longer in any preset's own list for that reason -- it arrives with root, or you
ask for it explicitly.
