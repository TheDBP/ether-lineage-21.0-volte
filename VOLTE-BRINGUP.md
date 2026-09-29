# VoLTE bringup on the Nextbit Robin

How a 2016 phone whose IMS stack shipped for Android 7.1.1 ended up placing VoLTE calls on
Android 13, what each piece does, and — at least as usefully — every wrong turn on the way.

Status as of 2026-09-24: **VoLTE works, outgoing and incoming, with two-way audio on both and the
HD indicator.** Calls end with `CODE_USER_TERMINATED` and a `REMOTE`/`LOCAL` disconnect cause, i.e.
somebody hung up, rather than an error. Wi-Fi calling is available at the platform level but its
registration is untested. Video calling is deliberately off and cannot be revived.

`VOLTE.md` is the chronological working log this is distilled from; it has the raw measurements.
The generic, device-independent lessons live in `forge/docs/debugging-volte.md`.

---

## 1. Why any of this is necessary

The Robin's IMS stack is proprietary QTI userspace built for Android 7.1.1. Two things about it
matter:

**The framework API it targets no longer exists.** In 7.1 an IMS implementation was an app exposing
`com.android.ims.internal.IImsService` over Binder, and `com.android.ims.*` was part of the *boot
classpath*. Android 9 deleted that API and replaced it with `android.telephony.ims.ImsService`.
There is no version of Android 13 that can talk to a 7.1 IMS app directly.

**The blobs are compiled against a 2016 platform ABI.** They import symbols that changed meaning,
changed signature, or were deleted outright. Nothing warns you: the library loads, or it loads and
misbehaves, or it fails on a symbol you have never heard of.

So there are two independent problems — an API gap and an ABI gap — and they fail in completely
different ways. Most of the time lost on this port was spent mistaking one for the other.

---

## 2. Architecture

```
  Android 13 telephony  (ImsPhone, ImsPhoneCallTracker, ImsResolver)
            |
            |  android.telephony.ims.*  (modern ImsService API)
            v
  ImsServiceControllerCompat + MmTelFeatureCompatAdapter      <- AOSP's own pre-P compat layer
            |
            |  android.telephony.ims.compat.*                    (still in AOSP, unused elsewhere)
            v
  ImsBridge            (device/nextbit/ether/ims-bridge)       <- ours
            |
            |  org.codeaurora.ims.legacy.internal.IImsService    (the 7.1 Binder interface,
            v                                                     regenerated from the binary)
  ims.apk              (stock, deodexed and package-renamed)
            |
            |  protobuf over a local socket
            v
  rild / libril-qc-qmi-1.so  -> modem
```

AOSP still ships a compatibility layer for pre-P IMS implementations
(`android.telephony.ims.compat`). It is unused by any current device, but it is complete, and it is
what makes this possible at all: we only had to bridge from *its* interface down to the 7.1 app,
not reimplement the modern ImsService API.

---

## 3. The pieces

### 3.1 `ims.apk` — deodexed and renamed

Stock ships a 27 KB manifest plus an arm64 `.odex` compiled against the 7.1 boot image. It has to be
deodexed before it can run, and then renamed, because it references `com.android.ims.*` — classes
Android 9 deleted from the boot classpath.

`deodex-app.sh` extracts the apk and odex, pulls the arm64 boot classpath out of the stock image,
deodexes, and hard-fails on leftover quick opcodes or unresolved references. It also recovers 22
legacy types that live only in the boot image, not in the apk:
`boot-ims-common.oat` and `boot-framework.oat//system/framework/framework.jar:classes2.dex`.

> **Trap:** `baksmali x` disassembles only the *first* dex of a multi-dex oat. Address later ones
> explicitly as `<oat>//system/framework/framework.jar:classes2.dex` or you will silently get a
> fraction of the classes.

`rebuild-app.sh` then rewrites `com.android.ims` to `org.codeaurora.ims.legacy` — 1589 references in
the app, 6969 in the recovered framework classes, 373 descriptor strings. Broadcast action strings
such as `com.android.ims.IMS_SERVICE_UP` are deliberately **not** renamed: they are wire contracts
with other components, not class names.

Every rewrite in that script asserts its own expected count and fails the build if reality disagrees.
That is not defensive styling; several of them were wrong on the first attempt and the assertion is
what caught it.

