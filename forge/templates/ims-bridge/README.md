# ims-bridge template

The compat `ImsService` that presents an OEM's legacy IMS app (Android 7.x `com.android.ims` API,
reworked with `merge-legacy-classes.py`) to the modern telephony stack. Instantiate with
`tools/new-ims-bridge.sh`; do not copy by hand -- the `@LEGACY_PKG@`/`@OEM_APP@`/`@DEVICE@`/
`@RESTRICT_CAUSE@` placeholders must all be expanded. Method: `docs/debugging-volte.md`, section
"Bridge the reworked app into the modern telephony stack".

- `src/org/lineageos/ims/bridge/` -- generic: `LegacyMMTelFeature` (compat MMTelFeature over the legacy
  `IImsService`; waits for the "ims" ServiceManager entry, probes the feature bitmap after `open()`),
  `RegistrationListenerAdapter` (ONE legacy listener, multicast + cached replay), call-session / UT /
  ECBM / config / multi-endpoint wrappers, `Convert` (legacy <-> modern parcelables).
- `ModemVoiceSession.java` -- **the audio.** On a stack whose media runs on the modem, nothing in AOSP
  tells the audio HAL the voice session went active, so a call connects and is silent. This sends
  `vsid=<VSID>;call_state=<1|2>` via AudioManager.setParameters on session start/end. The VSID is
  per-platform (`VOICEMMODE1_VSID` 0x11C05000 on msm8996) -- check yours. See the silent-call ladder.
- `CallSessionWrapper` carries an `incoming` flag, set only on the `getPendingCallSession` path, and
  `CallSessionListenerAdapter` uses it to deliver a pre-answer remote hangup (which OEM stacks report
  as `startFailed`) as `callSessionTerminated`. Without it an unanswered call rings until reboot --
  `onCallStartFailed` only unwinds `mPendingMO`, which is null for MT.
- `src-legacy/` -- the 7.x parcelables, installed under the private legacy package. Wire order must match
  the OEM framework's `writeToParcel` (read the stock smali); `ImsCallProfile.WIRE_HAS_RESTRICT_CAUSE`
  is the one known OEM extension (LG).
- `aidl/android/view/Surface.aidl` -- 17 no longer ships it in core/java; the legacy video interfaces
  need it. The legacy `I*.aidl` are NOT here: generate them per device with `gen-legacy-aidl.py` and
  check with `aidl-tx-diff.py`.
- Manifest: `sharedUserId android.uid.phone`, platform cert, no signature|privileged permissions (a
  priv-app requesting one without an allowlist entry kills system_server at systemReady).

Proven on: Robin (QTI `ims.apk`, 7.1 shape, LineageOS 20) and V20 (LG `Ims4`, 7.0 shape, 24.0).
