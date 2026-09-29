# Debugging a vendor blob

For the case where a prebuilt HAL worked on the old branch and crashes on the new one, with the
same blob, the same device and the same config. [docs/debugging-a-boot-loop.md](debugging-a-boot-loop.md)
covers getting a device to boot at all; this is the next layer down, when something boots but one
subsystem is dead and the logs do not explain it.

The worked example throughout is a camera HAL that segfaulted on lineage-24.0 and worked on 22.2.

## Start with the symbol gap

`tools/abi-gap.sh <blob>` lists the symbols a prebuilt imports that the running platform no longer
exports. It pulls the blob and its `DT_NEEDED` set off the device, because the device is the only
authoritative answer to "what does this ROM export". Run it before forming any theory -- it is
thirty seconds and it either hands you the answer or rules out a whole class of cause.

    abi-gap.sh /vendor/lib64/libimsmedia_jni.so
    >> libimsmedia_jni.so: imports 18 symbols, 1 unresolved
       _ZN7android7SurfaceC1ERKNS_2spINS_22IGraphicBufferProducerEEEb
           android::Surface::Surface(android::sp<android::IGraphicBufferProducer> const&, bool)

Three things it taught us on ether that generalise:

- **A blob that looks fatal may not be in the path you care about.** `lib-imsvt.so` had 61
  unresolved symbols, which reads as hopeless -- but nothing links it and it is dlopened only on a
  code path we did not need. The library that actually gated startup needed one symbol. Check what
  is in the load path before costing the work.
- **Separate "removed subsystem" from "moved library".** Of those 61, most were `Rcc*` symbols from
  a vendor library we had simply forgotten to extract. The remainder were `IOMXObserver` and
  `IGraphicBufferAlloc` -- platform APIs deleted outright. The first is a one-line fix, the second
  is unfixable, and the counts alone do not distinguish them.
- **An empty report does not mean the blob works.** See the script header: nanopb kept every symbol
  name across a version bump and changed what the bytes behind them meant.

The trap worth repeating, because the script exists and still got it wrong once: **`comm` on
unsorted input silently lies.** Sort both sides, with `LC_ALL=C`, and sanity-check any scan against
a case whose answer you already know before believing a clean result.

## Get a reference before you theorise

Park the old branch on the inactive slot and boot it. Same phone, same blob, one variable changed.

```
tools/ota-extract.sh lineage-22.2-....zip /path/scratch --flash a --os-only
fastboot set_active a && fastboot reboot
```

`/data` is shared between slots, so anything you enable there — rooted debugging, `persist.*`
properties — carries across both ROMs. Switch back with `fastboot set_active b`. Keep the rig:
you will want to re-measure on the working side several times.

**Boot the old branch first, and expect the rig to expire.** The shared `/data` that carries your
debug setup across is also what ends the comparison: once the newer ROM has booted and initialised
user 0, the older one may no longer be able to. Going back then stops at
`Can't load Android system ... Reason: init_user0_failed`, and the only way through is a factory
reset — which wipes the `/data` both slots share, taking the working side's setup with it.
Measured on a Pixel 3a XL: lineage-22.2 on slot a booted fine as a reference, then refused after
24.0 had come up on slot b. So take every measurement you think you will want from the old branch
while you still can, and treat a late "let me just check the old one" as a request to rebuild the
whole rig.

If the old branch is *also* broken, stop. You are not looking at a regression and the rest of this
does not apply.

## Logs will lie to you by being identical

Turn logging up on both sides and diff them. For CamX that is
`persist.vendor.camera.log{Info,Verbose,Warning}Mask=0xFFFFFFFF` by `setprop`, or
`/vendor/etc/camera/camxoverridesettings.txt`. Other stacks have their own switch.

Expect this to fail to find anything, and know what that means. In the worked example every
message matched line for line — module count, probe results, calibration values — right up to the
fault. **That is a finding, not a dead end.** If two builds log the same thing and behave
differently, no state the blob prints is wrong, and the difference is in something it does not
print: a register, a struct size, a pointer.

Two traps while diffing:

- Addresses in log lines are ASLR, not data. "EEPROM rawData: 0x7 0faeb4f30" differing between runs
  means nothing.
- Capture from the moment adb appears, not `logcat -d` afterwards. A busy boot rotates the buffer
  and you will "discover" that early messages are missing on one side only.

## Then go to the registers

Attach and read the crash frame. `tools/blob-attach.sh` starts the binary under `lldb-server` and
prints the library load base, because lldb's gdbserver mode does not track shared libraries: no
symbolic breakpoint ever resolves, and bionic randomises the base regardless of
`kernel.randomize_va_space`. Absolute addresses are all you have and they move every run.

Symbols are usually still there even in a stripped blob, compressed in `.gnu_debugdata`:

```
llvm-objcopy --dump-section .gnu_debugdata=dbg.xz <blob> /dev/null && xz -d dbg.xz
llvm-nm -C dbg | grep <address>
```

