package org.lineageos.ims.bridge;

import android.net.Uri;
import android.os.RemoteException;
import static android.telephony.ServiceState.RIL_RADIO_TECHNOLOGY_LTE;
import android.util.Log;

import @LEGACY_PKG@.ImsReasonInfo;
import @LEGACY_PKG@.internal.IImsRegistrationListener;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Presents the platform's modern registration listeners to @OEM_APP@ as ONE legacy listener.
 *
 * A 7.0-shape IImsService: open() takes a single listener and setRegistrationListener()
 * REPLACES it; there is no addRegistrationListener. The compat layer, however, adds two listeners
 * after startSession (MmTelFeatureCompatAdapter's own and ImsRegistrationCompatAdapter's), so this
 * adapter is installed once at open() and fans every callback out to all current targets.
 *
 * It also remembers the last state it saw and replays it to a listener added later. @OEM_APP@ replays
 * only connected/disconnected on setRegistrationListener, never the feature bitmap -- and
 * registrationFeatureCapabilityChanged is the callback that matters: MmTelFeatureCompatAdapter
 * turns it into MmTelCapabilities. Miss it and the framework sees "Voice: false", decides IMS
 * cannot carry a call, and routes to circuit-switched.
 *
 * All eleven 7.0 callbacks exist unchanged on 17 and forward directly.
 */
class RegistrationListenerAdapter extends IImsRegistrationListener.Stub {
    private static final String TAG = ImsBridgeService.TAG;

    private final List<com.android.ims.internal.IImsRegistrationListener> mTargets =
            new CopyOnWriteArrayList<>();

    // Last-known state for replay. 0 = nothing yet, 1 = progressing, 2 = connected,
    // 3 = disconnected.
    private int mRegState;
    private int mRadioTech = -1;          // -1: the tech-less variant was the last one fired
    private ImsReasonInfo mDisconnectReason;
    private int[] mEnabledFeatures;
    private int[] mDisabledFeatures;
    private Uri[] mUris;

    /**
     * Run when registration transitions to connected. The feature uses it to probe the capability
     * bitmap: @OEM_APP@ emits registrationFeatureCapabilityChanged only on a UC state CHANGE, and it
     * registers tens of seconds after the framework opens the session, so a probe done once at
     * open() time always runs too early and leaves the framework with an empty capability set.
     */
    private Runnable mOnConnected;

    void setOnConnected(Runnable r) { mOnConnected = r; }

    void add(com.android.ims.internal.IImsRegistrationListener target) {
        if (target == null || mTargets.contains(target)) return;
        mTargets.add(target);
        replay(target);
    }

    void remove(com.android.ims.internal.IImsRegistrationListener target) {
        mTargets.remove(target);
    }

    synchronized boolean isConnected() {
        return mRegState == 2;
    }

    synchronized boolean hasFeatureBitmap() {
        return mEnabledFeatures != null;
    }

    private synchronized void replay(com.android.ims.internal.IImsRegistrationListener t) {
        try {
            switch (mRegState) {
                case 1:
                    if (mRadioTech >= 0) t.registrationProgressingWithRadioTech(mRadioTech);
                    else t.registrationProgressing();
                    break;
                case 2:
                    if (mRadioTech >= 0) t.registrationConnectedWithRadioTech(mRadioTech);
                    else t.registrationConnected();
                    break;
                case 3:
                    t.registrationDisconnected(Convert.toModern(mDisconnectReason));
                    break;
                default:
                    return;
            }
            if (mEnabledFeatures != null) {
                t.registrationFeatureCapabilityChanged(1 /* MMTEL */, mEnabledFeatures,
                        mDisabledFeatures);
            }
            if (mUris != null) t.registrationAssociatedUriChanged(mUris);
            Log.i(TAG, "replayed registration state " + mRegState + " to a late listener");
        } catch (RemoteException e) {
            Log.w(TAG, "replay to a registration listener failed", e);
        }
    }

    private interface Call {
        void on(com.android.ims.internal.IImsRegistrationListener t) throws RemoteException;
    }

    private void fanOut(String what, Call c) {
        for (com.android.ims.internal.IImsRegistrationListener t : mTargets) {
            try {
                c.on(t);
            } catch (RemoteException e) {
                Log.w(TAG, what + ": a registration listener is gone, dropping it", e);
                mTargets.remove(t);
            }
        }
    }

