# linux

An on-device Linux environment — a chroot, and Docker on kernels that can take it.

## Shape

This is the first option that contributes to the **kernel** rather than to product config, so it
carries `KERNEL_CONFIGS` and `KERNEL_PATCHES` in `option.conf`. `apply-overlay.sh` folds those into
the same `KERNEL_EXTRA_CONFIGS` / `KERNEL_EXTRA_PATCHES` lists a device can set directly, so nothing
downstream needs to know an option was involved.

It ships no `product.mk`: nothing about it is a product-config question.

## The two sub-switches

Both are per-device escapes, set in `device.conf`, and both default to on:

| switch | why a device turns it off |
|---|---|
| `WITH_LINUX_FHANDLE` | Android's VINTF matrix requires `CONFIG_FHANDLE=n` on devices that enforce kernel requirements (the V20). dockerd wants it on. |
| `WITH_LINUX_CGROUP_PATCH` | The cgroup patch needs kernfs, which arrived in Linux 3.14. The Robin's 3.10 cannot take it. |

They are sub-switches rather than separate options because neither means anything on its own — they
only ever narrow what `linux` does.

## The Magisk module

`forge/modules/linux-chroot/` builds `linux-chroot-v0.1.zip`, installed through Magisk on the
device. That is a post-install step, not part of the image, so it is outside this option.
