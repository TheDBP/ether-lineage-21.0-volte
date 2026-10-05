package org.lineageos.ims.bridge;

import android.os.RemoteException;
import android.telephony.ims.ImsExternalCallState;
import android.telephony.ims.stub.ImsMultiEndpointImplBase;
import android.util.Log;

import @LEGACY_PKG@.internal.IImsExternalCallStateListener;
import @LEGACY_PKG@.internal.IImsMultiEndpoint;

import java.util.ArrayList;
import java.util.List;

/**
 * Dialog-event package state, as above: the base owns the listener and takes updates through
 * onImsExternalCallStateUpdate(), so the wrapper registers with the legacy service and forwards.
 *
 * The legacy callback carries a raw List -- AIDL erases the element type -- so the contents are
 * checked rather than cast wholesale. 7.0's ImsExternalCallState and 17's are the same class from
 * the platform's point of view here, since this one was never part of the renamed set.
 */
public class MultiEndpointWrapper extends ImsMultiEndpointImplBase {
    private static final String TAG = ImsBridgeService.TAG;

    private final IImsMultiEndpoint mLegacy;

    MultiEndpointWrapper(IImsMultiEndpoint legacy) {
        mLegacy = legacy;
        try {
            mLegacy.setListener(new Adapter());
        } catch (RemoteException e) {
            Log.e(TAG, "multiendpoint setListener failed", e);
        }
    }

    @Override
    public void requestImsExternalCallStateInfo() {
        try {
            mLegacy.requestImsExternalCallStateInfo();
        } catch (RemoteException e) {
            Log.e(TAG, "requestImsExternalCallStateInfo failed", e);
        }
    }

    private class Adapter extends IImsExternalCallStateListener.Stub {
        @Override
        public void onImsExternalCallStateUpdate(List dialogs) {
            List<ImsExternalCallState> out = new ArrayList<>();
            if (dialogs != null) {
                for (Object o : dialogs) {
                    if (o instanceof ImsExternalCallState) {
                        out.add((ImsExternalCallState) o);
                    } else if (o != null) {
                        Log.w(TAG, "unexpected external call state entry: " + o.getClass());
                    }
                }
            }
            MultiEndpointWrapper.this.onImsExternalCallStateUpdate(out);
        }
    }
}
