# linux-chroot — a glibc Linux userland alongside Android

A Magisk module that runs Ubuntu Base (or any arm64 rootfs) in a chroot on the device. Deliberately
**not** baked into the ROM: nothing mounts at boot, so a broken rootfs can never affect Android's
boot path, and it survives ROM updates independently.

```sh
su
linux-setup     # once: downloads ~30 MB, unpacks to /data/linux
linux           # enter
linux uname -a  # or run one command
```

From the phone that means a terminal app: the `termoneplus` option bundles TermOne Plus (the ROM
ships no terminal of its own on 20.0+). From a PC, `adb shell` then the same.

## Why a chroot and not something better

Checked against the built kernel `.config` on bonito (4.9), vs995 (3.18) and ether (3.10) —
all three are the same story:

| capability | status | consequence |
|---|---|---|
| `CONFIG_KVM` | **absent** | Android 16's own AVF "Linux Terminal" (a real Debian VM) is impossible. It needs pKVM on a 5.10+ GKI kernel — a hardware/kernel-generation gap, not a config flip. |
| `CONFIG_PID_NS`, `CONFIG_IPC_NS` | **off** | No LXC / systemd-nspawn / Docker. No PID isolation: processes inside see and can signal Android's. |
| `CONFIG_USER_NS` | **off** | No rootless containers. Android disables this deliberately — it has a long history of local-privesc CVEs. |
| loop, ext4, overlayfs, cgroups, veth, tun, fuse, seccomp | **on** | chroot works fine, and networking/VPN tooling inside it will too. |

chroot requires none of the missing options.

## Optional: better isolation (requires a kernel rebuild)

`PID_NS`, `IPC_NS`, `DEVPTS_MULTIPLE_INSTANCES` and `CGROUP_DEVICE` are low-risk to enable in the
device kernel and would unlock real containers (`systemd-nspawn`, LXC) with genuine process
isolation. Android itself does not depend on them being off.

**Leave `USER_NS` off.** It is the one with real security weight on kernels this old, and nothing
here needs it.

## SELinux

Android's policy has no domain for arbitrary glibc binaries, so expect denials for anything unusual
even as root. Basic userland (apt, shells, editors, build tools) is generally fine.

`LXPERMISSIVE=1 linux` will `setenforce 0` for troubleshooting — note that this disables SELinux
**device-wide until reboot**, so use it to identify a denial, not as a normal mode of operation.
The proper fix is a dedicated sepolicy domain; that is the bulk of the work if this ever graduates
into a ROM feature.

## Notes

- Rootfs lives in `/data/linux`, not in the module — it grows to GBs. Unrelated to super-partition
  headroom.
- `/data` is `nodev,nosuid`. Harmless here: the chroot runs as root, and device nodes come from
  the bind-mounted `/dev`.
- apt is pinned to run as root (`/etc/apt/apt.conf.d/99-android`) because Android grants network
  access by group membership (AID_INET 3003), which apt's `_apt` sandbox user would drop.
- Ubuntu Base rather than Alpine: Alpine is ~10x smaller but musl, which breaks glibc-only binaries.
- Verified 2026-09-05: the pinned URL returns 29,865,086 bytes, valid gzip, `/bin/bash` is
  `ELF 64-bit LSB pie executable, ARM aarch64`, Ubuntu 24.04.3 LTS.

## Docker

```sh
lx-docker setup     # installs docker.io in the chroot + creates the ext4 backing image
lx-docker start     # mounts it, starts dockerd
docker run --rm --network=host alpine uname -a
```

Requires the `container` kernel fragment, which the `linux` option supplies (`KERNEL_CONFIGS` in its
`option.conf`; a device can also set `KERNEL_EXTRA_CONFIGS="container"` directly). It adds the
namespaces and cgroup controllers Android leaves off. Containers launched this way are
**real kernel namespaces on the Android kernel** — the chroot only supplies the glibc userland
dockerd links against, it is not emulation.

Two Android-specific workarounds are baked in, and both have consequences:

**Storage.** `/data` is f2fs, which overlay2 does not support as a backing filesystem, so
`/var/lib/docker` goes on a loop-mounted ext4 image (default 8 GB, sparse, at `/data/linux-docker.img`).
`LXDOCKER_VFS=1` uses the vfs driver instead — works anywhere, but copies every layer in full.

**Networking.** Android's netd owns the iptables chains and reprograms them, so Docker's NAT rules
for its bridge get flushed underneath it. dockerd therefore runs with `--iptables=false --bridge=none`,
and you use `--network=host`. **Port publishing (`-p`) will not work.** Bridge networking coexisting
with netd is unsolved.

Expect dockerd to complain about cgroups. Android mounts controllers at non-standard paths
(`/dev/cpuctl`, `/dev/blkio`, `/dev/cpuset`) with only freezer+memory on the v2 hierarchy, and a v1
controller can live in only one hierarchy — so it cannot simply be mounted where Docker looks.
The `container` fragment enables the controllers themselves (`CFS_BANDWIDTH`, `FAIR_GROUP_SCHED`,
`BLK_DEV_THROTTLING`, `MEMCG_KMEM`, …), which gets most limit flags working.

The remaining issue is that Android mounts cgroups with **`noprefix`**, so the control files are
named `shares` rather than `cpu.shares` — and runc looks for the prefixed names. That is a kernel
behaviour, not a config. `kernel-patches/cgroup-noprefix-symlinks.patch` (the `linux` option's
`KERNEL_PATCHES`) adds prefixed symlinks in `cgroup_add_file()` when `CGRP_ROOT_NOPREFIX` is set —
adapted from `fix_cgroup.patch` in
[tomxi1997/lxc-docker-support-for-android](https://github.com/tomxi1997/lxc-docker-support-for-android)
for kernels that still have the monolithic `kernel/cgroup.c`. It needs kernfs (3.14+); a device
whose kernel cannot take it sets `WITH_LINUX_CGROUP_PATCH=false` and gets unreliable limit flags.

## Not done yet

GUI. Options are Termux-X11 (best performance, needs the Termux app), or a VNC server in the chroot
plus any client (self-contained, laggier). Neither is wired up here.
