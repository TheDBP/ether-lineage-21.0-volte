# ether-lineage-21.0-volte

LineageOS 21.0 (Android 14) for the **Nextbit Robin** (`ether`, msm8992 / Snapdragon 808, 2016).
`main` carries no build config; the tree lives on
[`lineage-21.0-volte`](../../tree/lineage-21.0-volte).

> **Staged, not proven.** This starts as an exact copy of the working 20.0 series with the branch, base
> ref and lunch target repointed at 21.0. The patch series has not been rebased onto 21, and nothing
> here has been built or flashed yet.

| | |
|---|---|
| Android | 14 (LineageOS 21.0) |
| State | staged from 20.0; not built |
| Working 20.0 build | [ether-lineage-20.0-volte](https://github.com/TheDBP/ether-lineage-20.0-volte) |

LineageOS never carried ether past 18.1. The series replays onto the recovered 19.1 device tree
([ether-trees](https://github.com/TheDBP/ether-trees)) and is built with
[rom-forge](https://github.com/TheDBP/rom-forge), vendored as `forge/`.

21 is the last version this device will get: LineageOS 22 needs a kernel of at least 4.19 and the
Robin's is 3.10.
