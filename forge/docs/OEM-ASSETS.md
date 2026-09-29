# Reclaiming OEM assets from a stock ROM

Custom ROMs drop the manufacturer's boot animation, notification sounds and wallpapers. Given
stock firmware for the device, the forge extracts them back in.

These assets are proprietary. They are read from a zip you supply, written into your build tree,
gitignored, and never committed. Nothing is fetched from the manufacturer.

---

## 1. Get your stock ROM

A factory image or full OTA zip for the exact model, from the manufacturer's support site or a
firmware archive. Not an incremental OTA: those contain patches, not whole files.

Sanity-check it before using it:

```sh
unzip -t Stock_ROM.zip >/dev/null && echo ok       # not truncated
unzip -l Stock_ROM.zip | grep -E 'system|media'    # has a system image or media dirs
```

## 2. Tell the forge where it is

Three ways, checked in this order:

```sh
STOCK_ROM=/path/to/firmware.zip ./bootstrap.sh     # explicit, wins over everything
```

```sh
# or drop it in the device repo and match it with a glob in device.conf
STOCK_ROM_GLOB="MyPhone_Stock_*.zip"
```

```sh
# or let the forge fetch it
STOCK_ROM_URL="https://example.com/firmware.zip"
```

Then name the asset pack in `device.conf`:

```sh
OEM_ASSET_PACK=nextbit-robin
```

`OEM_ASSET_PACK` names *which* pack to reclaim rather than answering yes/no, because each pack
knows the layout of one manufacturer's firmware. `nextbit-robin` is the only pack today. Leave it
`none` (or unset) to bake no OEM assets. Any device may select a pack -- the Pixel 3a XL build
borrows the Robin boot animation -- since the constraint is the stock ROM you feed it, not the
device being built.

The default glob is `Stock_ROM_*.zip` and is anchored at the start, so `Pixel_Stock_ROM_N108.zip`
does not match. Set `STOCK_ROM_GLOB` or pass `STOCK_ROM=`. Otherwise the build fails with "no stock
ROM found" while the file sits beside it.

## 3. What gets extracted, and where it lands

`tools/extract-nextbit-oem-assets.sh` runs during bootstrap stage 4 and writes into **`vendor/extra`**,
not into your device tree. That is what makes this device-independent: nothing has to be added to a
device tree for a device to be able to use an asset pack.

| asset | lands in | wired up by |
|---|---|---|
| system sounds | `vendor/extra/oem-assets/sounds/media/audio/` | `PRODUCT_COPY_FILES` in the oem option's `product.mk` |
| wallpapers | `vendor/extra/oem-assets/wallpaper/` | same, plus a Backgrounds-picker overlay so they appear in the app |
| Backgrounds-picker overlay | `vendor/extra/overlay/oem-assets/` | `DEVICE_PACKAGE_OVERLAYS` |
| boot animation | `vendor/extra/oem-assets/bootanimation.zip` | `TARGET_BOOTANIMATION`, replacing the generated one |
| pack-specific properties | `vendor/extra/oem-assets/assets.mk` | `-include`d by the option; the default ringtone and friends |
| pack-specific **variables** | `vendor/extra/oem-assets/assets-vars.mk` | `-include`d by the DEVICE makefile; this is where `OEM_DEFAULT_WALLPAPER` lives |

Everything is gated on `WITH_OEM=true`, which is set when a preset's option list contains `oem`.

Two files, because of *who reads them* and *when*. The option's fragment lands in
`vendor/extra/product.mk`, which LineageOS inherits **after** the device makefile. Anything a device
needs to branch on therefore has to arrive earlier than that, so it goes in `assets-vars.mk` and the
device `-include`s it in its own scope. Putting `OEM_DEFAULT_WALLPAPER` in `assets.mk` was a real
bug: `device.mk` tested it while it was still empty, and every `WITH_OEM` build silently shipped the
skin's default wallpaper instead of the manufacturer's, with no error anywhere.
A preset without it builds without any of this.

The sounds step keeps only files not already in LineageOS (on the Robin: 12 of 130).

## 4. Build with them

```sh
WITH_OEM=true ./bootstrap.sh
# or a preset whose options include oem:
PRESET=full ./bootstrap.sh
```

You should see:

```
>> extracting system sounds (Robin-unique only)
   sounds: kept 12 Robin-unique, skipped 118 already-in-Lineage (of 130)
>> extracting OEM wallpapers
>> extracting OEM boot animation
>> extracted: 12 sound(s), 6 wallpaper(s), 1 boot anim
```

## 5. Adapting it to a different device

The mechanism is generic; the paths inside the zip are not. The extractor currently knows Nextbit's
layout. For another OEM, adjust:

- **sounds** — most vendors use `system/media/audio/{ui,notifications,ringtones}/`, but the prefix
  varies with the image layout (`system/system/...` on some A/B devices)
- **wallpapers** — usually inside a vendor APK; the Robin's are in `NextbitWallpapers.apk`. Find
  yours with `unzip -l Stock_ROM.zip | grep -i wallpaper`
- **boot animation** — nearly always `system/media/bootanimation.zip`, and the most portable of the three

Start by listing the zip and looking for the three categories:

```sh
unzip -l Stock_ROM.zip | grep -iE 'bootanimation|wallpaper|media/audio'
```

If the firmware ships a sparse or raw `system.img` rather than loose files, unpack that first
(`simg2img` then mount, or `unpack-block-ota.sh` for a payload-based OTA).

## Traps

**Canvas.** `desc.txt` line 1 is `WIDTH HEIGHT FPS` and must be at least the frame size. The player
centres the canvas on the panel and never scales it: a canvas smaller than the panel is a box on
black (the Robin's stock `550 400` on 1080x1920; the Robin's 1080x1920 frames on the V20's
1440x2560). The extractor composites the background under the frames, then cover-crops every frame
to the `TARGET_SCREEN_WIDTH/HEIGHT` the device tree declares and writes that as the canvas. GOTCHAS 5.

**The zip must be STORED, not deflated.** `bootanimation` reads frames directly out of the archive
and will not decompress them. Re-zip with `zip -0`.

## Licensing

Extracted assets stay in the build tree, gitignored. Do not commit them or publish a ROM containing
them without the right to redistribute.

## A device this doesn't cover

`nextbit-robin` is the only pack the forge ships, and it understands exactly one manufacturer's
firmware layout. Making that general — reading any vendor's stock ROM and finding the assets
wherever they hid them — is a separate project: **[extract-oem-assets](https://github.com/TheDBP/extract-oem-assets)**.
It can already identify firmware across several stock-ROM layouts; adding your phone means writing
a pack, which is mostly a matter of recording where that vendor put things.

## Turning it on

`oem` is not part of any preset. It applies to whichever preset you build:

```sh
EXTRA_OPTIONS=oem PRESET=full ./forge/bootstrap.sh     # tag turbo-oem
EXTRA_OPTIONS=oem PRESET=clean ./forge/bootstrap.sh    # tag turbo-clean-oem
```

Set `EXTRA_OPTIONS="oem"` in `device.conf.local` — gitignored, never published — if every build from
a checkout should carry them.

The `-oem` suffix on the tag is derived, not typed (every `EXTRA_OPTIONS` option the preset lacks
appends its name the same way). `release.sh` identifies an artifact by the tag in
its filename, so an image holding reclaimed assets must not be able to wear the shareable tag. A
hand-written `clean-oem tag=turbo-clean` row could; a derived suffix cannot.
