# fdroid

The F-Droid client (`org.fdroid.fdroid`) and its Privileged Extension
(`org.fdroid.fdroid.privileged`): an app store that installs and updates silently, with no
"unknown sources" prompt. Both signed by F-Droid.

The extension is a priv-app; the patch copies a `privapp-permissions` allowlist granting
`INSTALL_PACKAGES`/`DELETE_PACKAGES` to `/product/etc/permissions`, and the client finds it by
its signature.

## Shape

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES + permissions XML in config/common.mk;
                                   prebuilts/fdroid/ jni/Android.mk (22.2+ only; Android.bp is fetched)
fetch.sh                           pulls both APKs into vendor/lineage/prebuilts/fdroid at sync time (flat:
                                   FDroid.apk, FDroidPrivilegedExtension.apk), unpacks the native libraries of
                                   either that packs them compressed to <Mod>/lib/arm64-v8a/, on 22.2+ writes
                                   Android.bp
post-patch.sh                      copies APKs + libraries into device/<vendor>/<codename>/fdroid/<Mod>/ when
                                   the device tree carries the modules (ether 20.0); runs after device patches
require.sh                         both APKs present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      both shipped APKs byte-identical to the fetched ones; unpacked libraries
                                   beside them
```

Same shape as `nextcloud`, for two apps; that README explains the fetch (latest suggested build,
signer pinned, `FDROID_PINS` to hold one), the per-branch module choice, the native-library rule
and the `uses-library` check. Like `firefox`, the ether 20.0 device tree carries its own modules
and only 22.2/23.2 have patches here.

## Updating

Nothing to bump for a new release -- the next build fetches it. Change `prebuilt/fetch-fdroid.sh`
only if F-Droid rotates its signing key.
