// Copyright (C) 2026 The LineageOS Project
// SPDX-License-Identifier: Apache-2.0

package org.lineageos.ims.bridge;

import android.content.Context;
import android.media.AudioManager;
import android.util.Log;

/**
 * Tells the audio HAL when the modem's voice session is active, so a VoLTE call is audible.
 *
 * On this SoC the voice media of an IMS call is carried by the MODEM, not by an AudioTrack: the OEM
 * media stack creates a session on the modem (MMPF_CP_IF::createMediaSession over QMI) and the HAL
 * has to open its matching voice path to wire the earpiece and mic to it. The HAL does that in
 * voice_extn_set_parameters() -> update_call_states() when it is handed
 * {@code vsid=<id>;call_state=<state>}, and NOTHING in AOSP ever sends that -- on a QTI device the
 * vendor IMS app does it, and on stock this was the OEM's own telephony framework, which a port
 * replaces with AOSP. Miss it and a call sets up perfectly, RTP flows, the call stays up, and you
 * hear silence in both directions: the only symptom is the absence of a voice-call usecase in the
 * HAL log while the audio mode is already MODE_IN_CALL.
 *
 * Values come from the audio HAL, not from a public API: VOICEMMODE1_VSID and CALL_INACTIVE/ACTIVE
 * in hardware/qcom-caf/<soc>/audio/hal (voice_extn.c, voice.h). The modem confirms which session
 * it picked -- MMPF logs {@code setAudioCalInfoParam[vsid=...]} -- so check that matches if audio is
 * ever silent again after a modem or HAL change.
 */
final class ModemVoiceSession {
    private static final String TAG = ImsBridgeService.TAG;

    /** VOICEMMODE1_VSID: the multi-mode session the modem uses for VoLTE. */
    private static final int VSID = 0x11C05000;
    /** voice.h: BASE_CALL_STATE is 1, CALL_ACTIVE is BASE + 1. */
    private static final int CALL_INACTIVE = 1;
    private static final int CALL_ACTIVE = 2;

    private static Context sContext;
    private static int sState = CALL_INACTIVE;

    private ModemVoiceSession() { }

    static void init(Context context) {
        sContext = context;
    }

    /** Call with true once a call session is established, false once it ends or fails to start. */
    static void setActive(boolean active) {
        final int state = active ? CALL_ACTIVE : CALL_INACTIVE;
        synchronized (ModemVoiceSession.class) {
            if (sState == state) return;
            sState = state;
        }
        final Context context = sContext;
        if (context == null) {
            Log.w(TAG, "modem voice session: no context yet, cannot set state " + state);
            return;
        }
        final AudioManager am = context.getSystemService(AudioManager.class);
        if (am == null) {
            Log.w(TAG, "modem voice session: no AudioManager");
            return;
        }
        // Decimal: the HAL reads both keys with str_parms_get_int, which parses base 10.
        final String params = "vsid=" + VSID + ";call_state=" + state;
        Log.i(TAG, "modem voice session -> " + params);
        am.setParameters(params);
    }
}
