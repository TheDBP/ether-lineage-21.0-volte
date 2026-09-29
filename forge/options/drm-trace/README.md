# drm-trace

Kernel instrumentation for a display that switches off and stays off while the framework still
believes it is on. Adds `pr_info` + `dump_stack()` to the two functions that turn a display off:

- `drm_atomic_helper_disable_plane()` — `FORGE: disable_plane [PLANE:n] by comm(pid)`
- `drm_atomic_helper_set_config()` — `FORGE: set_config [CRTC:n] mode=yes|NOMODE by comm(pid)`

`mode=NOMODE` on the primary CRTC is the line that kills the panel. A plane disable on its own is
survivable and happens on a healthy boot, so count them separately.

Both prints are rate-limited: these are called legitimately too, and an unlimited `dump_stack()` in
the atomic path floods the ring buffer and hides the event you want.

## Using it

```sh
EXTRA_OPTIONS=drm-trace PRESET=clean ./forge/bootstrap.sh
```

Then, with `adb root` (unrooted `dmesg` returns nothing and reads as a clean run):

```sh
adb shell 'dmesg -T | grep -c "set_config \[CRTC:<primary>\] mode=NOMODE"'
adb shell 'dmesg -T | grep -A20 "mode=NOMODE"'      # the stack naming the caller
```

Use `dmesg -T`. Raw `dmesg` stamps uptime while logcat stamps wall clock, and lining a boot-time
event up against a user action is how you end up analysing the wrong one.

## Reading it

A stack of `drm_mode_rmfb_work_fn -> drm_framebuffer_remove -> drm_mode_set_config_internal` means
userspace removed a framebuffer the hardware was still scanning out — see
[`docs/debugging-a-dead-panel.md`](../../docs/debugging-a-dead-panel.md), which works the whole case
through. The kernel only defers to that workqueue when the fb is still referenced, so its presence
is itself the proof.

## Do not ship it

Every event costs a stack trace in the log. Keep it on while a display fix is on trial — it is the
only detector for a regression of this class, and it is silent when nothing fires — then build
without it for release.