`target modules add <local copy>` also gets lldb to read them, which is how you turn a bare address
into `CamX::ImageSensorUtils::ReadSensorCalibration(...)`.

Disassemble once, to a file, and work from it:

```
llvm-objdump -d <blob> > blob.dis
```

## Walking frames by hand

lldb cannot recover callee-saved registers in outer frames without unwind info, so read them off
the stack. Take the prologue of the frame you care about:

```
stp x29, x30, [sp, #-0x60]!     ; sp -= 0x60
stp x24, x23, [sp, #0x30]       ; x24 at x29+0x30, x23 at +0x38
stp x20, x19, [sp, #0x50]       ; x20 at x29+0x50, x19 at +0x58
mov x29, sp
```

then walk the frame pointer chain: `[x29]` is the caller's `x29`, `[x29+8]` its return address.
Confirm each hop by checking the return address lands where you expect
(`lr - load_base` = a file offset you can look up in `blob.dis`). Read the saved register out of
the frame you reached.

`memory read` refuses over 1024 bytes without `--force`.

## Bisect the call that breaks it

If a value is right on entry to a function and wrong later, and the function never reassigns it —
check that, with `grep` over the disassembly of the whole function — then a callee is clobbering a
callee-saved register. Find which one by setting a breakpoint on every `bl` in the range and
reading the register at each stop:

```
awk '/^  <start>:/{f=1} f&&/^  <end>:/{exit} f' blob.dis | grep '	bl	' | awk '{print $1}'
```

Breakpoints that never fire are information too: they tell you which branch was taken.

Then put a **watchpoint** on the saved stack slot and let it name the culprit outright:

```
breakpoint set -a <base + function entry>
continue
watchpoint set expression -s 8 -- $sp-0x10     # the slot the prologue saves the register into
continue                                        # hit 1 is the legitimate save
continue                                        # hit 2 is whoever corrupts it
register read pc ; memory region $pc
```

`memory region` prints the mapped file, so the second hit names the offending library directly.

## Do not restart a HAL to pick up a property

Testing a vendor property looks like it should be cheap -- `setprop`, restart the HAL that reads it,
try again -- and for a display or media HAL it is not. `ctl.restart vendor.hwcomposer-2-2` takes
SurfaceFlinger down with it, SurfaceFlinger takes zygote, and on a device whose display stack is
already the thing you are debugging the framework may not come back: it sits in the boot animation
with `init.svc.bootanim` still `running` while `sys.boot_completed` reads 1 from before the restart.
Measured twice on a Pixel 3a XL, and once it went further and rebooted the device outright --
`init: critical process 'zygote' exited 4 times in 10 minutes` -> `reboot: Restarting system with
command 'zygote-fatal'`.

So a property test costs a build and a flash. That is ~35 minutes against a wedged phone and a
reboot, and the reboot does not even give you the measurement.

Two things make that bearable. Get a REPRODUCIBLE TRIGGER from whoever is holding the device before
spending a build -- "it happens when I apply a colour scheme" turns a soak into a single action, and
it is the difference between one build answering the question and five not answering it. And check
the error counter as well as the symptom: a fix that stops the visible failure while the underlying
error still climbs in `dmesg` is a fix that has hidden the bug rather than removed it.

## The bug class this keeps finding

**A prebuilt blob that stack-allocates a platform C++ type is an ABI landmine.** The blob reserved
stack for that type as it was when the blob was compiled. Any platform upgrade that grows the type
overruns the reservation and corrupts whatever is next on the stack — usually the register save
area, so the symptom appears in an unrelated function later, with no log and no bad data anywhere.

The worked example: tinyxml2 11.0.0 changed `DynArray`/`MemPoolT` size fields from `int` to
`size_t`, which grew every embedded `DynArray` by 8 bytes and with it `sizeof(XMLDocument)`. A
camera HAL parsing a calibration XML into a stack `XMLDocument` overran it and cleared the saved
`x20`, which the *caller* was holding a pointer in. Two frames later that pointer was null.

Suspect this whenever a blob works on release N and faults on N+1 with identical inputs. Confirm
it cheaply before rebuilding anything: bind-mount the old library over the new one on a running
device and see if the crash goes away.

```
adb push old/libfoo.so /data/local/tmp/
adb shell mount --bind /data/local/tmp/libfoo.so /vendor/lib64/libfoo.so
```

Fix by pinning the vendor copy to the old ABI. A whole-tree revert of the upgrade is the expedient
version; the upstreamable one is a vendor variant built from the old source, leaving the platform
on the new one.

## A property its reader cannot see is a silent no-op

Setting a property and getting no behaviour change has three possible causes, and people usually
only check the first two:

1. the value is wrong
2. nothing reads it
3. **the thing that reads it is not allowed to**

(3) produces no error, no log line, and no clue. The property reads back correctly with `getprop`
from your root shell, because *you* are allowed to read it. The daemon that matters is not.

