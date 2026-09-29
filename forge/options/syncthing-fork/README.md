# syncthing-fork

[Syncthing-Fork](https://github.com/Catfriend1/syncthing-android): continuous file sync between
your own devices, peer to peer, no server or account.

| | |
|---|---|
| package | `com.github.catfriend1.syncthingfork` |
| size | 68 MB universal APK (four ABIs, cannot be trimmed without breaking the signature) + 27 MB core in `product/bin` + the arm64 libraries unpacked beside the APK |
| licence | MPL-2.0 |

Weigh the size before adding it to a preset on a device with a tight `product` partition.

## Shape

The `k9` shape with one extra: `patches/<branch>` adds the guarded `PRODUCT_PACKAGES` block and
`prebuilts/syncthing-fork/`, the APK is fetched per build by `prebuilt/fetch-syncthing-fork.sh`,
which pins the signer (Catfriend1's own key; the F-Droid build is reproducible) rather than the
version. The patch anchors on common.mk's `Xbox 360 controller` block, which every branch has.

The extra: the Syncthing core, `libsyncthingnative.so`, is not a library the app loads. The app
runs it as a process (`ProcessBuilder` on `nativeLibraryDir/libsyncthingnative.so`), and
`fs_config` gives every file under `product/app/` mode 0644, so a copy beside the APK can never be
executed -- the app would report "Syncthing core binary is missing" or die on EACCES. So:

- the fetcher extracts it to `prebuilts/syncthing-fork/syncthing` on every run;
- `SyncthingFork_core` installs it as `product/bin/syncthing` (0755 by `fs_config`, labelled
  `system_file`, which `appdomain` may execute) and drops a relative symlink
  `app/SyncthingFork/lib/arm64/libsyncthingnative.so -> ../../../../bin/syncthing`;
- the jni modules skip it.

`post-build.sh` proves the APK byte-identical, the libraries beside it, the core in `product/bin`
and the symlink resolving to it.

## Updating

Nothing to bump for a new release -- the next build fetches it. The signer pin lives in
`prebuilt/fetch-syncthing-fork.sh`; `FDROID_PINS` holds a version when you need one. If a release
moves the core out of `lib/arm64-v8a/libsyncthingnative.so`, the fetcher fails loudly.
