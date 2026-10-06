# volte

The manufacturer's own IMS stack, rebuilt from that phone's stock firmware, so the device can place
calls over LTE.

On devices whose IMS is the platform's, VoLTE needs no option and this one never engages. On the
ones that need it — a 2016 handset whose OEM put the SIP stack in its own app — carriers have been
retiring the 2G/3G circuit-switched voice the phone falls back to, so without this the device stops
being a phone. That is the stake, and it is why this option defaults differently from every other.

## Why it exists at all

An OEM IMS stack cannot be built from source, because there is no source. It is the manufacturer's
app, framework jars and native libraries, taken out of the firmware the phone shipped with and
reworked onto a modern platform. None of that may be redistributed, so a device repo can carry the
recipe and none of the ingredients.

That leaves a repo that cannot be built by anyone but its maintainer — which is what both devices
here were until this option existed. Gating IMS turns "you cannot build this" into "you can build
this, and here is what you are missing".

## Three states, because two is not enough

| you said | firmware present | result |
|---|---|---|
| nothing | yes | **on.** Nobody who supplied their phone's firmware wanted a phone that cannot call |
| nothing | no | **off**, announced on stdout, and the build tag gains `-novolte` |
| `volte` | no | **the build stops** |

The third row is the point. An explicit request is never silently downgraded — the alternative is
handing someone an image tagged for VoLTE that cannot place a call, and they find out from a failed
call rather than from a build log.

The second row is the one that needs discipline. "Same command, same repo, two different images" is
the failure `options/README.md`'s sub-switch rule exists to prevent, and the reason the Robin's
`device.mk` staging was written to refuse rather than degrade. Auto-detection is fine; silence is
not. So the absence is said out loud and recorded in the filename — and the absence, not the
presence, is what the tag marks, because on these devices VoLTE is the expected state.

## What a device supplies

Three keys in `device.conf` (see `device.conf.example`):

- `VOLTE_STOCK_GLOB` — what the user drops in the repo root. Whatever the stage script can read.
- `VOLTE_STAGE_SCRIPT` — run after the device patches, as `<script> <stock-file> <aosp-root>`.
  Optional: a device may stage from its own `device.mk` instead, as the Robin does.
- `VOLTE_STAGED_MARKER` — the file that exists only once staging worked. This is the whole safety
  net: it is what "already staged", "skip the rework" and "refuse to build" all test.

Which packages make up IMS is device-specific, so the device tree gates those on `WITH_VOLTE`. This
option installs nothing itself.

## Notes

Staging is idempotent by marker, because it is minutes of deodexing and dex rewriting. Delete the
marker to force a re-stage. A `repo sync --force-sync` that resets the device tree takes the staged
artifacts with it, and the next build rebuilds them — which is why the stock input is looked for
every time rather than once.