### 3.2 The legacy AIDL surface

The bridge has to speak the exact Binder protocol `ims.apk` expects: right transaction codes, right
interface descriptors, right parameter order. Guessing is not viable.

`gen-legacy-aidl.py` generates all 14 interfaces from the stock binary's own `TRANSACTION_*`
constants and method descriptors. `verify-legacy-aidl.sh` then checks the **built** apk's transaction
codes and descriptors against the stock binary — 14 interfaces, 148 transactions, all matching. It
was negative-tested by corrupting one code and confirming it exits non-zero.

### 3.3 `ImsBridge`

`device/nextbit/ether/ims-bridge` implements the pre-P `MMTelFeature` and forwards to the legacy
service. Notable details:

- `sharedUserId="android.uid.phone"`, platform-signed, privileged.
- It declares **no** privileged permissions. Adding them without a `privapp-permissions` allowlist
  entry crash-loops `system_server` at `systemReady`; `android.uid.phone` already grants what is
  needed.
- `LegacyMMTelFeature` reports `STATE_READY` only after `ServiceManager.waitForService("ims")`
  returns, because the framework will not call `startSession` on a feature that is not ready.
- `getVideoCallProvider` returns null — video is not bridged.

### 3.4 nanopb 0.2.8

`ims.apk` talks to `rild` in protobuf. `libril-qc-qmi-1.so` does not carry its own nanopb; it
*imports* `pb_encode`/`pb_decode` from `libril`. Android 13's libril has nanopb 0.3.x, and 0.3.x
inserted `PB_LTYPE_BOOL = 0x00`, shifting every other `PB_LTYPE_*` up by one. A 0.3.x runtime reads a
0.2.8 descriptor as the *next type along*: `VARINT` becomes `STRING`, `STRING` becomes `SUBMESSAGE`,
and the decoder chases a pointer that is really an integer.

Two changes fix it:

- `hardware/ril` patch 0001 gives libril a version script (`local: pb_*;`) so it stops exporting
  nanopb, while keeping 0.3.x for libril's own SAP descriptors.
- `device/nextbit/ether/nanopb-0.2.8/` builds `libnanopb_legacy` from `external/nanopb-c` at tag
  `android-7.1.1_r1`, bound to the blob via `TARGET_LD_SHIM_LIBS`.

> **This was misdiagnosed twice.** It is *not* a `PB_FIELD_8/16/32BIT` width problem — all three
> widths fail identically, and 32-bit additionally segfaults, which made it look like one. The
> symbol names are unchanged across the version bump, so a symbol-level check reports nothing wrong.

### 3.5 CNE

The Qualcomm Connectivity Engine (`cnd` plus `CNEService.apk`) was disabled during the initial port.
IMS needs it. Patches 0001 and 0002 were edited to restore the `cnd` service and the
`com.quicinc.cne.api` / `.server` HAL manifest entries. `com.qualcomm.qti.dpm.api` stays removed.

### 3.6 The Surface shim

`ImsVideoGlobals.init()` dlopens the VT natives, and `libimsmedia_jni.so` imports
`android::Surface::Surface(sp<IGraphicBufferProducer> const&, bool)` — a constructor Android 13
replaced with a three-argument form. The symbol resolves nowhere, `ImsMedia.<clinit>` throws
`UnsatisfiedLinkError`, and the whole IMS service dies at `ImsService.onCreate`.

`libshims/vtsurface_shim.cpp` supplies the old mangled name and placement-constructs the modern one.

That alone would be a heap-corruption bug. The blob does `new Surface(...)` with `sizeof(Surface)`
baked into the instruction stream at compile time — **3560 bytes in 2016, 8168 today**, measured at
six independent `new Surface` call sites in the platform's own `libandroid_runtime.so`. So
`extract-ims-blobs.sh` also rewrites the blob's allocation: one `MOVZ x0, #3560` becomes
`MOVZ x0, #8168`. It searches for the instruction encoding rather than a fixed offset, asserts
exactly one occurrence, and is idempotent.

Why bother, when video does not work anyway? Because `init()` creates singletons the *voice* path
uses. Without it, `CameraController` and `LowBatteryHandler` are null, and six separate call sites
throw `RuntimeException: ... Not initialized` — one of which kills `com.android.phone` on every
call. Four of those were patched out individually before it became obvious that fixing `init()`
fixes the class.

