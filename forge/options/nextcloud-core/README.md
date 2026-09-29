# nextcloud-core

Files, Talk, NextPush and DAVx5: the four that make the phone a client of your own server. The
`nextcloud` bundle without Deck, NC Passwords, Notes and Tasks, for a device that cannot fit all
eight beside GApps.

| module | app | package |
|---|---|---|
| `NextcloudFiles` | Nextcloud (files, auto-upload, account) | `com.nextcloud.client` |
| `NextcloudTalk` | Talk (chat, calls) | `com.nextcloud.talk2` |
| `NextPush` | UnifiedPush distributor over Nextcloud (push for Talk) | `org.unifiedpush.distributor.nextpush` |
| `DAVx5` | CalDAV/CardDAV sync (contacts, calendars) | `at.bitfire.davdroid` |

About 270 MB of system (Talk is 156 MB: a universal APK shipped byte for byte). On the Pixel 3a XL
it fits beside GApps once Firefox (306 MB) is out of the preset; the whole bundle does not.

## Shape

The same patch, directory and fetcher as `nextcloud`, which see: `patches/` are that option's
verbatim, and the modules are guarded per APK, so which apps ship is decided by which APKs are in
`vendor/lineage/prebuilts/nextcloud`. `fetch.sh` asks `prebuilt/fetch-nextcloud.sh` for these
four (`NEXTCLOUD_MODULES`) and it removes the other four from the directory, so a tree that built
the whole bundle before does not ship it again. `require.sh` checks the four are there and the
rest are not; `post-build.sh` checks the same of the image, plus byte-identity and unpacked
libraries.

`nextcloud` and `nextcloud-core` on one build is an error (`require.sh`; the second patch would not
apply anyway). Keep the patches identical to `nextcloud`'s: regenerate both together.

## Updating

Nothing to bump for a new release -- the next build fetches it. Signer pins live in
`prebuilt/fetch-nextcloud.sh`.
