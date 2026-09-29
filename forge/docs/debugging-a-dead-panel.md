# Debugging a dead panel

For the case where the screen goes black, stays black until a reboot, and the framework never
notices — `dumpsys power` still says `mWakefulness=Awake`, `sys.boot_completed` is 1, touch and
adb keep working. [debugging-a-vendor-blob.md](debugging-a-vendor-blob.md) covers a HAL that
crashes; this is the one that does not.

The worked example is a Pixel 3a XL on lineage-24.0, where changing the wallpaper or a colour
scheme killed the display every time.

## Separate the backlight from the pipeline first

```
cat /sys/class/backlight/panel0-backlight/bl_power     # 0 = on, 4 = off
cat /sys/class/backlight/panel0-backlight/brightness
dumpsys power | grep mWakefulness
```

Backlight off with the framework Awake means something below the framework switched the display
off. Writing `bl_power` back to 0 by hand and getting nothing is the tell that the CRTC is gone,
not the backlight — do not keep chasing brightness.

## Instrument the two functions that turn a display off

The forge ships this as an option — `EXTRA_OPTIONS=drm-trace` — so you do not have to hand-edit a
kernel tree and remember to revert it. See [`options/drm-trace/README.md`](../options/drm-trace/README.md).
What it does, and what to do if you are adding it somewhere else:

Nothing in logcat will name the culprit, because the kill happens in the kernel on behalf of a
userspace ioctl. Put `pr_info` + `dump_stack()` in `drm_atomic_helper_disable_plane()` and
`drm_atomic_helper_set_config()` in `drivers/gpu/drm/drm_atomic_helper.c`:

```c
if (printk_ratelimit()) {
        pr_info("FORGE: set_config [CRTC:%d] mode=%s by %s(%d)\n",
                set->crtc ? set->crtc->base.id : -1, set->mode ? "yes" : "NOMODE",
                current->comm, current->pid);
        dump_stack();
}
```

Rate-limit both: they are also called legitimately. **Declarations first** — these files build as
C90 and mixing declarations with code is an error, not a warning. Check the build result before
flashing; chaining a flash onto the same command flashes the previous kernel when the build fails.

`mode=NOMODE` on the primary CRTC is the event that kills the panel. A plane disable on its own is
survivable and happens during a normal boot.

## Read the stack

```
FORGE: set_config [CRTC:97] mode=NOMODE by kworker/2:2(1233)
  drm_atomic_helper_set_config <- drm_mode_set_config_internal <- drm_framebuffer_remove
    <- drm_mode_rmfb_work_fn <- process_one_work
```

That chain means **userspace removed a framebuffer the hardware was still using**. The kernel is
behaving as specified: `drm_framebuffer_remove()` force-disables every plane holding the fb, and
then the CRTC whose primary fb it was. The framework is never told, so nothing powers the display
back on.

`drm_mode_rmfb` only defers to that workqueue when the fb's refcount is still above 1 — so the
deferral *is* the proof the buffer was live. A synchronous rmfb of an unused fb never appears here.

## Do not chase the composer's EINVAL

Expect `WARN_ON` spam at `drm_atomic.c:868`, "FB set but no CRTC", attributed to the composer HAL,
and expect `drmModeAtomicCommit` to return `EINVAL`. **That is the consequence, not the cause.**
The kernel tore the CRTC out from under a plane the composer still has a framebuffer on, and the
composer keeps resubmitting the state it believes in. Fix the removal and the warning goes to zero
on its own; chasing it leads into the composer, which is not where the bug is.

## The rule this keeps proving

**Never `drmModeRmFB` a framebuffer the hardware may still be scanning out.** Downstream display
HALs get this wrong in more than one place, so fix the lifetime rule rather than the callers:
queue the id on destruction and drain the queue one full commit later.

In SDM (`sdm/libs/core/drm/hw_device_drm.cpp`) every removal funnels through
`~FrameBufferObject`, which called `RemoveFbId()` the moment its refcount hit zero. Cache eviction,
layer teardown and display reconfigure could each reach it. The cache overflows easily —
`UI_FBID_LIMIT` is 3 — and a wallpaper or theme change recreates nearly every surface at once,
which is why theming triggers it. Two QCOM commits created the hazard, `20ec28d0 "sdm: Clear fb_id
map if it exceeds the size limit"` and `0f70014c "sdm: Reduce the fb_id cache limit for UI layers"`;
there is no upstream fix.

## Verify with counters, not with the symptom

"It did not die that time" is not a result. Leave the instrumentation in and require the counts to
be zero across heavy churn — a dozen wallpaper and colour changes:

```
dmesg | grep -c "set_config \[CRTC:97\] mode=NOMODE"      # must be 0
dmesg | grep -c "FORGE: disable_plane"                    # may be non-zero, survivable
dmesg | grep -c "drm_atomic.c:868"                        # falls to 0 with the real fix
```

Build without `drm-trace` only after that passes, and keep it flashed while the fix is on trial:
it costs nothing when no event fires, and it is the only regression detector for this class.

Two traps while measuring:

- `dmesg` needs root. Counting with an unrooted shell returns 0 and reads as success.
- `dmesg` timestamps are uptime, logcat's are wall clock. Use `dmesg -T` or you will line a
  boot-time event up against a user action and analyse the wrong one.
- Both are ring buffers. A "baseline" taken half an hour earlier has already rotated out.