It happens because `property_contexts` is prefix-matched and anything unmatched falls through to
`default_prop`, which plenty of vendor domains are refused:

    $ getprop -Z persist.cne.feature
    u:object_r:default_prop:s0
    $ dmesg | grep 'avc: denied.*cnd'
    avc: denied { read } comm="cnd" tcontext=u:object_r:default_prop:s0

`persist.cne.feature=1` was set for the entire life of that port and the Connectivity Engine never
saw its own master switch. Everything downstream then behaved *correctly* for a daemon whose feature
flag is off, which is what makes this expensive: there is no misbehaviour to chase, only an absence.

`tools/prop-effect.sh <property>` answers all three questions at once — value, label, every binary
in the image that references it, and any denial on that type.

Two rules that follow:

- **Give the prefix its own type; do not widen `default_prop`.** Granting a domain `default_prop`
  hands it read access to every unlabelled property on the system.
- **Relabelling takes access away as well as granting it.** Moving `persist.cne.*` to a new type
  fixed `cnd` and broke the framework-side service that read the same names through `default_prop`,
  which showed up as a fresh denial on the next boot. Before relabelling, list *every* domain that
  can currently read the property, not just the one you are fixing.

## Find out who reads a property before you set it

A property in stock's `build.prop` is not evidence that anything in *your* image consumes it. Two
were copied across on one port; one was real and one was furniture:

    $ strings -a vendor/bin/netmgrd | grep '^persist\.'
    persist.data.iwlan.enable          <- real, netmgrd and qmuxd both read it
    ...
    $ grep -rl persist.radio.app_hw_mbn_path system/ vendor/
    (nothing)                          <- furniture; and stock's value pointed at a path that
                                          did not exist on this device either

The same `strings` pass hands you the neighbouring names, and the real switch is usually among them:
searching for `persist.data.iwlan.enable` also turned up `persist.data.iwlan.ims.enable`,
`persist.vendor.cnd.iwlan` and `persist.vendor.cnd.wqe`, none of which were in stock's `build.prop`
at all.

## Silence from a daemon is not evidence that it is idle

Some QTI daemons do not log to logcat. CNE logs through `CneLogDiagAdditional::printLog`, i.e. to
diag/QXDM, so `logcat | grep cnd` is empty no matter what it is doing. Check for a diag logging
class in the blob before concluding a daemon is asleep:

    strings -a vendor/lib64/lib<x>.so | grep -iE 'LogDiag|printLog|QXDM'

The giveaway that this is expected rather than broken: stock sets a QXDM logging property for it
(`persist.cne.logging.qxdm=3974`).

## The process name is not the package name

`ps -A | grep cne` finds nothing on a device where CNEService is running perfectly well, because it
is hosted in a process called `.dataservices`. Concluding "the service is dead" from `ps` sent one
investigation down a blind alley. Ask the framework instead:

    dumpsys activity processes | grep -B6 'class=com.quicinc.cne'
    *PERS* UID 1000 ProcessRecord{...:.dataservices}
      class=com.quicinc.cne.CNEService.CNEServiceApp

## A permissive restart is not a permissive boot

`setenforce 0` followed by restarting the daemon tests almost nothing if the daemon reads its
configuration once, at boot. The experiment is a permissive *boot*. Restarting CNE under
`setenforce 0` produced no change and briefly looked like evidence that sepolicy was not the
problem; it was, and the fix was worth a build.

## Sweep property *sets* separately from property *reads*

They are different audit classes and they give you different information, and the one that is easier
to read is the one people forget to look for.

A read denial (`tclass=file`, tcontext `*_prop`) names the domain and the type and **never the
property**, which is why it needs `prop-denials.sh` to resolve.

A set denial (`tclass=property_service`) names the property outright:

    avc: denied { set } for property=persist.audio.calfile0 pid=330
         scontext=u:r:vendor_init:s0 tcontext=u:object_r:audio_prop:s0

That one line was seven silently-unset ACDB calibration paths on a port -- the device's own speaker,
handset, headset and Bluetooth audio calibration, set by its `init.qcom.rc` and refused, so the
audio HAL had been running on generic tuning since the port began. Nobody had reported it as a bug,
because audio worked; it just did not sound like the device.

The cause is a type that AOSP retired: `vendor_init` used to be granted `exported_audio_prop`, that
type was folded back into `audio_prop`, and a vendor rc written against the old world quietly stops
working. Expect a crop of these whenever a port crosses a release boundary.

So sweep for both, and note that a set denial is worth more per line:

    logcat -b all -d | grep 'avc: *denied' | grep property_service   # names the property
    logcat -b all -d | grep 'avc: *denied' | grep '_prop:'           # needs resolving

And sweep for the classes that are neither, which on a mature port is a short and revealing list --
`tclass=dir`, `tclass=sysfs`, anything that is not a property at all.
