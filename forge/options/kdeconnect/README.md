# kdeconnect

KDE Connect (`org.kde.kdeconnect_tp`): phone <-> desktop link -- notifications, clipboard, file
transfer, remote input, media control, "find my phone". Pairs with KDE Connect on Linux desktops
and with GSConnect on GNOME. F-Droid build, F-Droid's signature, ~7 MB, no GMS dependency.

Same shape as `k9` (and so `nextcloud`); those READMEs explain the fetch, the per-branch module
choice and the native-library rule.

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES in config/common.mk; prebuilts/kdeconnect/
                                   module (20.0: Android.mk; 22.2+: jni/Android.mk, Android.bp is fetched)
fetch.sh                           pulls the APK into vendor/lineage/prebuilts/kdeconnect at sync time
require.sh                         APK present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      shipped APK byte-identical to the fetched one; unpacked libraries beside it
```

## Updating

Nothing to bump for a new release -- the next build fetches it. Change
`prebuilt/fetch-kdeconnect.sh` only if F-Droid rotates its signing key.
