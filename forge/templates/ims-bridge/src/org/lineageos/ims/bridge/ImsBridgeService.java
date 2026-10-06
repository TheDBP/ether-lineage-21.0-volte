package org.lineageos.ims.bridge;

import android.telephony.ims.compat.ImsService;
import android.telephony.ims.compat.feature.MMTelFeature;
import android.util.Log;

/**
 * Binds @OEM_APP@ -- the OEM's legacy IMS stack, built against the com.android.ims API Android 9 deleted -- to the modern
 * telephony framework, through the compat ImsService path that frameworks/opt/telephony still
 * carries (ImsServiceControllerCompat / MmTelFeatureCompatAdapter).
 *
 * For ImsResolver to bind this at all the device must also:
 *   - ship android.hardware.telephony.ims.prebuilt.xml, or PhoneGlobals never builds an
 *     ImsResolver in the first place, and
 *   - point config_ims_mmtel_package at this package.
 */
public class ImsBridgeService extends ImsService {
    static final String TAG = "ImsBridge";

    @Override
    public void onCreate() {
        super.onCreate();
        ModemVoiceSession.init(this);
    }

    @Override
    public MMTelFeature onCreateMMTelImsFeature(int slotId) {
        Log.i(TAG, "onCreateMMTelImsFeature slot=" + slotId);
        return new LegacyMMTelFeature(slotId);
    }

    @Override
    public MMTelFeature onCreateEmergencyMMTelImsFeature(int slotId) {
        Log.i(TAG, "onCreateEmergencyMMTelImsFeature slot=" + slotId);
        return new LegacyMMTelFeature(slotId);
    }
}
