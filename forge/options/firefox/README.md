# firefox

Not the default any more: the example presets carry `fulguris` instead, because Fennec stages
320 MB against its 9 MB and that is the difference between fitting and not on a smaller device.
Nothing here has gone away -- put `firefox` back in a preset on a device with the room.

Firefox (Fennec F-Droid, `org.mozilla.fennec_fdroid`) as the browser, replacing Jelly.

The module carries `overrides: ["Jelly"]` / `LOCAL_OVERRIDES_PACKAGES := Jelly`, so exactly one
browser ends up on the image and Android resolves the browser role on its own -- nothing has to
declare a default.

## Shape

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES in config/common.mk; prebuilts/firefox/
                                   jni/Android.mk (22.2+ only; Android.bp is fetched)
fetch.sh                           pulls the APK into vendor/lineage/prebuilts/firefox at sync time,
                                   unpacks lib/arm64-v8a/ beside it, on 22.2+ writes Android.bp
post-patch.sh                      copies APK + libraries into device/<vendor>/<codename>/firefox/ when the
                                   device tree carries the module (ether 20.0); runs after device patches
require.sh                         APK present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      shipped APK byte-identical to the fetched one; every unpacked library beside it
```

Same shape as `k9` (and so `nextcloud`); those READMEs explain the fetch (latest suggested build,
signer pinned), the per-branch module choice, the native-library rule and the `uses-library` check.

## Where the module lives

Only 22.2 and 23.2 have patches here, because only those add a module to `vendor/lineage`. The
ether 20.0 device tree carries its own `firefox/Android.mk` (its patch series), and
`post-patch.sh` places the APK there -- so "no patches for 20.0" does not mean "no Firefox on
20.0". The copy cannot live in `fetch.sh`: that runs before the device patches, when the directory
does not exist yet.

F-Droid publishes Fennec per ABI under one package, three versionCodes per release; the suggested
build is the arm64 one, and the fetch fails on "not an arm64 build" if that ever changes.

## It appears as "Fennec"

The `application-label` is **Fennec**, which is what the F-Droid build of Firefox calls itself.
Looking for "Firefox" in the launcher will not find it.

## Why byte for byte

`BUILD_PREBUILT` with `LOCAL_CERTIFICATE := PRESIGNED` rewrites the archive -- it uncompresses
every embedded `.so` -- and a v2 signature covers the whole file, so the re-zip invalidates it.
Fennec is mostly `libxul.so`: the APK went from 127,545,689 bytes fetched to 242,684,607 installed,
and the device refused it with `INSTALL_PARSE_FAILED_NO_CERTIFICATES`. PackageManager hits that
during the boot scan and skips the package silently, so the build succeeds and the browser is
simply absent. `LOCAL_SDK_VERSION := current` (20.0) / `preprocessed: true` (22.2+) select the
copy-only path; `post-build.sh` fails the build on any difference.

Fennec packs its libraries compressed (`extractNativeLibs=true`), so the fetcher unpacks
`lib/arm64-v8a/` beside the APK and the module installs it as `<app>/lib/arm64/*.so`; without that
every launch dies in `UnsatisfiedLinkError: libjnidispatch.so`.

## Updating

Nothing to bump for a new release -- the next build fetches it. Change `prebuilt/fetch-firefox.sh`
only if Fennec's signing key rotates (confirm with upstream first).
