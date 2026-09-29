# fulguris

[Fulguris](https://github.com/Slion/Fulguris) as the browser, replacing Jelly. A WebView browser --
the system WebView renders, so this is a better shell around the same engine, not a second engine.

| | |
|---|---|
| package | `net.slions.fulguris.full.fdroid` |
| size | 9.3 MB, no native libraries |
| licence | Apache-2.0 |

What it has over Jelly: named sessions (tab groups), a vertical tab panel with drag-to-reorder and a
recoverable trash, a horizontal tab bar for desktop modes, and an address bar that can sit at the
bottom.

This is what the presets carry by default. `firefox` and `fulguris` on one build is an error
(`require.sh`): both `overrides: ["Jelly"]`. Pick the engine you want -- Fennec is 320 MB staged,
Fulguris is 9 MB, and on a device where the first does not fit the second is the point. Fennec is
still there for a device with the room.

## Shape

The `k9` shape, and see `firefox` for the Jelly override: `patches/<branch>` adds the guarded
`PRODUCT_PACKAGES` line and `prebuilts/fulguris/{.gitignore,jni/Android.mk}`; the APK and the Soong
module file are written per fetch by `prebuilt/fetch-fulguris.sh`, which pins the signer, not the
version.

Only `lineage-22.2` carries patches. On a branch without them the option has nothing to contribute
and the build stops at the option check -- add a patch set before putting it in that device's preset.

## Updating

Nothing to bump for a new release -- the next build fetches it. The signer pin lives in
`prebuilt/fetch-fulguris.sh`; `FDROID_PINS` holds a version when you need one.

## Why it is in no preset

Fulguris replaces Jelly rather than installing alongside it (`overrides: ["Jelly"]`), so a preset
that carries Fulguris ships it as the **only** browser. On first run it asks you to accept its
privacy policy and terms — and with no other browser installed there is nothing to open those
documents in. You are asked to agree to something you cannot read.

That is why no preset carries it. Dropping it restores Jelly, which is the sane default: it is
Lineage's own browser and part of the base image either way.

Add it deliberately when you want it:

```sh
EXTRA_OPTIONS=fulguris PRESET=full ./forge/bootstrap.sh
```

The same caution applies to any browser option that overrides Jelly — `firefox` has the same shape.
Shipping a single browser that gates first use behind documents it alone can display is a trap
worth avoiding by default.
