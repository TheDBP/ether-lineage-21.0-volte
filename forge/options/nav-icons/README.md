# nav-icons

The Nextbit Robin's nav-bar icons, redrawn from scratch as VectorDrawables.

## The design

The stock icons look like three unrelated shapes. They are **one annulus, cut three ways**: a full
ring for home, and a 180° arc for back and for recents, each offset by half its outer radius so its
bounding box re-centres on the canvas. Ends are flat, not rounded.

Outer radius 8.175, inner radius 4.825, on a 28dp viewport — the same viewport SystemUI's own
`ic_sysbar_*` drawables use. Those numbers come from measuring the stock 49px xxhdpi art (outer
24.465px, inner 14.415px, centres at (24,24), (36.5,23.5), (23.5,36.5)) and dividing by 3.

`reference/` holds the same paths as plain SVG so the shapes can be opened and looked at, plus a
fourth arc (`ic_sysbar_back_ime`, the lower half) that is drawn but not currently wired up.

## Where the overlay lands

`DEVICE_PACKAGE_OVERLAYS` matches on a module's own path, so the same drawable is carried twice:
once for SystemUI, once for the launcher's quickstep copy. The launcher was renamed on
lineage-24.0 -- `packages/apps/Trebuchet` became `packages/apps/Launcher3` -- so both paths are
present. A path that matches nothing on a branch is simply ignored, which is why one tree serves
every branch; drop neither, or the nav bar goes half-stock on one of them.

## Why not just extract the originals

The stock art ships at **xxhdpi only**, 49×49 — about 16.3dp, off Android's 24dp icon grid, with no
other density in the APK. Every device that is not xxhdpi upscales a tiny bitmap, and even the
Robin does not escape it: it reports density 420, so the 480-bucket asset is resampled by 0.875.
Non-integer resampling of a 49px bitmap, on the phone the art came from.

The PNGs are also flat white with an alpha channel, so they cannot be tinted and stay white
whatever the nav bar is doing. These use `?attr/singleToneColor`, so they follow the nav bar and
Monet theming.

And they were drawn rather than lifted out of someone's firmware, so they are ours to ship.

## Two consumers, two icon sets

Who draws the 3-button bar depends on the branch:

| branch | drawn by | overlay path in `tree/` | canvas | colour |
|---|---|---|---|---|
| 20.0 / 21.0 | SystemUI `NavigationBarView` | `frameworks/base/packages/SystemUI/res/drawable/` | 28dp | `?attr/singleToneColor` |
| 22.2+ (`enable_taskbar_navbar_unification` on) | Launcher taskbar `NavbarButtonsViewController` | `packages/apps/Trebuchet/quickstep/res/drawable/` | 20dp | flat white, tinted by the ImageView |

Both sets ship on every branch; the unused one is inert. Same geometry, the Trebuchet set is shifted
by -4 so the ring re-centres on the smaller canvas. `?attr/singleToneColor` is a SystemUI attr and
does not resolve inside Launcher, hence the white fill.

Checking on device: `settings get secure navigation_mode` must be 0 (3-button). Gesture mode draws
a pill and no icons at all, which is why the option also preselects 3-button on the SetupWizard
navigation page (`patches/<branch>/packages/apps/SetupWizard/`); gestures stay one tap away.

## The QuickStep home button

SystemUI picks between two home drawables at runtime, in `NavigationBarView.java`:

```java
? getDrawable(R.drawable.ic_sysbar_home_quick_step)   // a QuickStep launcher is active
: getDrawable(R.drawable.ic_sysbar_home);
```

Trebuchet ships as TrebuchetQuickStep, so the QuickStep branch is the one that runs and
`ic_sysbar_home` alone never appears. Overriding only the three plain icons left a stock pill sitting
between a custom back and recents. `ic_sysbar_home_quick_step.xml` reuses the same ring on the 28dp
viewport stock uses for it.

Checking this needs care: counting `ic_sysbar_*` resources in `SystemUI.apk` proves nothing, because
stock ships those same names. Decode the compiled XML and look at `viewportWidth` — 28 with an
annulus path is ours, 20 is stock.
