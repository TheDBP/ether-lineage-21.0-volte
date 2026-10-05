package org.lineageos.ims.bridge;

import android.os.RemoteException;
import android.telephony.ims.stub.ImsEcbmImplBase;
import android.util.Log;

import @LEGACY_PKG@.internal.IImsEcbm;
import @LEGACY_PKG@.internal.IImsEcbmListener;

/**
 * Emergency callback mode.
 *
 * The listener is not plumbed through: ImsEcbmImplBase owns its own listener and exposes
 * enteredEcbm()/exitedEcbm() for the implementation to call. So the wrapper registers its own
 * adapter with the legacy service and turns those callbacks into the base's notifications.
 */
public class EcbmWrapper extends ImsEcbmImplBase {
    private static final String TAG = ImsBridgeService.TAG;

    private final IImsEcbm mLegacy;

    EcbmWrapper(IImsEcbm legacy) {
        mLegacy = legacy;
        try {
            mLegacy.setListener(new Adapter());
        } catch (RemoteException e) {
            Log.e(TAG, "ecbm setListener failed", e);
        }
    }

    @Override
    public void exitEmergencyCallbackMode() {
        try {
            mLegacy.exitEmergencyCallbackMode();
        } catch (RemoteException e) {
            Log.e(TAG, "exitEmergencyCallbackMode failed", e);
        }
    }

    private class Adapter extends IImsEcbmListener.Stub {
        @Override
        public void enteredECBM() {
            enteredEcbm();
        }

        @Override
        public void exitedECBM() {
            exitedEcbm();
        }
    }
}