---

## 4. The failure that defined the port

For several days the symptom was: IMS capabilities negotiated, `MmTel Capabilities - [Voice: true]`,
`UNSOL_VOPS_CHANGED`, `STATUS_ENABLED` — and yet every call fell back to circuit-switched and failed
with `DIAL error 46 / INVALID_MODEM_STATE`. No `onImsConnected`. The obvious reading was that our
bridge's registration listener was broken.

It was not. Decoding the raw frames the IMS app exchanges with the modem settled it in minutes:

```
UNSOL_RESPONSE_IMS_NETWORK_STATE_CHANGED (id 204), payload:
  08 02        field1 state     = 2  -> NOT_REGISTERED
  15 00000000  field2 errorCode = 0  (fixed32, correct wire type)
  20 0E        field4 radioTech = 14 (LTE)
```

Well-formed protobuf, correct wire types, no error. The listener was faithfully relaying
"not registered". **The modem had never been asked to register.**

Walking back: the framework only asks the vendor stack to enable a capability it believes the
platform supports. `ImsManager.isVolteEnabledByPlatform()` is

```java
config_device_volte_available   AND   carrier_volte_available_bool
```

The carrier leg was fine (`mConfigFromDefaultApp` had it true). The device leg was **false**,
because the resource was in `overlay/.../values-mcc310-mnc260/` and:

```
gsm.sim.operator.numeric   310240   <- Mint, and this is what picks the resource qualifier
gsm.operator.numeric       310260   <- T-Mobile, and this picks nothing
```

**Android takes resource mcc/mnc qualifiers from the SIM, not the serving network.** An MVNO on a
host network reports its own MCC/MNC on the SIM. The overlay never applied, the resource fell back to
AOSP's `false`, and one boolean suppressed VoLTE, VT and Wi-Fi calling together.

It was also a regression of our own making: patch 0004 had replaced a working global
`persist.dbg.volte_avail_ovr=1` with that MNC-scoped overlay. The log line
`qcril_qmi_imsa_is_ims_registered_for_voip_vt_service` read `1` before the swap and `0` after.

Fixed in patch 0026 by adding `values-mcc310-mnc240`.

---

## 5. Everything else that failed, and what it taught

**`readParcelable(null)` after the rename.** `createCallSession` died with
`ClassNotFoundException: org.codeaurora.ims.legacy.ImsStreamMediaProfile`. A null loader makes
`Parcel` fall back to the *boot* classloader. On 7.1 these were `com.android.ims.*` framework
classes and that worked. Renaming moved them into the app, invisible to the boot loader.
→ **A class that moves off the boot classpath breaks every `readParcelable(null)`, `readBundle()`
and `readSerializable()` that used to resolve it.** Grep for those before blaming the transport.

**Four singletons, one cause.** `openForSub`'s `getInstance()`, `maybeCreateVideoProvider`'s
`CameraController`, `maybeUpdateLowBatteryStatus`'s and `canDial`'s `LowBatteryHandler` — all
because `ImsVideoGlobals.init()` had been deleted. Each was patched individually, each cost a build
cycle. The fifth occurrence is what finally justified the shim.
→ **When the same root cause surfaces three times, stop patching call sites.**

**Exceptions vanish across Binder.** `JavaBinder: *** Uncaught remote exception! (Exceptions are not
yet supported across processes.)` means a callee threw and the caller saw success — or, here, a null
session and no explanation. Several of the above presented as "the bridge returned null".

**Reading the wrong registration signal.** `RILJ: IMS_REGISTRATION_STATE {1,1}` said registered while
the MMTel side logged `registrationDisconnected` four times in the same session. The legacy RIL query
and the `ImsQmiIF.Registration` unsol are different signals and they disagree. The one the call path
follows is the unsol.

**The incoming-call path deadlocks the main thread, and it is the compat layer's fault.**
`ImsPhoneCallTracker.onIncomingCall` defaults to `executeAndWait()`, which is
`CompletableFuture.runAsync(task, mExecutor).join()`, and the production constructor injects
`phone.getContext().getMainExecutor()`. A modern ImsService calls `onIncomingCall` on a **binder**
thread, where blocking costs nothing -- hence the property name
`ro.telephony.block_binder_thread_on_incoming_calls`. The pre-P compat layer instead delivers it
from `MmTelFeatureCompatAdapter`'s `ACTION_IMS_INCOMING_CALL` broadcast receiver, which runs on the
**main** thread, so `join()` waits for a task only the waiting thread can run.

