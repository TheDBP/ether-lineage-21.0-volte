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
