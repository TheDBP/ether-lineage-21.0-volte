# The flashlight on the Nextbit Robin

The torch tile worked from the day the port booted. It reported on, it reported off, it never once
returned an error — and the LED stayed dark for months.

This is what was actually wrong. There were three faults stacked behind each other, and each one had
to be removed before the next became visible. None of them looked like what it was.

---

## 1. The tile was lying, and so was the driver

`QCameraFlash` in the device tree writes two sysfs nodes:

    /sys/class/leds/led:torch_0/brightness
    /sys/class/leds/led:torch_1/brightness

Those belong to the PMI8994 `qpnp-flash-led` block. They exist, they accept writes, and the writes
succeed. Reading the driver's own register dump back confirms the PMIC is being programmed: module
enable `0xd342` moves `0x00 -> 0x0f`, strobe control `0xd347` moves `0x40 -> 0xc0`. Everything about
the software path looks correct.

**Nothing on this board is connected to that block.** The nodes exist only because QCOM's reference
`msm-pmi8994.dtsi` is included in the device tree. No light, at any current, on either channel, in
torch or flash mode. Measured, not inferred.

Two facts either of which would have ended the detour early:

- `pmi8994_boostbypass` and `pon_spare_reg` sit at `state=disabled use=0` with the torch commanded at
  maximum. `use=0` means no consumer ever acquired them — the DTS torch nodes carry `regulator-name`
  children but no `<name>-supply` phandle, so `regulator_get()` cannot resolve them. That block could
  not light even if it were wired.
- The stock 7.1 camera HAL exports no `set_torch_mode` and no `QCameraFlash` at all, only
  `CameraParameters::FLASH_MODE_TORCH`. **Stock had no torch API.** Its flashlight ran through the
  camera pipeline, because that is the only path to the real part.

The real part is a **TI LM3646** on the CCI bus:

    led_flash0: qcom,led-flash@ce {
        compatible = "ti,lm3646";
        qcom,cci-master = <0>;
        gpios = <&pm8994_gpios 1 0>, <&pm8994_gpios 2 0>;   /* FLASH_EN, FLASH_NOW */
        qcom,max-current = <1200 1200>;
    };

The lesson worth keeping is not "it was the wrong chip". It is that **a driver being present, bound,
and accepting writes is not evidence that anything is attached to it.** A reference dtsi will happily
give you a complete, functional, correctly-behaving path to nowhere.

## 2. Finding the right subdev, and two ways to get it wrong

The LM3646 is reached through a V4L2 subdev. This kernel carries *two* flash frameworks and they are
not interchangeable:

| framework | ioctl | payload |
|---|---|---|
| `msm_led_flash.c` | `VIDIOC_MSM_FLASH_LED_DATA_CFG` | flat `msm_camera_led_cfg_t` |
| `msm_flash.c` | `VIDIOC_MSM_FLASH_CFG` | `msm_flash_cfg_data_t`, full of userspace pointers |

This device uses the first. `MSM_CAMERA_LED_LOW` is torch, `HIGH` is the capture strobe.

Two obvious ways to find the subdev are both wrong:

**By index.** `/dev/v4l-subdev9` is the flash today. It is not guaranteed to be tomorrow, and a
stale index does not fail — it programs whatever else answers.

**By `entity.name` from `MEDIA_IOC_ENUM_ENTITIES`.** This one is a genuine trap. `msm_sd_register()`
overwrites the name with the device node's own name:

    msm.c:320   sd->entity.name = video_device_node_name(vdev);

So the entity is called `v4l-subdev9`, not `msm_flash`, and searching the entity list for the subdev
name finds nothing. The real name survives only in `/sys/class/video4linux/<node>/name`, which the
camera domain cannot read.

Both frameworks also register under the same `group_id` (`MSM_CAMERA_SUBDEV_FLASH`), so group alone
does not disambiguate them.

What works: enumerate media entities for that group, then settle which framework probed **by which
ioctl the subdev accepts**. `msm_led_flash.c` answers `VIDIOC_MSM_FLASH_LED_DATA_CFG`; `msm_flash.c`
returns `ENOTTY` for it. The device tells you what it is.

## 3. The fault that read as a bus error and was a power one

With discovery correct and the ioctl reaching the driver, `MSM_CAMERA_LED_INIT` failed:

    msm_cci_i2c_write: wait_for_completion_timeout 681
    msm_cci_flush_queue:113 wait timeout
    msm_camera_cci_i2c_write_table: line 217 rc = -110
    msm_flash_led_init:224 failed

