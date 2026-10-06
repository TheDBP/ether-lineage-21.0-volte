package org.lineageos.ims.bridge;

import android.os.RemoteException;
import android.os.SystemProperties;
import android.util.Log;

import java.util.concurrent.atomic.AtomicBoolean;

import @LEGACY_PKG@.ImsConfigListener;
import @LEGACY_PKG@.internal.IImsConfig;

/**
 * IMS provisioning. 17's IImsConfig is method-for-method what 7.0 had -- same nine, same order --
 * so this is pure delegation; only the listener needs adapting, and that is four callbacks that
 * also match.
 */
public class ConfigWrapper extends com.android.ims.internal.IImsConfig.Stub {
    private static final String TAG = ImsBridgeService.TAG;

    /** Read every item the vendor stack admits, once per process. See maybeProbe(). */
    private static final String PROBE_PROP = "persist.@DEVICE@.ims.configprobe";
    private static final AtomicBoolean sProbed = new AtomicBoolean();
    private static final int PROBE_ITEM_MAX = 70;
    /** The vendor types each item; asking for a string item as an int is refused, and vice versa. */
    private static final int[] PROBE_STRING_ITEMS = { 0, 1, 12, 31, 54 };

    private final IImsConfig mLegacy;

    ConfigWrapper(IImsConfig legacy) {
        mLegacy = legacy;
        maybeProbe();
    }

    /**
     * Ask the vendor stack for every provisioning item it might hold, and log what comes back.
     *
     * Its ImsConfigImpl validates the item against a fixed set and answers anything outside it with
     * "Invalid API request for item", and its legacy-to-proto translator throws outright for items
     * 17 and 28. So the accepted set is not the 7.0 header's set, and it cannot be guessed -- the
     * proto items for VoWiFi-enabled have no legacy number at all, while the ePDG timers and WLAN
     * handover thresholds do (legacy 60..64). Whether the modem holds usable values for those is
     * only visible by asking for them one at a time. A refusal is as informative as a value, so
     * both are logged verbatim rather than filtered.
     *
     * Off unless the property is set: this is one synchronous round trip to the modem per item.
     * getConfigInterface() is called more than once per boot, hence the latch.
     */
    private void maybeProbe() {
        if (!SystemProperties.getBoolean(PROBE_PROP, false)) {
            return;
        }
        if (!sProbed.compareAndSet(false, true)) {
            return;
        }
        // Its own thread. The vendor blocks on the modem with no timeout of its own, so one wedged
        // item must not take feature creation down with it.
        new Thread(() -> {
            for (int item = 0; item <= PROBE_ITEM_MAX; item++) {
                try {
                    Log.i(TAG, "configprobe int " + item + " = "
                            + mLegacy.getProvisionedValue(item));
                } catch (Exception e) {
                    Log.i(TAG, "configprobe int " + item + " threw " + e);
                }
            }
            for (int item : PROBE_STRING_ITEMS) {
                try {
                    Log.i(TAG, "configprobe str " + item + " = "
                            + mLegacy.getProvisionedStringValue(item));
                } catch (Exception e) {
                    Log.i(TAG, "configprobe str " + item + " threw " + e);
                }
            }
            Log.i(TAG, "configprobe done");
        }, "ims-configprobe").start();
    }

    @Override
    public int getProvisionedValue(int item) throws RemoteException {
        return mLegacy.getProvisionedValue(item);
    }

    @Override
    public String getProvisionedStringValue(int item) throws RemoteException {
        return mLegacy.getProvisionedStringValue(item);
    }

    @Override
    public int setProvisionedValue(int item, int value) throws RemoteException {
        int rc = mLegacy.setProvisionedValue(item, value);
        // 0 is SUCCESS; anything else is a refusal, and otherwise invisible -- the framework logs
        // that it made the call, not what came back, so a rejected item reads as a completed set.
        if (rc != 0) {
            Log.w(TAG, "setProvisionedValue(" + item + ", " + value + ") refused, rc=" + rc);
        }
        return rc;
    }

    @Override
    public int setProvisionedStringValue(int item, String value) throws RemoteException {
        return mLegacy.setProvisionedStringValue(item, value);
    }

    @Override
    public void getFeatureValue(int feature, int network,
            com.android.ims.ImsConfigListener listener) throws RemoteException {
        mLegacy.getFeatureValue(feature, network, wrap(listener));
    }

    @Override
    public void setFeatureValue(int feature, int network, int value,
            com.android.ims.ImsConfigListener listener) throws RemoteException {
        mLegacy.setFeatureValue(feature, network, value, wrap(listener));
        // @OEM_APP@ accepts the value but never calls the listener back, and the framework's
        // changeEnabledCapabilities() waits on a 2 s CountDownLatch per capability. One switch in
        // SIM settings pushes about ten capability changes, i.e. ~20 s of blocked binder threads --
        // enough to ANR Settings (seen 2026-10-05) and to collide with call setup. Acknowledge the
        // value we were asked to set, with the same feature/network or the framework discards it
        // as "response different than requested" and waits out the latch anyway.
        //
        // This does not fake a capability: what decides whether a call may use IMS is the
        // registration feature bitmap, and @OEM_APP@ keeps its own feature state regardless of this
        // call. If @OEM_APP@ ever does answer, the latch is already released and the late callback is
        // a no-op.
        if (listener != null) {
            try {
                listener.onSetFeatureResponse(feature, network, value,
                        com.android.ims.ImsConfig.OperationStatusConstants.SUCCESS);
            } catch (RemoteException e) {
                Log.w(TAG, "synthesized setFeatureValue ack failed", e);
            }
        }
    }

    @Override
    public boolean getVolteProvisioned() throws RemoteException {
        return mLegacy.getVolteProvisioned();
    }

    @Override
    public void getVideoQuality(com.android.ims.ImsConfigListener listener)
            throws RemoteException {
        mLegacy.getVideoQuality(wrap(listener));
    }

    @Override
    public void setVideoQuality(int quality, com.android.ims.ImsConfigListener listener)
            throws RemoteException {
        mLegacy.setVideoQuality(quality, wrap(listener));
    }

    private static ImsConfigListener wrap(com.android.ims.ImsConfigListener l) {
        return l == null ? null : new ListenerAdapter(l);
    }

    private static class ListenerAdapter extends ImsConfigListener.Stub {
        private final com.android.ims.ImsConfigListener mTarget;

        ListenerAdapter(com.android.ims.ImsConfigListener target) {
            mTarget = target;
        }

        @Override
        public void onGetFeatureResponse(int feature, int network, int value, int status)
                throws RemoteException {
            mTarget.onGetFeatureResponse(feature, network, value, status);
        }

        @Override
        public void onSetFeatureResponse(int feature, int network, int value, int status)
                throws RemoteException {
            mTarget.onSetFeatureResponse(feature, network, value, status);
        }

        @Override
        public void onGetVideoQuality(int status, int quality) throws RemoteException {
            mTarget.onGetVideoQuality(status, quality);
        }

        @Override
        public void onSetVideoQuality(int status) throws RemoteException {
            mTarget.onSetVideoQuality(status);
        }
    }
}
