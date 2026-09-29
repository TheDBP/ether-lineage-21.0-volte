# oem

The manufacturer's own boot animation, wallpapers and system sounds, reclaimed from that phone's
stock firmware and put back on a LineageOS build.

## The option / pack split

This is the first option with a real **input**: it needs a copy of the stock firmware, and something
that understands that firmware's layout.

- **The option** knows how to *install* reclaimed assets: copy sounds to `/system/media/audio`,
  wallpapers to `/product/media/wallpaper`, add the Backgrounds picker overlay, point
  `TARGET_BOOTANIMATION` at the zip. None of that is manufacturer-specific.
- **The pack** knows how to *extract* them, and what they are called. `Fillmore.ogg` is the Nextbit
  Robin's ringtone; the option has no business knowing that.

So the pack emits the manufacturer-specific half as generated makefiles, which the option
`-include`s — the same split `gapps` uses for `packages.mk`. There are two, and the difference
matters: `assets.mk` holds *properties* and is read by this option; `assets-vars.mk` holds
*variables a device branches on* and is read by the device makefile itself, because this option is
inherited after the device and anything set here is too late for the device to see. `OEM_ASSET_PACK` in `device.conf`
selects the pack. Today there is exactly one: `nextbit-robin`.

Everything the pack stages lives under `vendor/extra/oem-assets/`, which is why this works on any
device without a patch.

## What stays with the device

Only genuine decisions and genuine facts:

- **ether** chooses whether to use the pack's home scene as its default wallpaper. It reads
  `OEM_DEFAULT_WALLPAPER` — which it must `-include` from `assets-vars.mk` itself, since this option
  is inherited too late — the decision is the device's, the filename is the pack's.
- **bonito** sizes its product partition to fit ~37 MiB of reclaimed assets. That is a real fact
  about that phone's super partition, and it still says `WITH_OEM` in its reasoning, correctly.

## TARGET_BOOTANIMATION

Not a product variable — it is read later by `vendor/lineage/bootanimation/Android.mk`, which falls
back to the generated animation when it is empty. A plain assignment in `vendor/extra/product.mk`
does reach that far; verified by setting it there and reading it back with `get_build_var`.

It used to be set in each device's `BoardConfig.mk`, which is read *after* product config — so
while both existed, the device's `:=` silently overwrote the option's value with an empty string.
That is worth remembering for any future option that touches a board-level variable.

## require.sh

Every install rule is `$(wildcard ...)`-guarded, so a `WITH_OEM` build with nothing extracted
produces no error and no warning — it just quietly ships none of the assets it is tagged as having.
`require.sh` catches that before the compile instead.