`-110` is `ETIMEDOUT`. There is no `cci_init failed` in that log, which matters: CCI itself came up
correctly — the GDSC, the clocks and the CCI reset all succeeded. What failed is the first i2c write
to the chip.

That reads like a bus fault. It is not:

    /sys/kernel/debug/regulator/pm8994_lvs1
      enable      0
      use_count   0

`pm8994_lvs1` is `cam_vio`. The chip's I/O rail is off, so it cannot acknowledge, and **an unpowered
i2c slave does not NACK — the transfer simply never completes** and surfaces as a queue timeout. The
error you get points at the bus; the fault is in the power tree.

Why the rail is off is structural. The flash is owned by the rear sensor node:

    qcom,camera@0 {
        qcom,led-flash-src = <&led_flash0>;
        cam_vio-supply = <&pm8994_lvs1>;
        qcom,cam-vreg-name = "cam_vdig", "cam_vio", "cam_vana", "cam_vaf";
    };

**`led_flash0` declares no regulators of its own.** Every rail belongs to the sensor, so the chip is
powered exactly when a camera session is open and at no other time. And `msm_led_i2c_trigger.c` has
no regulator handling whatsoever — no vreg parsing, no `msm_camera_power_up`. It assumes the chip is
already powered, which for a flash driven from the camera pipeline it always was.

Which closes the loop with §1: this is *why* stock had no torch API.

## 4. The fix

Two files, one logical change, in `overlay/patches/kernel/nextbit/msm8992/`:

- the DTS gives `led_flash0` its own `cam_vio-supply` (both the dvt/pvt and evt camera dtsi),
- `msm_led_i2c_trigger.c` parses the flash node's regulators and brings them up in
  `msm_flash_led_init()` before CCI, dropping them in `msm_flash_led_release()`.

The regulator core refcounts, so naming the same supply the sensor uses costs nothing while a camera
session holds it. A flash node that declares no rails parses to `num_vreg 0` and behaves exactly as
before, so the change is inert on any other board.

One trap in the implementation. `msm_camera_get_dt_vreg_data()` assigns
`of_property_count_strings()` — which returns `-EINVAL` when the property is absent — into a
`uint32_t`. Calling it unguarded on a node without regulators therefore asks for a ~4-billion-element
`kzalloc` and returns `-ENOMEM`, failing probe on every board that does not need any of this. The
count is checked in the caller.

**Verified on hardware, 2026-09-24.** CCI now completes with no timeout, the framework sees the whole
lifecycle (`torch status is now AVAILABLE_ON` → `Torch for camera id 0 turned on` → `AVAILABLE_OFF`),
and `pm8994_lvs1` returns to `enable 0 use_count 0` afterwards — so the release path drops the rail
rather than stranding it on.

## 5. The bug the fix exposed

Making the HAL honest broke something that had been quietly protected by it lying.

    FATAL EXCEPTION: SysUiBg
    java.lang.IllegalArgumentException: setTorchMode:2394: Camera "0" has no flashlight
        at FlashlightControllerImpl$$ExternalSyntheticLambda0.run

`FlashlightControllerImpl` catches `CameraAccessException` around `CameraManager.setTorchMode()` and
nothing else. `setTorchMode()` turns a service-side refusal into an unchecked
`IllegalArgumentException`, and the call runs on a background executor — so any HAL refusal is a
fatal uncaught exception and tapping the tile restarts SystemUI.

It had never surfaced because the old sysfs writes always succeeded. The HAL had never returned an
error in the entire life of the port.

The message is also misleading: `dumpsys media.camera` says `Has a flash unit: true`. "Has no
flashlight" is what CameraService prints for `-ENOSYS`, which is what the legacy provider maps an
unrecognised HAL error to. It describes the mapping, not the hardware.

Fixed in `overlay/patches/frameworks/base/` by catching `RuntimeException` as well and routing it to
`dispatchError()`, which greys the tile out — the path that already existed for exactly this.

---

## What this cost, and why

Three faults, each masked by the one in front of it:

1. a complete, working software path to a chip that is not connected,
2. a subdev whose name is overwritten by the framework that registers it,
3. a power fault that reports itself as a bus timeout.

The through-line is that **every layer reported success or a plausible-but-wrong error**. The tile
said on. The PMIC registers moved. CCI initialised cleanly. The one measurement that would have cut
through it at any stage — is the LED actually emitting light, and is its rail actually powered —
was not taken until late.

Two corroborating facts were sitting in the tree the whole time and were read but not weighted:
`use=0` on the PMIC regulators, and stock having no torch API at all. Both said "this path is not the
one" in the first hour.
