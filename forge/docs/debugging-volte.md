# Debugging VoLTE on a ported device

For the case where the IMS stack is present and running but the modem never registers, so calls
fall back to circuit-switched and dialling fails with `INVALID_MODEM_STATE` (RIL error 46).

## Read the registration state off the wire before blaming your code

On a QTI device the IMS app logs every frame it exchanges with the modem. Decode one by hand; it
settles in a minute whether you are looking at a transport bug or an honest answer.

    ImsSenderRxr : Response data: [12, 13, -1, -1, -1, -1, 16, 3, 24, -52, 1, 32, 0, 8, 2, 21, 0, 0, 0, 0, 32, 14]
    ImsSenderRxr :  Tag -1 3 204 0

One length byte, then a `MsgTag` (field 1 fixed32 token, 2 varint type, 3 varint message id,
4 varint error), then the payload. **The length byte covers the tag only**, not the payload. For
`Registration` (message id 204): field 1 `state` varint — 1 REGISTERED, 2 NOT_REGISTERED,
3 REGISTERING — field 2 `errorCode` **fixed32**, field 3 `errorMessage`, field 4 `radioTech`.

Above: `08 02` is state 2, NOT_REGISTERED, with errorCode 0 — the modem was never asked to
register. A garbled frame looks different: wrong wire types for the field numbers, or fields the
generated parser skips as unknown. Field numbers and wire types that match the generated
`*_FIELD_NUMBER` constants mean the protobuf layer is fine.

## A capability that is never requested looks exactly like one that is refused

Before the modem will register, the framework has to ask for voice. Watch for:

    MmTelFeatureCompat: changeEnabledCapabilities - cap: 0 radioTech: 13 enabled

`cap` is the legacy `ImsConfig` feature: **0 = VOICE_OVER_LTE**, 1 VOICE_OVER_WIFI, 2 VIDEO_OVER_LTE,
3 VIDEO_OVER_WIFI, 4 UT_OVER_LTE, 5 UT_OVER_WIFI, **-1 = unmapped**. If you only ever see cap 4 and
cap -1, the framework never asked for voice and the modem is behaving correctly. Fix the framework
side; nothing below it is broken.

## The gate is an AND, and both legs are easy to get wrong

`ImsManager.isVolteEnabledByPlatform()`:

    config_device_volte_available   (device resource)  AND  carrier_volte_available_bool  (carrier config)

- Read the carrier leg from `dumpsys carrier_config` under **`mConfigFromDefaultApp`**. The first
  block printed is `Default Values from CarrierConfigManager`, where every IMS key is false by
  definition. Reading that block is how you talk yourself into blaming the carrier.
- The device leg is a normal resource, so it obeys resource qualifiers.

`persist.dbg.volte_avail_ovr=1` is read *ahead of both legs* and returns true immediately. Use it to
prove the gate is what is stopping you, in one reboot and no build. Do not ship it — it forces VoLTE
on for every carrier — and **clear it before validating the real fix**, or you will test nothing.
The siblings are `persist.dbg.vt_avail_ovr` and `persist.dbg.wfc_avail_ovr`.

## Resource mcc/mnc qualifiers come from the SIM, not the serving network

An MVNO on a host network reports its own MCC/MNC on the SIM while the network reports the host's:

    gsm.sim.operator.numeric  310240   <- picks values-mcc310-mnc240, and nothing else
    gsm.operator.numeric      310260   <- picks nothing

So `overlay/.../values-mcc310-mnc<host>/config.xml` silently does not apply, the resource falls back
to its AOSP default, and every symptom appears far downstream in the IMS stack. Check both
properties before writing an mcc/mnc overlay, and add one directory per SIM you intend to support.
The same applies to `mcc`/`mnc` filters in a `CarrierConfig` `vendor.xml`.

## Symptoms that are downstream, not separate bugs

Do not chase these until registration succeeds — they clear on their own when it does:

- `sys.ims.DATA_DAEMON_STATUS` unset and `imsdatadaemon` never starting.
- The registration listener delivering only `registrationDisconnected`, and MmTel capabilities
  flicking `Voice: true` then immediately back to false.
- `ims_rtp_daemon` not running. It starts for a call, not at boot.

Note also that `sys.ims.*` is typed `qcom_ims_prop` and is unreadable from a shell, so an empty
`getprop` is not evidence that it is unset.

## A pre-answer hangup is not a "start failure", and 17 will not unwind it for you

A 7.0-era OEM stack reports the remote hanging up on a call that was never answered as
`callSessionStartFailed` — in its model the session never started. Forward that verbatim and an
unanswered incoming call rings until the handset is rebooted.

`ImsPhoneCallTracker.onCallStartFailed` unwinds `mPendingMO` and nothing else (plus a `findConnection`
branch gated on `DomainSelectionResolver.isDomainSelectionSupported()`, off on devices this old).
`mPendingMO` is null for an incoming call, so the handler runs to completion having disconnected
nothing. Telecom's `CallAnomalyWatchdog` notices after two minutes and logs "caught and disconnected
a stuck/zombie call" — and the call survives that too, as it survives `KEYCODE_ENDCALL`, because
there is no live session underneath for a hangup to act on. Meanwhile Telecom refuses to dial
("Cannot place a call as there is an unanswered incoming call"), so the symptom people report is
broken outgoing calls.

- The one-line signature: `ImsPhoneCallTracker: onCallStartFailed reasonCode=510`
  (`CODE_USER_TERMINATED_BY_REMOTE`) on a call that is *ringing* rather than dialling. A correct
  teardown reads `onCallTerminated`. The OEM layer usually logs the truth immediately above it.
- The fix is in the bridge, not the framework: deliver MT sessions as `callSessionTerminated` and
  leave MO on `callSessionStartFailed`, which is what drives the CSFB retry path. `templates/
  ims-bridge` carries it — `CallSessionWrapper` takes an `incoming` flag, set only on the
  `getPendingCallSession` path, since that is the only way an MT session arrives.

Generalises past this callback: when an OEM stack's vocabulary predates the modern stack's, check
what the modern handler *does* with each callback, not just that a callback of that name exists.
A faithful forward of a term whose meaning has narrowed is a silent no-op.

