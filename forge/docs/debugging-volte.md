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
   real only when a call actually marshals them.
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
   expect runtime denials), and the modem reg path.

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
  `/system/bin`; vendor file_contexts may not). A helper that `ctl.start`s another needs
  `ctl.start$<svc>` in property_contexts mapped to a prop type the starter may set -- a coredomain may
  only set `system_property_type`, so declare it with `system_internal_prop(...)`, not a bare
  `property_type`.
