# k9

K-9 Mail (`com.fsck.k9`) as the mail client. LineageOS ships none.

K-9 and Thunderbird for Android are the same codebase (Mozilla owns both); K-9 is the one
without the Thunderbird account-setup funnel, so it is the one bundled. F-Droid build, signed by
upstream (a reproducible build), ~11 MB, no GMS dependency.

## Shape

```
patches/<branch>/vendor/lineage/   guarded PRODUCT_PACKAGES in config/common.mk; prebuilts/k9/
                                   module (20.0: Android.mk; 22.2+: jni/Android.mk, Android.bp is fetched)
fetch.sh                           pulls the APK into vendor/lineage/prebuilts/k9 at sync time, unpacks its
                                   native libraries if it packs them compressed, on 22.2+ writes Android.bp
require.sh                         APK present and named in the module file; on 20.0, the build/make
                                   presigned-warn patch applied
post-build.sh                      shipped APK byte-identical to the fetched one; unpacked libraries beside it
```

Same shape as `nextcloud`, for one app; that README explains the fetch (latest suggested build,
signer pinned, `FDROID_PINS` to hold one), the per-branch module choice, the native-library rule and
the `uses-library` check. No device-tree involvement, unlike `firefox`/`fdroid`: the module lives
in `vendor/lineage` on every branch, so the option is the whole feature.

The `PRODUCT_PACKAGES` line is guarded on the APK existing (naming a module with no APK fails
`lunch`); `require.sh` then refuses to build with the option on and the APK absent, so the guard
cannot turn into a silent no-mail image.

Each option's `config/common.mk` hunk anchors on a distinct pristine block (22.2: `k9` after
`rsync`, `kdeconnect` after `init.openssh.rc`, `termoneplus` after the Root `endif`s, `fdroid`
after `android.software.credentials.prebuilt.xml`, `firefox` at EOF), so any subset applies in any
order; a new option must pick another.

## Updating

Nothing to bump for a new release -- the next build fetches it. Change `prebuilt/fetch-k9.sh`
only when upstream rotates its signing key (confirm the rotation with upstream first).
