# connectbot

[ConnectBot](https://connectbot.org) as an SSH client.

| | |
|---|---|
| package | `org.connectbot` |
| size | 15 MB; native libraries stored and aligned, so nothing is unpacked beside it |
| licence | Apache-2.0 |

Lineage already ships the OpenSSH binaries (`ssh`, `scp`, `sftp`, `sshd`) in `config/common.mk`, so
with `termoneplus` you can already reach a host from a shell. This is for the part a phone actually
wants: saved hosts, key generation and an agent, port forwarding, and a keyboard that suits a
terminal, without a terminal app in the way.

## Shape

The `k9` shape: `patches/<branch>` adds the guarded `PRODUCT_PACKAGES` line and
`prebuilts/connectbot/`, and the APK is fetched per build by `prebuilt/fetch-connectbot.sh`, which
pins the signer rather than the version. The patch anchors on common.mk's `Extra tools in Lineage`
block, which every branch has -- an SSH client is one.

## Updating

Nothing to bump for a new release -- the next build fetches it. The signer pin lives in
`prebuilt/fetch-connectbot.sh`; `FDROID_PINS` holds a version when you need one.