Everything else is downstream, and none of it looks like the cause. `PhoneInterfaceManager.sendRequest`
posts to the main thread and waits with no timeout, so *every* unrelated telephony call hangs: that
is why Settings ANRed on `isVoNrEnabled`, and why binder threads pile up on `MainThreadRequest`
monitors. Eventually `TelephonyConnectionService` cannot execute, the phone process is killed for
ANR, and the next call fails with `Phone is null, OUT_OF_SERVICE` -- with IMS never re-registering.
Set the property false (device patch 0029). AOSP's else-branch comment names the case exactly: "for
legacy IMS we want to avoid blocking the binder thread".
**`sys.ims.*` is typed `qcom_ims_prop`** and unreadable from a shell without root. Empty is not the
same as unset.

**`apply-overlay.sh` regenerates `vendor/extra/product.mk` from the enabled option set.** Run without
the option environment it writes that file empty and silently drops every option, producing a ROM
with stock sounds and no re-skin. Always go through `bootstrap.sh`.

**Editing a patch file does not change the build tree.** The tree is rebuilt from `BASE_REF` plus
patches at bootstrap; verifying a change in a scratch replay proves nothing about the build that just
ran.

---

## 6. Verifying it

In rough order of usefulness:

```sh
# 1. Did the framework ask for voice at all? cap 0 == FEATURE_TYPE_VOICE_OVER_LTE.
adb logcat -d | grep 'changeEnabledCapabilities'
#    cap: 0 radioTech: 13 enabled        <- what you want
#    cap: 4 radioTech: 13 enabled        <- UT only: the platform gate is shut, see section 4

# 2. What does the modem actually say? Decode the frame, do not trust the summary.
adb logcat -d | grep -A1 'UNSOL_RESPONSE_IMS_NETWORK_STATE_CHANGED'
#    payload 08 01 = REGISTERED, 08 02 = NOT_REGISTERED, 08 03 = REGISTERING

# 3. Framework's view.
adb logcat -d | grep -E 'setImsRegistrationState|isVolteEnabled='

# 4. Both legs of the availability gate.
adb shell dumpsys carrier_config | awk '/mConfigFromDefaultApp/{f=1} f' | grep volte_available
adb shell getprop gsm.sim.operator.numeric    # the SIM picks the resource qualifier
adb shell getprop gsm.operator.numeric        # the network does not
```

Frame format, for hand-decoding: one length byte, then a `MsgTag` (field 1 fixed32 token, 2 varint
type, 3 varint message id, 4 varint error), then the payload. **The length byte covers the tag only.**
For `Registration` (id 204): field 1 `state` varint, field 2 `errorCode` **fixed32**, field 3
`errorMessage`, field 4 `radioTech`.

`forge/tools/abi-gap.sh <blob>` lists symbols a blob imports that the platform no longer exports.
Note what it cannot tell you: a symbol that still resolves can have changed meaning (nanopb), and a
type that still exists can have grown (`Surface`).

---

## 7. Reproducing the build

Everything is staged from the stock ROM at product-config time; there is no remembered command.

```sh
EXTRA_OPTIONS="bringup oem" PRESET=clean ./forge/bootstrap.sh
```

`device.mk` stages `vendor/ims-blobs` on first build if it is absent, running `extract-ims-blobs.sh`,
which in turn runs `deodex-app.sh` and `rebuild-app.sh` and applies the Surface allocation rewrite.
The include of `ims-blobs.mk` is deliberately hard, not `-include`: a ROM whose VoLTE is quietly
absent is exactly the failure the staging exists to prevent. To force re-staging, delete
`vendor/ims-blobs`.

Relevant patches:

| patch | what |
|---|---|
| device 0018 | IMS daemons, JNI symlinks, sepolicy |
| device 0019–0022 | ImsBridge, legacy AIDL, the sub-interfaces |
| device 0023 | stage the IMS blobs from the build |
| device 0025 | nanopb 0.2.8 |
| device 0026 | **`config_device_volte_available` under the SIM's MNC** |
| device 0027 | Surface shim; video calling off |
| device 0029 | **`block_binder_thread_on_incoming_calls=false`** -- without it, incoming calls deadlock `com.android.phone` |
| `hardware/ril` 0001 | stop libril exporting nanopb |
| `vendor/apn` 0001 | the missing IMS APN for 310240 |