## Wi-Fi calling: find out what the modem is being told, not what the framework thinks

VoWiFi fails differently from VoLTE. The framework side can be completely healthy --

    ImsManager: updateWfcFeatureAndProvisionedValues: available=true, enabled=true,
                mode=1, provisioned=true, isFeatureOn=true
    RILQ: Set config CLIENT PROVISIONING wifi_call_preference to: 3

-- and the modem still never attempts an ePDG tunnel, because on a modem-based IWLAN device the
modem does not go looking for Wi-Fi. It has no Wi-Fi radio. Something on the AP has to tell it that
a WLAN exists, and until that happens every layer above is behaving correctly with nothing to act
on.

**Establish first whether the capability is even present**, because it decides whether this is worth
any time at all. It lives in the modem image, not in your tree:

    strings -a /firmware/image/modem.b* | grep -iE 'epdg|iwlan|s2b'
      IWLAN S2B IFACE 1 ... IWLAN S2B IFACE 16
      IMSSupplementaryService.cpp:HandleRATTechnologyChange: IWLAN/WLAN/LTE RAT found
      /nv/item_files/data/wlan_config/iwlan_s2b_mtu_val

S2b is the 3GPP interface for untrusted WLAN to an ePDG; that is modem code, not configuration. The
carrier side sits next to it, and note the `mdm/` in the path — a stock `build.prop` on one device
pointed at the same tree *without* it, at a directory that does not exist:

    /firmware/image/mdm/modem_pr/mcfg/configs/mcfg_sw/generic/na/<carrier>/*/mcfg_sw.mbn
      epdg_fqdn:ss.epdg.epc.mnc<mnc>.mcc<mcc>.pub.3gppnetwork.org;
      Supported_RAT_Priority_List:WWAN,IWLAN;

Do not read a carrier directory in `mcfg_sw/generic/na/` as proof the hardware supports that
carrier. Qualcomm ships them wholesale; a `verizon` directory appears on GSM-only devices.

**Then find where the chain stops.** The signal is DSD (Data System Determination): the modem
reports which data systems are available, and the RIL reads WLAN out of that report.

    RILQ: qcril_qmi_get_pref_data_tech: is_dsd 1
    RILQ: qcril_qmi_get_pref_data_tech: Report DSD technology Index 0

One technology, no WLAN index, so IWLAN is never a candidate. The RIL's own search functions name
what they are looking for — `qcril_arb_check_wlan_rat_dsd_reported`,
`qcril_arb_find_index_rat_not_wlan_dsd_reported` — and the corresponding log lines
(`DSD WLAN status %d, WLAN index %d`) only appear once the modem reports one.

**What feeds DSD is CNE**, and its symbols spell out the trigger:

    strings -a vendor/lib64/libcne.so | grep -iE 'wlan|iwlan'
      _ZN6CneSrm14updateWlanInfoER5_Wlan
      _ZN6CneSrm21updateWlanScanResultsEPv
      NOTIFY_WLAN_STATUS_PROFILE
      _ZN15CneFeatureCache16getIwlanUserPrefER20CfoIwlanUserPrefType
      Iwlan pref is unchanged. Not updating

So: the framework CNE service watches the Wi-Fi network, pushes it to `cnd`, `cnd` sends
`NOTIFY_WLAN_STATUS_PROFILE` with the WLAN status and the IWLAN user preference, the modem's DSD
then lists WLAN, and only then can an ePDG attempt happen.

That last string is worth reading twice. `cnd` pushes on *change*. A boot where the Wi-Fi calling
preference is already at its final value may never push at all, which means "enable WFC and reboot"
can be a strictly worse test than "boot, then toggle WFC off and on".

**Toggle it through the API, not the database.** Writing `wfc_ims_enabled` straight into
`content://telephony/siminfo` changes the value and the framework re-reads it, but sends nothing
down: the push to the ImsService happens inside `ImsManager.setWfcSetting()`. Zero
`qcril_qmi_imss_request_set_ims_config` messages followed a direct database write. Use the Settings
UI, or call the API.

One trap while doing that: setting `wfc_ims_enabled` makes the framework start honouring
`wfc_ims_mode` from the same row. If that column holds a stale `0`, you have just put the device in
WIFI_ONLY and it will refuse cellular calls. Set the mode explicitly at the same time.

## Find out where the IMS stack lives before porting anything

Two designs ship on the same SoC. Qualcomm's: IMS runs on the modem, the AP only has
`imsqmidaemon`/`imsdatadaemon`/`ims_rtp_daemon` and the modem publishes QMI services IMSS 0x12,
IMSA 0x21, IMSP 0x1f, IMS_RTP 0x28 (the Robin, the Pixels). An OEM AP-side design (LG V20): a SIP
stack in AP libraries driven by an OEM app, the modem publishes none of those, and the only
modem/AP coupling is a small private QMI service. The porting work is different in kind -- a bridge
to a modem IMS stack is a Binder shim; an AP-side stack is 32-bit 2016 blobs against a current
framework plus the OEM hook -- so settle this first:

    qmi-services.py live            # rooted phone: service table by processor; names the IMS ids
    qmi-services.py lib <oem .so>   # service id + message ids an OEM QMI client library talks to
    qmi-services.py idl <oem .so> [svc-hex]   # TLV layout of every message (types, offsets, array sizes)

A vendor id on the modem (0x2bd..0x2c3 on the V20) that also appears in an OEM lib
(`libvss_ims_qcci.so` -> 0x2bf, two messages) is the OEM hook, and it is reachable from a plain
QMI client without the OEM's RIL. `strings` on the modem image confirms the split: a modem IMS
stack has SIP method names and `imsa_`/`imss_` symbols; an AP-side design has only the hook names.

When `idl` shows the hook's payload as an opaque `u8[N]` TLV, the protocol is one layer up: find the
single lib that imports the qcci lib (grep the raw system image for its name, map the offsets with
`debugfs icheck`/`ncheck`), disassemble its `*_send_msg`, and read the framing header off the
stores into the buffer before the call (the V20 one is a 32-byte `{type, last, len, offset, hdrsize,
session, seq, 0}` with 220-byte fragments). The indication handler's jump table gives the
modem-to-AP message types the same way.

## Trace how the OEM app talks to the modem, layer by layer

An AP-side IMS stack still has to tell the modem it is registered (domain selection, SRVCC, CSFB
decisions live in the modem). That path is not where you expect -- on the V20 the private QMI hook
turned out to be only the media pipe, and registration went through the OEM's RIL. Trace it rather
than guess, and bank each hop; every one is a hook a bridge can call directly:

1. **App -> framework.** `oat-to-smali.sh <stock Ims apk/odex>`, grep the registration agent for
   `invoke-interface` on OEM Binder interfaces (`I*Phone`, `setSysInfo`, `LgSvcCmd`). The interface
   name in `asInterface` (`"com.lge.ims.phone"`) tells you which process implements it; the stub is
   wherever `strings` on the boot oats finds the class (`boot-telephony-common.oat`, not the
   telephony app).
2. **Framework -> RIL request.** `oat-to-smali.sh` on that boot oat; follow the dispatch
   (`setSysInfo(type, ..)` is a switch -- record the whole type table, it is the OEM's modem API) to
   a `RILRequest;->obtain(I..)` whose `const/16` is the RIL request number. The `RIL.smali` method
   also shows the parcel layout (`writeInt` order).
3. **RIL request -> qcril handler.** `strings vendor/lib64/libril-qc-qmi-1.so | grep -i <keyword>`
   names the handler (`qcril_qmi_lge_vss_set_modem_info`, `lge_qcril_qmi_nas_hvolte_update_ims_status_request`).
4. **Handler -> QMI message.** `fn-calls.sh <qcril lib> <handler>`: the immediates in front of the
   `*_send_cmd`/`qmi_client_send_msg_sync` call are the message id, request length and timeout.
   `qmi-services.py idl <idl lib> <svc>` gives that message's TLV layout; its C struct size must equal
   the length passed, which is the check that you read the right id. A handler that goes through a
   generic `raw_cmd(kind, item, ..)` dispatcher picks the id from a stack slot -- use `--dis`.
5. **Modem side.** `modem-strings.sh <modem.image> <out>`: `qmi-req.txt` names the server handler
   (`qmi_vss_set_ims_status_req`), `all.txt` the code it feeds (`cmss.c lgp_set_ims_status`, then
   `cmsds.c` domain-selection lines), `efs.txt` the NV items that gate it.
6. **Inside the compressed modem code.** `modem-strings.sh` only recovers plaintext; ~85% of a Hexagon
   modem is q6zip-compressed, so a log line you can see does not mean its *branch* is visible. To read
   the code: `modem-decompress.sh <modem.image|elf> <out>` reassembles the ELF, decompresses the q6zip
   code segment to a flat VA image and disassembles it (`out/q6.dis`, based at the dlpager VA, typically
   0xd0000000). Then `modem-xrefs.py <modem.elf> msg <rodata VA>` turns a QShrink msg_const into its
   string, and `grep` in `q6.dis` for the `immext(#<strptr>)` that loads it finds the exact log site --
   read the enclosing function to see the condition. This is how you confirm whether a mode is real or
   dead code: trace the flag the branch tests back to its writer. A flag that is **read but never
   written** anywhere (no store in q6.dis nor the uncompressed `llvm-objdump -d modem.elf`, no data
   pointer via `modem-xrefs.py ptr`, and `modem-xrefs.py read <VA>` returns nothing = it is in
   demand-zero BSS) defaults to 0 -- the mode exists in the binary but nothing arms it. (Real example:
   LG's "3rd Party IMS Enabled" domain-selection mode on the V20 is gated on a `cmsds` global byte that
   nothing sets, so no EFS item turns it on.)

Expect more than one route for the same fact, split by operator (`setRegiStateForVZW` vs the
generic path), and expect one of them to be a standard Qualcomm message hiding behind an OEM RIL
number -- `RIL 292 -> NAS 0x0072 update_ims_status` is what any non-OEM IMS stack would send, and
it does not need the OEM's RIL at all.

Check the stock app's Binder surface the same way as on the Robin (`oat-to-smali.sh`, then
`ether-20.0/gen-legacy-aidl.py`): the TRANSACTION_* order in the stock framework's `I*$Stub` is the wire
protocol, and one inserted method (7.0 -> 7.1 added `IImsService.addRegistrationListener`) shifts
every later id.

## Prove the OEM's native stack loads before building it in

Reusing the OEM's own IMS libraries (the SIP stack is theirs; the modem serves no IMS QMI) means a
2016 32-bit blob against a current framework. Before any app/sepolicy/make work, answer one question:
does it even dlopen? `abi-gap.sh` estimates the symbol gap; `dlopen-probe.sh` proves it, closure and
constructors included.

1. `abi-gap.sh <lib>` first for the shape: the SIP core usually needs a tiny, ABI-stable slice of
   libutils/libbinder (on the V20, `libims.so` was 7 missing symbols -- 5 `uuid_*` from the dropped
   `libext2_uuid.so`, 2 libutils helpers). The media lib carries the real drift (Surface ctor sizeof,
   camera/GraphicBufferMapper/AudioSystem), and it is all video -- irrelevant to voice.
2. `dlopen-probe.sh <lib> --supply <stock extract> --stub <cut-out libs> --preload <your shims>`:
   it dlopens on the device from the shell default namespace (which, unlike an app's classloader
   namespace, can reach /system/lib + the staging dir -- so this isolates the ABI question from the
   packaging one), auto-walks the DT_NEEDED closure out of the stock extract, and reports the first
   real symbol gap. Supply the pure-libc/vendor deps from stock (uuid, the QMI client stack); empty-
   `--stub` the subsystems you are cutting (video codecs: libOmx*, libstagefrighthw -- co-loading the
   stock ones fails on libbinder vtable thunks anyway); `--preload` the shims you author.
3. Author two kinds of shim, freestanding (`-nostdlibinc`, declare the handful of libc funcs you call,
   link against the device's pulled libutils/libc):
   - **real reimpl** for a dropped helper whose behaviour you can reproduce (`String8::getPathLeaf`
     calls the live String8 ctor; `strndup16to8` is a self-contained UTF16->UTF8).
   - **load-only stub** for a symbol on a path you will never call: give it the exact mangled name
     with an `__asm__("<mangled>")` label on a function returning 0. Mark it clearly -- a stubbed
     `Surface` ctor or `AudioSystem::setParameters` satisfies the loader and crashes if used. Make the
     one symbol on the path you DO need (voice audio: `AudioSystem::setParameters`) real before relying
     on it.
   Preload shims via `LD_PRELOAD`, not a dlopen-RTLD_GLOBAL: on 32-bit bionic RTLD_GLOBAL is 0x2 and
   the global-group route does not reliably expose a preload's symbols to a later dlopen.

A clean "OK ... loaded" means the closure resolves and no constructor faulted -- the dlopen/onCreate-
native layer is cleared. It does NOT mean the lib works (abi-gap.sh's header: semantic drift, grown
types). The remaining order is: real-shim the few on-path symbols, package as an app namespace
(ld.config.txt + sepolicy) or host the stack in the telephony process (how the Robin bridge dodged the
namespace wall), then the Binder/AIDL bridge, then feed the modem.

## Rework an OEM legacy IMS app to run on a newer Android

When the IMS implementation is an OEM app (LG `Ims4`, QTI `ims.apk`) built against a framework API the
new release deleted (`com.android.ims.*`, gone since P), the app must be made self-contained: rename the
removed package to a private one and merge that package's classes into the app's own dex. Done on the
Robin (QTI, A13) and the V20 (LG, A17). The pieces, in order:

1. **Deodex the app and the legacy framework jar.** `oat-to-smali.sh` on the app's clean classes.dex;
   `deodex-jar.sh <oat> <system.image|bootcp> <out>` on the framework jar(s) that hold the legacy API
   (on the V20: `boot-ims-common.oat` has the concrete classes). deodex-jar resolves the quickened
   opcodes against the stock boot classpath -- a plain `baksmali d --allow-odex-opcodes` leaves them in
   and the smali then will not reassemble. It fails loudly if any quick opcode survives (partial deodex
   installs fine and only breaks at runtime).
2. **Regenerate the AIDL interfaces, do NOT deodex them.** The `I*$Stub/$Proxy` binder classes rarely
   deodex cleanly (invoke-virtual-quick into Parcel by vtable index). `gen-legacy-aidl.py` rebuilds the
   `.aidl` from the smali instead -- transaction order from the `$Stub`'s `TRANSACTION_` constants
   (which survive quickening), signatures from the interface's abstract methods. Set `LEGACY_PKG` to the
   private package. Then compile: `aidl` (aidl must sit at its package path; `-I` the tree's framework +
   `telecomm/framework/aidl-export` for VideoProfile + `frameworks/native/aidl/gui` for Surface) ->
   `javac` against `prebuilts/sdk/current/public/android.jar` -> **R8's D8** (`prebuilts/r8/r8.jar`
   `com.android.tools.r8.D8`; the old `d8.jar` lacks `--min-api`) -> baksmali. Verify the regenerated
   `$Stub` transaction codes match the stock ones byte-for-byte -- that is the binder-compatibility check.
   The AIDL compile needs each referenced parcelable as a build-time stub `.java` (CREATOR +
   writeToParcel) on the classpath.
3. **Parcelables: stub for load, real for calls.** AOSP parcelables whose only quick op is
   `return-void-no-barrier` are clean after one sed. The rest (OEM parcelables, UCE/RCS) can be minimal
   `implements Parcelable` stubs for the *load* milestone (they are off the service-start path), made
   real only when a call actually marshals them. Before relying on "real": check WHICH jar the OEM's
   parcelables live in and that the merged tree actually got them -- `grep -c '^.field'` the merged
   `ImsCallProfile.smali`. On the V20 they are in `boot-framework` (not `boot-ims-common`), so the
   build-time stubs (1 field) silently shipped and REGISTER worked while a call would have arrived
   with no number. The stock framework oat is **multidex**: `baksmali x <oat>` deodexes only the first
   dex entry (framework.jar's `com/*` is in `classes2.dex`) -- `deodex-jar.sh` now walks every entry
   from `baksmali list dex`; a single-entry deodex of framework.jar is the classic partial that LOOKS
   complete (5990 files, zero quick opcodes, no `com/`).
4. **Rename + merge.** `merge-legacy-classes.py --app <smali> --legacy <clean-dirs> --old com/android/ims
   --new <private/pkg> --out <merged>` renames every type descriptor and exact-match AIDL descriptor
   string (not broadcast actions), merges the legacy closure in, and redirects the @hide specialized
   `System.arraycopy` overloads to the public generic one (a 2016 app calling the specialized form dies
   with IllegalAccessError at onCreate under hidden-API enforcement). Then `smali.jar assemble` ->
   replace classes.dex -> strip META-INF -> ship via `android_app_import certificate:platform` (the OEM
   `sharedUserId` must stay signed by the platform key).
5. **Bitness.** The OEM SIP libs are 32-bit. An app with no bundled native libs launches 64-bit on a
   zygote64_32 device and cannot load them. Bundle the 32-bit libs in the apk (`lib/armeabi-v7a/`,
   `extractNativeLibs=true`) -- that forces the process 32-bit AND puts the libs in the app namespace's
   own permitted path, so only the framework libs need public.libraries; see the load section above.
6. **Then** the Binder/AIDL bridge (the compat ImsService), the ImsResolver config, sepolicy (author it;
   expect runtime denials), and the modem reg path. Bridge gotcha for a 7.0-shape `IImsService` (one
   listener slot, `setRegistrationListener` REPLACES, no `addRegistrationListener`): the compat layer
   adds two listeners after `startSession`, so hand ONE multicast adapter to `open()`, fan out, and
   cache the last connected/disconnected/feature-bitmap/URIs to replay to late joiners. The OEM app
   replays only connected/disconnected to a new listener and emits the feature bitmap only on a UC
   state CHANGE -- a bridge that opens after registration completed reports "registered, voice
   disabled" forever (every call goes CS); rebuild the bitmap from `isConnected(id, NORMAL, VOICE/VT)`
   after `open()` returns (not inside the callback: that is a nested binder call).

## Get the reworked OEM app to RUN (the runtime-bringup layer)

Rebuilding the app so it *assembles* (previous section) is half of it; getting the process to survive
onCreate and register its service is the other half, and it comes as a sequence of distinct failures,
each with its own signature. Observed bringing LG's `Ims4` up on A17; the order is general.

1. **Boot hang, system_server FATAL at `onSystemReady`**: `"Signature|privileged permissions not in
   privileged permission allowlist: <pkg> <perm>"`. A priv-app requesting `signature|privileged`
   permissions must be allowlisted. Generate the allowlist from the app's own manifest --
   `aapt2 dump permissions app.apk | grep uses-permission` -> a `privapp-permissions-<pkg>.xml` in
   `/system/etc/permissions` (or system_ext). Missing this takes the whole boot down, not just the app.
2. **`NoClassDefFoundError` for an OEM framework class** (`com.lge.os.Build`, ...): the app calls into
   the OEM's framework extensions, absent on AOSP. Hand-write a minimal smali stub with exactly the
   fields/methods the app reads (check the `sget`/`invoke` sites) and merge it in (an `extra-smali`
   dir). Scope them with `grep -rhoE "Lcom/<oem>/[A-Za-z0-9_/$]+;"` on the app smali minus what the apk
   itself defines.
3. **Package silently not installed, PM log `"Signature mismatch for shared user"`**: an app with
   `sharedUserId` (android.uid.phone/.system) must be signed with the SAME key as the others in that
   uid. That is the key THIS build signed platform apps with -- frequently build/make's default
   `platform` key, NOT testkey and NOT a custom release key. Read the device's actual platform cert
   from an installed platform app and match it (`push-system-app.sh` does this).
4. **`NoSuchMethodError` on a framework class** (`SubscriptionManager.getSlotId` -> `getSlotIndex`):
   API drift -- the class survived, the method was renamed/removed. Redirect old->new in smali
   via a `method-redirects.txt` applied by `apply-method-redirects.py`: a literal rename when the
   method moved; `|static Lcompat;->m(Lrecv;...)` when it is GONE (`TelephonyManager.getPcscfAddress`
   -> a compat static over `LinkProperties.getPcscfServers()`, receiver as arg 0, compiled against the
   `system` stub jar for @SystemApi). Note the failure only surfaces when the path RUNS -- here on the
   ConnectivityThread the first time the IMS PDN came up, so it hid behind the APN gate (6) for days.
   Find these ahead of time with `app-fw-api-gap.py`.
5. **`SecurityException`/property-set failure, then avc denials**: sepolicy. The app sets properties
   (`avc denied { set } property=... tclass=property_service`), opens sockets, reads files. It runs in
   whatever domain its uid maps to (android.uid.phone -> `radio`). **You usually cannot iterate this at
   runtime** -- `setenforce 0` is denied on a locked policy -- so sepolicy changes need a reflash. The
   efficient path is the standard vendor-component bringup: make the domain permissive (its own seapp
   domain, or the shared one) for one reflash, let it run through surfacing every denial, `audit2allow`,
   then write real rules and lock down.
6. **The app runs but a gate is stuck** ("APN is blocked; LTE only supports the emergency service"
   forever, no exception anywhere): a verify stub changed the app's control flow. Stubs that stand in
   for OEM *enums* return the same code from every constant, so `state.getCode() ==
   EMERGENCY.getCode()` is always true and `fromInt(n) == CONST` never is. `gen-verify-stubs.py` warns
   `!! enum-like` for this shape; for those classes copy the real names/ordinals/codes from the stock
   deodex (`fromInt` must return the singletons -- callers compare by reference). Audit a stuck gate by
   reading the condition's smali back to which stub it consults, before suspecting the platform.

**Iterate dex/resource fixes without reflashing** with `push-system-app.sh` (a ~3-min loop vs a ~45-min
rebuild+reflash). It handles the three traps: shared-uid signing (matches the device cert), and the
flaky block-`/system` remount (only the first `mount -o rw,remount /` after a clean boot persists, so
it pushes to /data and `cp`s within one root shell on a fresh boot, then reboots for PM to rescan).
sepolicy and anything in the boot image still need a real reflash.

**Preflight the API drift** with `app-fw-api-gap.py --app <smali> --fw <all framework jars>`: it finds
the `NoSuchMethod`/`NoClassDef` the app will throw, statically, so you fix them in one batch instead of
one reboot each. It is inheritance-aware and conservative (won't flag a method whose class's full
ancestry is not in the DB), so ACCURACY HINGES ON A COMPLETE `--fw`: on modern Android the framework is
split across mainline modules (SubscriptionManager is in framework-telephony, not framework.jar), so
pass EVERY `/system/framework/*.jar` + all apex `/javalib/*.jar` (incl. core-oj/core-libart for the
java.* ancestry) or it stays silent on classes it cannot see. It complements, not replaces, the runtime.

## The OEM stack's native helpers: find them from the error, not the strings

An OEM IMS app rarely does everything in-process. Past the point where the SIP stack runs, the next
class of failure is a step it delegates to a small daemon that stock init started and your build does
not have. Two LG examples, both only visible once the stack got that far: the SIP REGISTER security
agreement (RFC 3329 `Security-Client: ipsec-3gpp`) -- libims computes the ESP SAs after the 401 but
hands them to `ipsecstarter`/`ipsecclient` (netlink xfrm) to install, and SMS-over-IMS, which goes
through `imswmsproxy`. Without the helper the log shows a *send* failing, the step marked failed, and
the whole registration torn down and retried forever.

How to close one:
- **Check what the socket is before chasing a directory.** `ECONNREFUSED (111)` on a unix socket path
  that does not exist on disk means an **abstract** socket (`sun_path[0] == 0`): a missing *path* gives
  `ENOENT`. Confirm with `grep <name> /proc/net/unix` -- abstract names show with a leading `@`. The
  path-like string in the binary is just a name; no `/tmp` directory, no `mkdir`, no file label, and
  sepolicy checks the *peer domains'* `unix_dgram_socket sendto`, not a file type.
- **Reproduce the chain by hand first, then make it an init service.** Pull the stock binaries, `ldd`
  them (these helpers are typically libc/libcutils/libc++ only and run unmodified), run them from
  `/data/local/tmp` as root while the app is up, and watch the step succeed. Expect a launch-order
  dependency: LG's `ipsecclient` exits immediately if the app's socket is not bound, which is why stock
  ran it `disabled` and had the starter `ctl.start` it on demand. Copy stock's rc lines (from the boot
  image ramdisk, `init.<device>_product.rc`), not your guess of them.
- **Ship them the way the app is shipped**: proprietary -> staged, not committed (`cc_prebuilt_binary`
  with `srcs` pointing at the staged file, `compile_multilib: "32"` for 32-bit stock, `init_rc`), and a
  domain per helper in the device's *product private* sepolicy (platform file_contexts may label
  `/system/bin`; vendor file_contexts may not). `cc_prebuilt_binary` resolves the binary's imports
  only against the libs *listed* in `shared_libs` (check_elf_file), not against the libs those pull
  in -- a stock helper that reaches `__android_log_print` through libcutils still needs `liblog`
  listed, or the ROM build fails long after the preflight passed. A helper that `ctl.start`s another needs
  `ctl.start$<svc>` in property_contexts mapped to a prop type the starter may set -- a coredomain may
  only set `system_property_type`, so declare it with `system_internal_prop(...)`, not a bare
  `property_type`.

## Bridge the reworked app into the modern telephony stack (the compat ImsService)

The reworked OEM app registering with the network is invisible to the framework until something
implements `ImsService` on its behalf. Still true on 17: `ImsResolver` binds services declaring the
`android.telephony.ims.compat.ImsService` action (`ImsServiceControllerCompat`), so a small priv-app
that implements the compat `MMTelFeature` over the OEM's legacy `IImsService` binder is enough -- no
framework patch. `new-ims-bridge.sh` writes it from `templates/ims-bridge`; what is per-device:

- **The legacy AIDL.** Generated from the OEM's deodexed `$Stub` smali with `gen-legacy-aidl.py`
  into the bridge's `aidl/` (same `LEGACY_PKG` the app was renamed to) and *committed*. Do not
  assume another port's copy fits: `aidl-tx-diff.py <stub-smali> <aidl-dir>` -- LG's 7.0
  `IImsService` has 15 transactions, QTI's 7.1 has 16 (`addRegistrationListener` inserted at 6).
- **Parcelable wire order.** The bridge carries Java copies of the 7.x parcelables (`ImsCallProfile`,
  `ImsReasonInfo`, ...). Read each one's `writeToParcel` in the stock framework smali and compare:
  OEMs append fields (LG: `restrictCause` after `mediaProfile`, `--restrict-cause`), and a mismatch
  shifts every later read instead of throwing. The same real classes must also be in the reworked
  *app* (previous section, item 3) -- stubs on one side and real on the other is the same bug.
- **Listener shape.** One multicast adapter handed to `open()`; the feature bitmap probed from
  `isConnected(id, NORMAL, VOICE/VT)` after `open()` returns (see item 6 above). Both are in the
  template; nothing to configure.
- **Wiring** (device repo, one patch): `PRODUCT_PACKAGES += ImsBridge android.hardware.telephony.ims.
  prebuilt.xml` (without the feature xml PhoneGlobals never constructs an ImsResolver -- no log line);
  Telephony overlay `config_ims_mmtel_package = org.lineageos.ims.bridge`;
  `ro.telephony.block_binder_thread_on_incoming_calls=false` (the compat path delivers
  `onIncomingCall` on the bridge's main thread and ImsPhoneCallTracker would join() it). The bridge
  shares `android.uid.phone` with the OEM app: platform cert, and seapp_contexts puts it in `radio`
  with the app -- no new domain.
- **17 build facts**: `platform_apis: true` is enough for `android.telecom.*` (telecom is a mainline
  module; its `VideoProfile.aidl` sits at `frameworks/base/telecomm/framework/aidl-export`, so that is
  an `aidl.include_dirs` entry next to `frameworks/base/core/java`); `android/view/Surface.aidl` is
  gone from core/java, the template ships its own parcelable declaration.
- **The compat path needs a framework fix on 17 (and probably anything past 13).** Binding ANY compat
  ImsService kills `com.android.phone` and it restart-loops:
  `ImsProvisioningController` -> `ImsConfig#addConfigCallback` -> `ImsConfigImplBase$ImsConfigStub
  .executeMethodAsync` -> NPE in `CompletableFuture.screenExecutor`. Every `*ImplBase` dispatches
  binder calls through `runAsync(.., mExecutor)`; `ImsServiceControllerCompat.createMMTelCompat()`
  builds the MmTel/registration/config adapters and calls `setDefaultExecutor()` on none of them, so
  that executor is null -- and null there throws rather than falling back to the calling thread. The
  modern path sets it in `ImsService#getConfig/getRegistration/createMmTelFeature`, which is why
  nothing upstream notices: the compat path has been deprecated since P. Patch
  `ImsServiceControllerCompat` to set it on all three adapters (the other two reach the same
  `runAsync` and fail on the next call). Expect more rot in this path for the same reason.
- **What actually gates an IMS dial** -- not the modem's VoPS flag:
  `GsmCdmaPhone.useImsForCall()` -> `ImsPhone.isVoiceOverCellularImsEnabled()` ->
  `ImsPhoneCallTracker.isImsCapabilityInCacheAvailable(CAPABILITY_TYPE_VOICE,
  REGISTRATION_TECH_LTE)`. That cache is fed by the registration callbacks, i.e. the feature bitmap
  the bridge publishes, so `vops=false` in the RIL does not stop an IMS call but a missing bitmap
  does. Check `dumpsys telephony.registry` / `mMmTelCapabilities` before suspecting the modem.
- **Push the bridge onto the running build instead of waiting for a flash.** The APK, the feature xml
  and a `ro.` prop in build.prop all go in with one `/system` remount, and `cmd phone cc set-value -p
  config_ims_mmtel_package_override_string <pkg>` points ImsResolver at it without rebuilding the
  Telephony overlay (`cmd phone ims set-ims-service -d` does NOT stick -- the getter keeps reporting
  the overlay). That turns a 75-minute build+flash per hypothesis into minutes; it is how the
  executor NPE above was found. Clear the override (and remove the apk) before walking away -- a
  persisted override pointing at a crashing service restart-loops the phone process, waking the
  screen with a notification every few seconds. Note the override is stored per-ICCID under
  `/data/user_de/0/com.android.phone/files/` and survives reboots.
- **Verify**: `dumpsys telephony.registry` shows IMS registered; logcat tag `ImsBridge` for open()/
  replay/bitmap probe; an MT INVITE now rings the InCallUI instead of being CANCELled by the network
  with `480 CC_NOT_REACHABLE` ~18 s later (that CANCEL is the signature of "SIP works, nothing is
  listening above it").

## The OEM media stack asks the MODEM for the RTP address (and what to do when that fails)

Signalling working is not audio working. Past REGISTER and INVITE the next class of failure is the
media layer, and an OEM stack may not look for the local RTP address where you expect: LG's asks the
*modem* for the IMS PDN address over a private QMI tunnel, and logs the failure under a tag nobody is
filtering on. The shape generalises to any OEM IMS media lib.

- **Find the tags before chasing the bug.** A library linked into someone else's process contributes
  its own logcat tag, so the app's tag shows you none of it. `blob-log-tags.py <lib.so>` resolves the
  tag literal at each `__android_log_*` site. On the V20 the SIP core logged under the tag everyone
  watched while the real cause sat under `MMPF` (libimsmmpf) and `QMI_FW` (libvss_ims_qcci) -- never
  captured until the tags were known. Prefer the tags that log at E.
- **The chain, for reference**: `AudioAdaptor::GetIPAddrOfCP` -> binder to the OEM's media service
  (`getService("lgeims_mmpf")`) -> a private QMI service (LG: `0x2BF lge_ims`, msg `0x060C`, an
  opaque `u8[300]` tunnel) -> the answer arrives as an *indication*, not in the response. The error
  the SIP layer prints (`Error[21]`) is only a 1 s timeout waiting for that indication, and the QMI
  send result is **discarded** -- a failed send and a silent modem look identical from above. Never
  diagnose from the SIP-layer error code; get the transport's own log.
- **Four outcomes, needing different fixes.** With the real tags captured:
  `ERROR!!! ims handle is NULL` -> the QMI client never came up in that process (AP-side; suspect the
  IPC-router/qmuxd socket under sepolicy). `Error sending TXN` / `xport_send: Sendto failed` -> the
  client is alive but the message never left the AP (AP-side transport). Request sent, no indication
  -> the modem is silent; check what it is being asked about before blaming it. Indication received
  but the address unused -> a gate upstream rejected it.
- **Check what the modem is being asked about.** LG logs
  `UpdateModemIPv6() - PDP profile : %d, Socket Pos : %d`. A profile of `-1` means the AP never
  learned the IMS PDN profile number -- the OEM stack expects the OEM RIL to supply it, so on a port
  running a stock/AOSP RIL this is an AP-side config gap, not a modem fault.
- **Before assuming silence means no audio, look for a fallback.** LG's `AudioProfileConfigurer`
  falls back to the stack's normal local-address accessor when the modem address is empty, and that
  is what `MakeSDPFromProfile` puts in `c=`/`o=`. So first confirm an AP-side IMS PDN address exists:
  `dumpsys telephony.registry` for the `ims` APN's `InterfaceName` / `LinkAddresses` (on the V20 it
  is CONNECTED on its own `rmnet_data*` with a global address and the P-CSCF list). If it does, the
  modem query failing is probably not what breaks audio -- look at the RTP socket bind instead.
- **Gates are properties worth finding.** LG's `UpdateModemIPv6` has eight logged gates; one is
  `IsUseSingleIP()` = `persist.lg.data.iwlan.ipsec.ap`, whose only caller is that function. Setting
  it skips the doomed query and reaches the fallback at once -- on the V20 the failed query retried
  four times and added ~3.3 s to call setup. That removes a delay; it is not a fix for audio.
- **A service the OEM app publishes needs a `service_contexts` entry before sepolicy is locked down.**
  `avc denied { add } name=<oem_service>` under a permissive domain *succeeds*, so media works during
  bringup and dies the moment that domain is enforcing. Note `service list` from `adb shell` can
  itself be denied `find` on it -- that is the check lying, not the service missing.

## The call connects and nobody can hear anything

A silent call is not one bug, it is a ladder, and each rung has its own unambiguous signal. Walk it
in order -- the symptoms of the top and bottom rungs are identical from the earpiece. Observed
bringing LG's Ims4 up on 24.0; the layering is QTI-generic.

1. **Is the media even negotiated?** If an answered call tears itself down after ~20 s with no user
   action, that is an RTP-inactivity teardown, not a routing problem: the framework sets
   `mRtpInactivityTimeMillis` (5 s) and the OEM stack has its own monitor
   (`#WARNING# Can't receive peer's RTP pkts`). A call that now *stays up* until someone hangs up
   (`onCallTerminated reasonCode=501 CODE_USER_TERMINATED`) means RTP is arriving and the problem is
   below this rung. This single observation separates "no media" from "media but no audio" and is
   the most useful thing to ask the person holding the phone.
2. **Where does the media actually run?** Do not assume AP-side. Look for an `AudioTrack`/
   `AudioRecord` in `dumpsys audio` during a call: if there is none and the audio mode is already
   `MODE_IN_CALL`, that is not the bug -- it means the voice path is **modem-side**, which on QTI is
   normal. The giveaways are a VSID in the OEM media log (`setAudioCalInfoParam[vsid=0x11c05000...]`)
   and a `CP_Proxy` backend in the engine. AP-side RTP sockets can exist at the same time (check
   `/proc/net/udp6` for the IMS uid) and are a red herring: they are the stack's own monitoring.
3. **Can the AP talk to the modem at all?** The modem session is created over a private QMI service,
   and that is where a port breaks -- see the IPC-router section above and run `qmi-sec-check.sh`.
   `createMediaSession` followed by `send_msg_sync error: -16` means no session exists and nothing
   below this rung can work.
4. **Is the audio HAL told the session went active?** This is the rung a port silently deletes.
   The HAL opens the earpiece/mic path in `voice_extn_set_parameters()` -> `update_call_states()`
   when handed `vsid=<id>;call_state=<state>` (values from the HAL source, not a public API:
   `VOICEMMODE1_VSID 0x11C05000`, `CALL_INACTIVE 1`, `CALL_ACTIVE 2`). **Nothing in AOSP ever sends
   those keys** -- on a QTI device the vendor IMS app does it, on an OEM ROM the OEM's telephony
   framework did, and a port replaces that with AOSP. Symptoms: `MODE_IN_CALL` is set, the HAL
   supports `volte-call` and `voice_start_call`, the correct VSID even appears in the HAL log -- but
   only as `update_calls: cur_state=1 new_state=1` at teardown, which is the HAL's own stop-all path,
   not an activation. Grep for `update_call_states` ever running with state 2; if it never does, send
   the keys yourself from whatever component knows IMS call state (for a bridge: the call-session
   listener's started/terminated callbacks -- `templates/ims-bridge` has `ModemVoiceSession`).
   The HAL parses both keys with `str_parms_get_int`, so send **decimal**, and confirm the VSID
   matches the one the modem actually picked rather than hardcoding blind.
5. **Only then suspect the codec or calibration.** AMR-WB/EVS support, ACDB, mixer paths. Everything
   above has to be true first, and on this port none of it turned out to be the problem.

## An OEM's own sec_config can omit the QMI service its own stack needs

On a QTI SoC the kernel's MSM IPC router gates each QMI service by GID. `irsc_util` feeds it
`sec_config` at boot; a service with **no rule at all** is reachable only by root, so a vendor
process running as radio/system fails on exactly that service while every other QMI path works.

- The kernel says so plainly, and it is the only unambiguous signal:
  `IPC_RTR: msm_ipc_router_send_to: permission failure for <thread>` in `dmesg`, alongside
  `QCCI qmi_cci_flush_tx_q: Error sending TXN: svc_id: <N>` and `xport_send: Sendto failed` in
  logcat. The QMI layer above reports a generic transport error (`-16`) and the layer above *that*
  usually discards even it, so without `dmesg` this looks like a silent modem.
- `qmi-sec-check.sh` cross-references the failing service ids against the rules and prints the line
  to add. On the V20 LG's own file granted 1-511, 704 and 4097 and omitted **703** (`lge_ims`) --
  the service LG's own IMS media stack needs for the modem voice session.
- **The rule must exist before the service registers.** The router binds a rule to a service at
  registration, so running `irsc_util` by hand after boot changes nothing and makes a correct fix
  look wrong. Put it in the file init already feeds (often a device-tree file:
  `device/<oem>/<soc>/configs/permissions/sec_config`, installed by the device mk and run from
  `init.qcom.rc`) and reboot.
- Instance `4294967295` is "all instances"; GIDs that matter are usually 1000 system, 1001 radio,
  3004 net_raw.

## Testing an OEM IMS helper daemon without building a ROM

The OEM stack delegates steps to small daemons stock's init started (IPsec for the REGISTER security
agreement, a WMS proxy for SMS over IMS). You can prove or disprove one in minutes, no build:

1. **Extract both ABIs from the stock image** and match the daemon:
   `debugfs -R 'ls -l /vendor/lib64' system.image` then
   `debugfs -R 'dump /vendor/lib64/<lib> <out>' system.image`. Same-named libraries exist under
   `/vendor/lib` and `/vendor/lib64`; the wrong one fails at link with "is 32-bit instead of 64-bit".
2. **Place it by namespace, not by where stock had it** -- `/vendor/bin` if it links vendor libs
   (GOTCHAS 37).
3. **Run it from a root shell**, not init: init cannot exec a label with no `exec_type`, and the root
   shell's `u:r:su:s0` is permissive on userdebug, so policy is out of the way for the experiment.
4. **Check the abstract sockets**, which is how these daemons rendezvous with the OEM app:
   `grep '@/tmp/...' /proc/net/unix` should show both the app's and the daemon's names once the
   chain is live.
5. **Expect the app to retry.** The OEM app may re-attempt its init on a timer (LG's SMS-over-IMS
   client retries every ~3 s), so the daemon does not have to be up before the app -- which means
   you can iterate without rebooting. Confirm from the log before assuming launch order matters.

What this cannot test is the sepolicy domain the real patch needs, so treat a success here as
"the chain works", not "it is ready to ship".

## Locking an OEM IMS stack down from `permissive`

Bringing the OEM app up means running its domain permissive; shipping means removing that. The
denial set from a permissive boot gets you most of the way, with two traps.

- **Audit from a boot that did everything**, not just one that registered. The services the stack
  publishes lazily (the media service that creates the modem's voice session) only appear once a
  call has been made, and that service failing to publish is exactly the kind of denial that costs
  audio while leaving calls connecting normally.
- **Expect one enforcing boot to find more.** A permissive audit logs what *would* have been denied
  given the current policy, so it cannot show anything your new rules themselves introduce --
  notably ioctl whitelisting (GOTCHAS 38), which does not exist until you add an `allowxperm`. On
  the V20 the first enforcing boot surfaced a second QMI ioctl and a third service
  (`com.lge.ims.rcs.media`) the permissive run never recorded.
- Services the OEM app registers need `service_contexts` entries plus `add`/`find` for its domain,
  or they land on `default_android_service` where the domain may not touch them.
- Its own properties usually need a type: a coredomain may only set a `system_property_type`, so
  declare them `system_internal_prop` rather than leaving them as `system_prop`/`default_prop`.
- The QMI socket family has no class in policy and lands on the generic `socket` class.

Verify with `logcat | grep "avc.*denied.*radio" | grep permissive=0` on an enforcing boot, and
re-check after any change to the stack -- an empty list there is the only evidence that matters.