    @Override
    public void registrationConnected() throws RemoteException {
        // Report LTE rather than passing the missing tech through. @OEM_APP@ says "connected" with no
        // radio tech, which ImsRegistrationCompatAdapter maps to REGISTRATION_TECH_NONE -- and
        // ImsPhoneCallTracker.isImsCapabilityInCacheAvailable() is
        // `getImsRegistrationTech() == regTech && mMmTelCapabilities.isCapable(cap)`, with
        // isVoiceOverCellularImsEnabled() only ever asking about REGISTRATION_TECH_LTE and _NR.
        // So a tech-less registration makes the dial gate false and every call falls back to CS
        // while IMS looks registered and VoLTE capability looks enabled. This stack only registers
        // MMTEL over LTE; a tech @OEM_APP@ does give us is passed through untouched below.
        registrationConnectedWithRadioTech(RIL_RADIO_TECHNOLOGY_LTE);
    }

    @Override
    public void registrationProgressing() throws RemoteException {
        synchronized (this) { mRegState = 1; mRadioTech = -1; }
        fanOut("registrationProgressing", t -> t.registrationProgressing());
    }

    @Override
    public void registrationConnectedWithRadioTech(int imsRadioTech) throws RemoteException {
        synchronized (this) { mRegState = 2; mRadioTech = imsRadioTech; }
        Log.i(TAG, "registrationConnected radioTech=" + imsRadioTech + " (RIL tech, "
                + RIL_RADIO_TECHNOLOGY_LTE + "=LTE) -> " + mTargets.size() + " listener(s)");
        fanOut("registrationConnectedWithRadioTech",
                t -> t.registrationConnectedWithRadioTech(imsRadioTech));
        Runnable r = mOnConnected;
        if (r != null) r.run();
    }

    @Override
    public void registrationProgressingWithRadioTech(int imsRadioTech) throws RemoteException {
        synchronized (this) { mRegState = 1; mRadioTech = imsRadioTech; }
        fanOut("registrationProgressingWithRadioTech",
                t -> t.registrationProgressingWithRadioTech(imsRadioTech));
    }

    @Override
    public void registrationDisconnected(ImsReasonInfo info) throws RemoteException {
        synchronized (this) { mRegState = 3; mDisconnectReason = info; }
        Log.i(TAG, "registrationDisconnected: " + info);
        android.telephony.ims.ImsReasonInfo modern = Convert.toModern(info);
        fanOut("registrationDisconnected", t -> t.registrationDisconnected(modern));
    }

    @Override
    public void registrationResumed() throws RemoteException {
        fanOut("registrationResumed", t -> t.registrationResumed());
    }

    @Override
    public void registrationSuspended() throws RemoteException {
        fanOut("registrationSuspended", t -> t.registrationSuspended());
    }

    @Override
    public void registrationServiceCapabilityChanged(int serviceClass, int event)
            throws RemoteException {
        fanOut("registrationServiceCapabilityChanged",
                t -> t.registrationServiceCapabilityChanged(serviceClass, event));
    }

    @Override
    public void registrationFeatureCapabilityChanged(int serviceClass,
            int[] enabledFeatures, int[] disabledFeatures) throws RemoteException {
        Log.i(TAG, "featureCapabilityChanged from @OEM_APP@: enabled="
                + java.util.Arrays.toString(enabledFeatures) + " disabled="
                + java.util.Arrays.toString(disabledFeatures));
        synchronized (this) { mEnabledFeatures = enabledFeatures; mDisabledFeatures = disabledFeatures; }
        fanOut("registrationFeatureCapabilityChanged", t -> t.registrationFeatureCapabilityChanged(
                serviceClass, enabledFeatures, disabledFeatures));
    }

    @Override
    public void voiceMessageCountUpdate(int count) throws RemoteException {
        fanOut("voiceMessageCountUpdate", t -> t.voiceMessageCountUpdate(count));
    }

    @Override
    public void registrationAssociatedUriChanged(Uri[] uris) throws RemoteException {
        synchronized (this) { mUris = uris; }
        fanOut("registrationAssociatedUriChanged", t -> t.registrationAssociatedUriChanged(uris));
    }
}
