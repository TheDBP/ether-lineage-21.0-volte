# Releasing

A device's presets fall into two kinds, and only one kind should ever be published.

| preset / switch | has | for |
|---|---|---|
| `full` | GApps, root, and the free apps (`device.conf.example`: F-Droid, K-9, KDE Connect, ConnectBot) | your own phone |
| `clean` | none of that | the download page |
| a free-apps-only preset (ether calls it `libre`: F-Droid, K-9, KDE Connect, ConnectBot, no Google, no root) | nothing proprietary | publishable too |
| `EXTRA_OPTIONS=oem` | adds the manufacturer's reclaimed boot animation / wallpapers / sounds to any of them | your own phone only |

`oem` is not a preset. `EXTRA_OPTIONS` adds an option to whichever preset you build, and every
option added that way appends `-<name>` to the tag (sorted, so the same set always gives the same
tag): `clean` plus `oem` produces `turbo-clean-oem` rather than something that looks publishable,
and `libre` plus `nextcloud` produces `turbo-libre-nextcloud`. `release.sh` matches the tag
exactly, bounded by the date and codename in the filename, so a `turbo-libre-nextcloud` zip is not
the `turbo-libre` release.

The difference matters because GApps and the reclaimed assets belong to someone else. Running
them on a phone you own is uncontroversial; handing them out is redistribution. The realistic
consequence is not a letter to you — it is a DMCA notice to whoever hosts the file, landing on the
account that also holds every one of your repos.

`full` and `clean` differ by one flag and their filenames differ by one word, so publishing goes
through `forge/tools/release.sh`, which refuses anything it cannot prove is clean.

## Signing

AOSP's test keys are public: anyone can sign an APK or an "update" that a test-keys image will
accept. So a published image must be signed with keys only you hold, and `release.sh` refuses a zip
whose `META-INF/com/android/otacert` is the AOSP testkey.

Once, into a directory that is inside no repo:

```sh
./forge/tools/make-keys.sh ~/keys/rom '/C=US/O=YourHandle/OU=YourHandle/CN=YourHandle/emailAddress=you@example.org'
```

Then in `device.conf.local` (gitignored): `KEYS_DIR=/home/you/keys/rom`. The directory is bind-mounted
read-only into the container at `vendor/lineage-priv/keys`, where `vendor/lineage/config/common.mk`
already looks, so the source tree never holds a copy. One directory serves every device repo.

The subject is what every certificate on the phone will show, so it is a required argument rather
than something guessed from git config. Back the directory up off the machine: a lost `releasekey`
means every user wipes to take the next update. The first signed build installcleans by itself.

## Publishing

```sh
./forge/tools/release.sh --dry-run    # always do this first
./forge/tools/release.sh
```

One release per day and branch (tag `<branch>-<date>-<codename>`). Publishing a second preset the
same day adds its zip and recovery to that release, with its own section in the notes — build it,
then `release.sh --preset clean`; the audit reads the tree, so build and publish one preset at a
time. The release must be at the same commit; at any other it is a different build and refused.
Nothing here replaces or deletes a release.

## What it publishes

Per preset: the zip, and from the same build its `recovery.img` (as `<zip name>-recovery.img`),
each with its sha256 in the notes. The recovery is not optional: on an A-only device the zip does not write the
recovery partition, and the zip is signed with keys that only a recovery built alongside it trusts.
`RELEASE_NO_RECOVERY=1` in `device.conf` for a device whose recovery lives in the boot image (A/B
with no recovery partition) — the zip carries it, so nothing is published beside the zip.

## What it checks

1. **Preset options** — the preset's option set must contain neither `gapps` nor `oem`.
2. **Filename** — the artifact must carry that preset's tag, so a stray zip from another run
   cannot be picked up.
3. **Provenance** — `out/.turbo_config`, which the build writes for itself, must agree.
4. **Contents** — the staged system tree is scanned for anything that should not be leaving:
   - files byte-identical to something the OEM extractor staged (hash-matched, so it stays correct
     when the asset list changes)
   - GApps packages by name
   - **any wallpaper it cannot account for**
5. **Name** — the release title and tag are checked against `RELEASE_NAME_DENY`.

Checks 1–3 all trust a label of some kind. Check 4 does not, which is why it is there.

## When the audit stops you

It found something. Identify it before doing anything else.

If the file turns out to be redistributable, record it — do not turn the check off:

```sh
RELEASE_AUDIT_ALLOW="
  <sha256>  # what it is, and why it is safe to hand out
"
```

Every entry needs a reason. An allowlist with unexplained hashes in it is just a disabled check
with extra steps.

`--skip-content-audit` exists for the case where the build tree has been cleaned and there is
nothing left to scan. It is deliberately long to type.

## Naming

`RELEASE_NAME_DENY` defaults to a list of phone manufacturers. Trademark is the part of this with a
built-in incentive to enforce: marks have to be policed to stay valid, copyright does not. A
manufacturer who would never notice a ROM might well notice their brand on a download page.

Set `RELEASE_NAME` in `device.conf` to something that is yours. The device codename is fine.

## What it does not check

Every Android ROM contains proprietary vendor firmware — it will not boot otherwise. That is true
of official LineageOS builds too, and it is out of scope here. The release notes say so plainly
rather than implying the build is free of anything but your own code.