---

## 8. What is still open

**Wi-Fi calling.** Not working. The platform gate is open — the toggle appears, and both
`carrier_wfc_ims_available_bool` and `config_device_wfc_ims_available` are true — and the call path
goes through the same bridge, so it should work once registration does. What was wrong underneath,
in the order it was found:

*The modem is not the blocker.* `strings` over `/firmware/image/modem.b*` gives `IWLAN S2B IFACE
1..16`, an IMS RAT-change handler that knows about IWLAN, and S2b NV item paths. The carrier config
in the same image carries `epdg_fqdn:ss.epdg.epc.mnc260.mcc310…` with `IWLAN` in its
`Supported_RAT_Priority_List`. The capability was compiled in and left switched off; Wi-Fi calling
was never a shipped feature on this device.

*CNE could not read its own configuration.* Every `persist.cne.*` name fell through to
`default_prop`, which `cnd` is refused, so `persist.cne.feature=1` was set and never seen. The
visible consequence was one layer up, in the RIL: `pref data tech UNKNOWN` with a candidate list of
CDMA/EVDO/GSM/LTE and no IWLAN. Device patch 0031 gives those prefixes their own type; the measured
result was `pref data tech` becoming `LTE`. IWLAN still did not appear.

*The modem accepts the switch and declines to act.* Tested 2026-09-24 on the flashed build. Every
AP-side link in the chain was verified in a single boot, in this order:

    FeatureConnector     connection ready -> onMmTelAvailable            (~17s, every boot)
    ImsProvisioning...   setInitialProvisioningKeys (voice, iwlan) true
    MmTelFeatureCompat   changeEnabledCapabilities cap: 2 radioTech: 18 enabled
    RIL                  set_ims_srv_status: Sending wifi call setting through set_service, value: 1
    RIL                  CLIENT_PROVISIONING_WIFI_CALL_PREFERENCE mode 2 -> ims wifi mode 1, success

The modem echoes `wifi_call: 2` (on) and then does nothing. `tcpdump -i wlan0`, across a full boot with
Wi-Fi associated from 15s and across a `cmd phone ims disable/enable` cycle, captures no DNS for the
ePDG FQDN, no IKE on UDP 500/4500 and no ESP. Its IMSA status indication reads `VOIP: service_status 2,
rat 1` — it has the RAT field and only ever names WWAN.

Two items read back wrong, and that is where this now stands:

    client_prov_enabled: 0        never 1
    wifi_call_preference: 0       mode 1 was set, "response success", reads back 0

`client_prov_enabled: 0` means the modem provisions itself from NV instead of accepting the AP's
provisioning. That matches the behaviour exactly: the setting is stored, the preference is discarded,
no tunnel is attempted.

*Patch 0035 works; legacy item 28 is a dead end.* `ims.mmtel_requires_provisioning_bundle` lands
(`isImsProvisioningRequiredForCapability capability 1 tech 1 return value true`), so
`setInitialProvisioningKeys` does now push the key — and the vendor stack refuses it:

    ImsConfig            setConfig(): item = 28 value = 1
    QImsService          ImsConfigImpl : Invalid API request for item
    ImsConfigImplBase    Set provision value of 28 to 1 failed with error code 1

`setProvisionedValue` is the wrong API for VoWiFi on this build; item 28 is not in its accepted set. Do
not chase this by widening the bundle. The open question is which legacy item numbers this `ims.apk`
does accept, and whether any maps to the RIL's `ENABLE_VOWIFI` or to `client_prov_enabled`.
`ConfigWrapper` is our code, so probe from there rather than guessing.

*The modem's iWLAN code is complete. Its configuration is not, and the configuration is not the gate
either.* Diffed this modem against a Nexus 5X final radio -- same M8994F line, both MPSS.BO.2.6.x --
and the Robin carries *more* iWLAN, not less: 323 `iwlan` strings against 264, 68 `epdg` against 53,
19 `vowifi` against 1, plus the whole S2b subsystem (`iwlan_s2b_pdn_sm`, `iwlan_s2b_ikev2_hdlr`,
`iwlan_s2b_epdg_addr_resolver`). The modem has its own IKEv2 client and its own ePDG resolver.

