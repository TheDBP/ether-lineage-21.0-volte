# nextcloud

The Nextcloud bundle, one option: the phone as a client of your own server, out of the box.

| module | app | package | signed by |
|---|---|---|---|
| `NextcloudFiles` | Nextcloud (files, auto-upload, account) | `com.nextcloud.client` | Nextcloud GmbH |
| `NextcloudTalk` | Talk (chat, calls) | `com.nextcloud.talk2` | Nextcloud GmbH |
| `NextPush` | UnifiedPush distributor over Nextcloud (push for Talk and the rest) | `org.unifiedpush.distributor.nextpush` | its author |
| `NextcloudDeck` | Deck (kanban) | `it.niedermann.nextcloud.deck` | its author |
| `NCPasswords` | NC Passwords — client for the *Passwords* server app | `de.jbservices.nc_passwords_app` | its author |
| `NextcloudNotes` | Notes | `it.niedermann.owncloud.notes` | its author |
| `DAVx5` | CalDAV/CardDAV sync (contacts, calendars, tasks into the system providers) | `at.bitfire.davdroid` | bitfire |
| `Tasks` | Tasks.org (CalDAV tasks UI, pairs with DAVx5) | `org.tasks` | its author |

All F-Droid builds, all arm64, about 350 MB together (Talk alone is 157 MB: a universal APK, and it
must ship byte for byte, so no ABI stripping). Nothing needs GMS: NextPush is the push path.

NC Passwords is one of the two Android clients the Passwords server app lists; the other is
`com.hegocre.nextcloudpasswords`. Nextcloud GmbH ships no Passwords client of its own.

## Shape

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES in config/common.mk; prebuilts/nextcloud/
                                   modules (20.0: Android.mk; 22.2+: jni/Android.mk, Android.bp is fetched)
fetch.sh                           pulls the eight APKs into vendor/lineage/prebuilts/nextcloud at sync time,
                                   unpacks the native libraries of any that packs them compressed, and on
                                   22.2+ writes Android.bp
require.sh                         all eight present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      every shipped APK byte-identical to the fetched one; unpacked libraries
                                   installed beside it
```

The shape every fetched-app option shares (`k9`, `kdeconnect`, `termoneplus`, `firefox`,
`fdroid`), times eight. **The version is not pinned.** `fetch.sh` takes the build F-Droid currently
suggests for each package and accepts it only if its signing certificate matches the sha256 pinned
in `prebuilt/fetch-nextcloud.sh` (`apksigner verify`, whole file). The image carries the apps as
they are on the day it is built. `FDROID_PINS="pkg=versionCode …"` holds any of them to one build.
If F-Droid is unreachable, or names a build it has already moved, a cached copy that verifies is
used with a warning.

`PRODUCT_PACKAGES` is one `$(foreach)` guarded per APK (naming a module with no APK fails `lunch`);
`require.sh` refuses to build with the option on and any APK absent, so the guard cannot turn into a
silently smaller bundle.

## Why the module shape differs per branch

The APKs must be installed byte for byte: any rewrite invalidates the v2 signature and, at targetSdk
35+, PackageManager rejects the package at boot scan without logging. Most of these ship their dex
Deflated, and both build systems want to "fix" that.

- **22.2 / 23.2** — `android_app_import { preprocessed: true, enforce_uses_libs: false }`, one per
  app, like `k9` — but **written by the fetcher**, not shipped in the patch. Soong's check on a
  preprocessed APK (`check_prebuilt_presigned_apk.py`: `zipalign -c -p 4`, every `lib/**/*.so`
  stored) must be skipped with `skip_preprocessed_apk_checks: true` on an APK that fails it, and
  Soong fails the build if the flag is set on one that passes. Which apps fail changes with their
  releases (today: NC Passwords, a Flutter app with compressed libs), so the file is regenerated on
  every fetch and gitignored.
- **20.0** — `BUILD_PREBUILT` with `LOCAL_SDK_VERSION := current` takes the `do_not_alter_apk`
  path, whose compression check then fails on the Deflated dex. ether-20.0 carries a `build/make`
  patch that makes it a warning; `require.sh` checks for that patch and stops the build if it is
  missing. One `define` stamped out per module; a module exists only when its APK does.

## Native libraries

PackageManager never extracts native libraries for a bundled system app, and the linker cannot
dlopen a compressed zip entry, so an app whose APK packs them compressed (or unaligned) would die at
launch in `UnsatisfiedLinkError`. The fetcher classifies each APK with the same test as Soong's
check (`fdroid_apk_libs_loadable` in `prebuilt/lib-fdroid.sh`) and, for the ones that fail, unpacks
`lib/arm64-v8a/*.so` to `prebuilts/nextcloud/<App>/lib/arm64-v8a/`; the module installs those as
`<app>/lib/arm64/*.so` — `LOCAL_PREBUILT_JNI_LIBS` on 20.0, one `BUILD_PREBUILT` module per library
from `jni/Android.mk` on 22.2+ (`android_app_import` has no such property), both from a wildcard so
the patches carry no per-app knowledge.

The `<uses-library>` check is off on every branch (`LOCAL_ENFORCE_USES_LIBRARIES := false` /
`enforce_uses_libs: false`): the manifests move with each fetch, so a mirrored list would break the
build on the first upstream release that adds one. The check only guards dexpreopt, which is off for
these modules anyway.

## Size

Budget ~350 MB of system (plus the unpacked libraries of any app that needs them: ~18 MB today).
On the Robin (3072 MB system) `full` (GApps + Firefox + everything else) comes within ~130 MB of
the limit with it.

## Updating

Nothing to bump for a new app release — the next build fetches it. Change
`prebuilt/fetch-nextcloud.sh` only to add or drop an app, or when an upstream rotates its signing
key (`java -jar prebuilts/sdk/tools/linux/lib/apksigner.jar verify --print-certs <apk>`, Signer #1
SHA-256 — and confirm the rotation with upstream before trusting it).
