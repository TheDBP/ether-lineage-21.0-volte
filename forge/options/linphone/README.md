# linphone

[Linphone](https://linphone.org) as a SIP client, for devices with no VoLTE.

| | |
|---|---|
| package | `org.linphone` |
| size | 56 MB; native libraries stored and aligned, so nothing is unpacked beside it |
| licence | GPL-3.0 |
| needs | minSdk 28, so 20.0 (13), 22.2 (15) and 24.0 (17) all take it |

## What this is and is not

It is a SIP client. It does not register with the carrier's IMS, so it carries no mobile number of
its own, does not ring for ordinary incoming calls, and cannot place emergency calls. It is a voice
path only with a SIP account behind it -- a VoIP provider, a PBX, a SIP trunk with a real number.

It is worth baking in where the device has no VoLTE: on a carrier that has retired 2G and 3G there
is then no carrier voice at all, and SIP over LTE data is the only one left. Android removed its own
SIP stack in 12, so it has to be an app.

## Shape

The `k9` shape: `patches/<branch>` adds the guarded `PRODUCT_PACKAGES` line and
`prebuilts/linphone/`, and the APK is fetched per build by `prebuilt/fetch-linphone.sh`, which pins
the signer rather than the version. The patch anchors on common.mk's `Enable SIP+VoIP on all
targets` block, which every branch has.

Its libraries are stored and aligned today, so no JNI modules are defined and the Soong module needs
no `skip_preprocessed_apk_checks`. Both are decided per fetch, so a release that changes it is
handled rather than shipped broken -- `post-build.sh` fails if a library goes missing beside the APK.

## Updating

Nothing to bump for a new release -- the next build fetches it. The signer pin lives in
`prebuilt/fetch-linphone.sh`; `FDROID_PINS` holds a version when you need one.