Read its EFS directly with `forge/tools/diag-efs.sh`:

    /nv/item_files/ims/IMS_enable                         1
    /nv/item_files/ims/qipcall_domain_selection_enable    1
    /nv/item_files/data/wlan_config/wlan_offload_config   2      only item in that directory
    iwlan_s2b_mtu_val, wifi_oos_linger_timer,
    wait_for_LTE_attach_timer, wlan_proxy_setup_timer,
    data_wlan_acq_hyst_timer                              ENOENT

`wlan_offload_config` was written to 1, and to 3, rebooting each time. Neither changes anything:
handover config still answers `RIL_E_MODEM_ERR`, and a `tcpdump` on wlan0 sees no ePDG DNS, no IKE and
no ESP. Restored to 2.

Do not spend time on the other EFS items. `ims_operation_mode` (0x09) and the entire `qp_ims_*`
family -- including a `qp_ims_wifi_config` that is 256 bytes of zeroes and looks like exactly the
thing you want -- are **named nowhere in the modem image**. It references precisely two items under
`/nv/item_files/ims`, `IMS_enable` and `qipcall_domain_selection_enable`, and both are already 1.
The rest are leftovers from older firmware or from AP-side provisioning tools. Writing an item this
build never reads produces a convincing log and no effect.

*The EFS is already provisioned for iWLAN, and that is not the gate either.* Do not cross-flash the
modem partition to chase this. `/firmware` is one vfat holding the modem AND `adsp.*`, `qwlan30`,
`keymaster`, `widevine`, `cmnlib` -- `fastboot flash modem NON-HLOS.bin` takes out audio, Wi-Fi and
keymaster to change one thing, which is what the "unstable" reports amount to.

An MCFG is not firmware, it is a container of EFS item values, so it can be read and diffed instead
(`forge/tools/mcfg-items.py`). Against T-Mobile's own `mcfg_sw.mbn`, pulled from a Nexus 5X radio of
the same M8994F line, this device's EFS comes out equivalent or better:

    /data/iwlan_s2b_config.txt        identical -- same epdg_fqdn
                                      (ss.epdg.epc.mnc260.mcc310), same IKEv2 params -- except a
                                      missing natt_keepalive_wifi_offload:TRUE, and LF vs CRLF
    /data/pdn_policy_db.txt           already Supported_RAT_Priority_List:WWAN,IWLAN for the ims
                                      PDN, and IWLAN,WWAN for tmus
    /efsprofiles/imshandoverconfig    a SUPERSET of T-Mobile's; ours adds the media jitter and
                                      frame-loss thresholds
    modem/mmode/wifi_config           byte-identical
    wlan_config/wlan_offload_config   2 on both, so the earlier write experiment was always going
                                      to be a no-op
    ims/qp_ims_wifi_config            512 zero bytes in T-Mobile's MCFG too -- ours being zeroed is
                                      normal, not a defect
    wlan_config/iwlan_s2b_mtu_val     the only genuine absence (T-Mobile: 1280)

Both deltas were written and are still in place -- the natt line appended in this device's own LF
convention, and `iwlan_s2b_mtu_val` created as 1280. With Wi-Fi calling on and set to wifi-preferred
(`wfc_ims_enabled=1, wfc_ims_mode=2`), neither changes anything: handover config still answers
`RIL_E_MODEM_ERR`, and tcpdump on wlan0 sees no ePDG DNS, no IKE, no ESP.

So: every AP-side path is correct and delivered, every EFS item this firmware reads is set, and the
modem still never attempts a tunnel. What remains is inside the modem -- the S2b code is present, the
QMI surface that would configure it errors, and no WLAN RAT is ever reported. That is a build or
feature flag in the firmware, not something reachable from Android.

*The donor firmware experiment was run, and it closes the question.* A Nexus 5X `2.6.42` modem was
written onto a spare Robin -- only `modem.b*` and `modem.mdt`, leaving `adsp`, `qwlan30`, `keymaster`,
`widevine` and `cmnlib` in place, all 19 files verified byte-identical on the partition. It does not
fail authentication. It never gets that far:

    pil-q6v5-mss fc880000.qcom,mss: modem: Failed to allocate relocatable region of size 6400000
    init: Service 'modem_hold' exited with status 1          (retries, fails identically)

