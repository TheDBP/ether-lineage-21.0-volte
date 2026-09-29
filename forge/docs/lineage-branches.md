# LineageOS branch landscape — which branch to actually target

Verified 2026-09-09 against the LineageOS org over the network. Re-check with the commands at the
bottom rather than trusting the tables; branches move.

## Version mapping

Taken from each manifest branch's `default.xml` AOSP tag, not from memory.

| Lineage branch | AOSP tag | Android | Manifest last touched | State |
|---|---|---|---|---|
| `lineage-22.1` | `android-15.0.0_r?` | 15 | 2025-04-14 | dead |
| `lineage-22.2` | `android-15.0.0_r32` | 15 | 2026-08-26 | **live** (2026-09 ASB) |
| `lineage-23.0` | `android-16.0.0_r1` | 16 | 2025-12-27 | frozen |
| `lineage-23.1` | `android-16.0.0_r3` | 16 QPR1 | 2025-12-27 | frozen |
| `lineage-23.2` | `android-16.0.0_r4` | 16 QPR2 | 2026-08-19 | **live** (2026-09 ASB) |
| `lineage-24.0` | `android-17.0.0_r1` | **17** | 2026-08-19 | **live**, new |

Three branches take security bulletins concurrently: 22.2, 23.2 and 24.0. `23.0` and `23.1` both
stopped on the same day and are superseded — **do not target them**. Expect 23.2 to freeze the same
way once 24.0 matures: a new port that is not yet building should target 24.0, not 23.2.

## The kernel floor: 16+ needs 4.14-era eBPF

[Changelog 30](https://lineageos.org/Changelog-30/): Android 16 "requires Linux 5.4 and above, and
... the necessary features have only been properly backported as far back as 4.14 ... no complete
backports of the required features exist for [4.4 and 4.9]". LineageOS's own common kernels: MSM8996
(4.4) and SDM845 (4.9) end at Android 15; SM8150 (4.14) gets 16. A device on 4.4/4.9 has no 23.x or
24.0 port until someone adapts those backports onto its kernel — a kernel networking/bpf job, not
device-tree work. The release config per branch is `vendor/lineage/vars/aosp_target_release`
(`bp1a` 22.2, `bp4a` 23.2, `cp2a` 24.0); the lunch combo is `lineage_<codename>-<config>-<variant>`.

## The trap: a newer branch number can be an OLDER tree

The important lesson from the Pixel 3a XL. `bonito` has a `lineage-23.0` device tree, which looks
like the obvious base for an Android 16 port. It is not:

```
$ git merge-base origin/lineage-22.2 origin/lineage-23.0     # == the 23.0 tip itself
$ git rev-list --count origin/lineage-22.2..origin/lineage-23.0    # 0
$ git rev-list --count origin/lineage-23.0..origin/lineage-22.2    # 9
```

`lineage-23.0` is a strict **ancestor** of `lineage-22.2`. LineageOS branched it in 2025-08 and never
touched it again, while 22.2 kept getting real modernisation (audio HAL to blueprint, namespace
import updates, dropping stale in-tree kernel headers). Building on the 23.0 tree would silently
throw all of that away.

**Always check the merge-base before assuming a higher branch number means newer code.** A device
whose newest branch is frozen has effectively been dropped at that version, and its "newer" tree is
a stale fork point.

## What a version bump actually costs at the device-tree level

Measured on `redfin`, which made both moves properly:

| Move | Cost |
|---|---|
| 22.2 -> 23.0 (Android 15 -> 16) | 8 commits, 5 files, +10/-29 lines |
| 23.0 -> 23.2 (16 -> 16 QPR2) | 7 commits, 33 files, nearly all deletions |

The 22.2 -> 23.0 commits are all one genre: compat shims and cleanup —
*"Shim libsecureuisvc_jni with libgui_shim"*, *"Address missing libbinder symbols"*,
*"Drop unused AndroidBoard.mk"*, sepolicy trimming.

So **the device tree is rarely the obstacle** in a version bump. Budget the effort for platform and
vendor-blob compatibility instead: HAL interface versions, VINTF, SELinux, and modules that moved
into mainline APEXes. That is where the 18.1 -> 20.0 ether port spent all of its time.

Caveat on generalising: redfin is a 2020 Pixel with first-class blob support. Older Qualcomm
hardware hits far more friction, and none of it shows up in the device-tree diff.

## Re-checking

```sh
# which branches exist for a device tree
git ls-remote --heads https://github.com/LineageOS/android_device_<vendor>_<codename>

# is a branch alive, and what Android is it?
curl -s https://api.github.com/repos/LineageOS/android/commits/<branch> | grep -m1 '"date"'
curl -s https://raw.githubusercontent.com/LineageOS/android/<branch>/default.xml \
  | grep -oE 'revision="refs/tags/android-[^"]*"' | head -1

# is the "newer" branch actually newer? (run inside a clone with --no-single-branch)
git rev-list --count origin/<older>..origin/<newer>
```