`0x6400000` is 100 MB. The reserved region is 90 MB and the carve-outs are packed:

    msm8992.dtsi  peripheral_mem  0x07400000 + 0x1c00000   ends exactly at 0x09000000
    msm8992.dtsi  modem_mem       0x09000000 + 0x5a00000   90 MB, ends 0x0EA00000

`peripheral_mem` ends precisely where `modem_mem` begins, so the region cannot grow downward, and
these physical addresses are coordinated with the bootloader and TZ, which program the MSS region
before Linux runs. Finding 10 MB means relocating fixed carve-outs that firmware below the kernel also
depends on -- and a modem that loaded would still have to authenticate against a QFPROM root, which
remains untested.

**Verified on hardware 2026-09-25:** with `config_device_wfc_ims_available` false the Wi-Fi calling
entry is absent from Settings entirely, and VoLTE is unaffected on the same handset -- SIM loaded,
IN_SERVICE, `changeEnabledCapabilities cap: 0 radioTech: 13 enabled`. Note that `dumpsys carrier_config`
is useless for checking this: it prints `carrier_wfc_ims_available_bool` more than once, from different
config layers, with different values. The device-capability resource has no adb read path, so the only
reliable check is whether the Settings entry is there.

**So Wi-Fi calling is not achievable on this device, and specifically not as something a ROM can
ship.** Everything above the modem is correct and does ship: the framework delivers the enable, and
the modem's EFS is provisioned for iWLAN as completely as a handset that sells the feature. The modem
itself will not attempt a tunnel, its own firmware generation is the reason, and a newer generation
does not fit in the memory the hardware reserves for it. Treat VoLTE as the win here and stop.

Two practical notes for anyone who repeats any of this. Do not `adb push` into `/firmware`: vfat has no
ownership, so push truncates the destination, writes, then fails `remote fchown failed` and cleans up,
destroying the original and leaving nothing -- it removed all 19 `modem.*` files in one command. Stage
to `/data/local/tmp` and `cp` on-device instead. And `fastboot flash modem <backup>.img` restored the
partition completely, twice, so a hash-verified backup of `modem`, `modemst1`, `modemst2`, `fsg`, `fsc`
and `persist` is a sufficient safety net.

Two EFS deltas are currently applied on the development handset and are inert: the
`natt_keepalive_wifi_offload:TRUE;` line appended to `/data/iwlan_s2b_config.txt`, and
`iwlan_s2b_mtu_val` created as 1280. Both are what T-Mobile's own MCFG carries. Revert by rewriting
the file without the final line and unlinking the item (`forge/tools/diag-efs.sh`).

*CNE is not the gate.* `libcne.so` carries the iWLAN preference itself (`CneFeatureCache::setIwlanUserPref`,
`"ePDG preference: %d"`) driven by `persist.vendor.cnd.iwlan`, which is already `true`. There is no HIDL
entry point for it, so nothing on the AOSP side is missing a call.

`persist.vendor.cnd.wqe` is deliberately left off. WQE is Wireless Quality Estimation: it actively
probes an ICD server to measure RTT and bitrate and reports a verdict to the modem. It is not a gate
for Wi-Fi calling, and with no probe server configured it may report the link as bad and suppress the
handover we are trying to get.

**Video calling will not work.** `lib-imsvt.so` imports `IOMXObserver` and `IGraphicBufferAlloc` —
platform interfaces deleted outright when OMX moved to HIDL/Codec2 — among 61 unresolved symbols.
Those are removed subsystems, not grown types, and are not shimmable. It is switched off at the
framework (`config_device_vt_available=false`) so nothing advertises a capability it cannot deliver.
The shim exists only so `init()` can create its singletons.

**`ims_rtp_daemon` never runs, and that is fine.** `sys.ims.DATA_DAEMON_STATUS` is never set, so the
daemon never starts — and audio works in both directions regardless. Voice media goes modem-to-DSP
without the AP-side daemon on this device. `imsdatadaemon` sits idle in `poll` with no client on
`/dev/socket/ims_datad`; that is not a fault. **Do not "fix" it.**
