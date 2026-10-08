package org.lineageos.ims.bridge;

import android.app.PendingIntent;
import android.os.IBinder;
import android.os.Message;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.telephony.ims.ImsCallProfile;
import android.telephony.ims.compat.feature.ImsFeature;
import android.telephony.ims.compat.feature.MMTelFeature;
import android.telephony.ims.stub.ImsEcbmImplBase;
import android.telephony.ims.stub.ImsMultiEndpointImplBase;
import android.telephony.ims.stub.ImsUtImplBase;
import android.util.Log;

import com.android.ims.internal.IImsCallSession;
import com.android.ims.internal.IImsCallSessionListener;
import com.android.ims.internal.IImsConfig;
import com.android.ims.internal.IImsRegistrationListener;

import @LEGACY_PKG@.internal.IImsService;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Presents the OEM app's 7.0 IImsService (@LEGACY_PKG@.internal) to the platform as a modern
 * MMTelFeature.
 *
 * The shape difference this class exists to absorb: the legacy API is serviceId-keyed -- open()
 * hands back an int every later call must carry -- while a MMTelFeature instance already implies
 * one session. So the bridge holds the id and injects it. The 7.0 shape also has a single
 * registration listener slot (no addRegistrationListener), so one RegistrationListenerAdapter is
 * installed at open() and fans out to whatever the framework adds afterwards.
 *
 * @OEM_APP@ registers itself as "ims" with ServiceManager; it is not a bound service.
 *
 * Note that no MMTelFeature method declares RemoteException, while every legacy call throws it.
 *
 * Nothing here may throw. These methods run on a binder thread serving com.android.phone, and
 * binder marshals IllegalStateException and friends straight through to the caller --
 * ImsServiceControllerCompat does not catch RuntimeException, so an exception thrown out of this
 * class is a fatal crash in the framework's phone process. That process then restarts, ImsResolver
 * rebinds this service, the same call throws again, and the handset is unusable for as long as the
 * legacy service stays away. The API's own channel for "this feature is down" is the feature state,
 * so report it there and return something benign.
 */
public class LegacyMMTelFeature extends MMTelFeature {
    private static final String TAG = ImsBridgeService.TAG;

    /** 7.0 ImsServiceClass.MMTEL. */
    private static final int SERVICE_CLASS_MMTEL = 1;

    private static final int INVALID_SERVICE_ID = -1;

    private final int mSlotId;
    private int mServiceId = INVALID_SERVICE_ID;
    private final RegistrationListenerAdapter mRegistration = new RegistrationListenerAdapter();
    private final AtomicBoolean mAwaiting = new AtomicBoolean();

    LegacyMMTelFeature(int slotId) {
        mSlotId = slotId;
        setFeatureState(ImsFeature.STATE_INITIALIZING);
        awaitLegacyService();
    }

    /**
     * Publish STATE_READY once @OEM_APP@ has registered itself.
     *
     * This is the whole handshake and it is easy to get backwards: the framework will not call
     * startSession on a feature that has not reported READY, so a feature that only becomes READY
     * inside startSession never gets used at all -- ImsResolver binds it, onCreateMMTelImsFeature
     * runs, and then nothing happens, with no error logged anywhere.
     *
     * @OEM_APP@ registers "ims" with ServiceManager from its own onCreate in com.android.phone, while
     * the bridge is a separate process, so the two race. Wait for the service on a background thread
     * rather than blocking the binder thread that created the feature.
     */
    private void awaitLegacyService() {
        // @OEM_APP@ dying and being restarted re-runs this, so guard against stacking up waiters: the
        // wait is indefinite, and one failing call per second would otherwise be one thread per
        // second, all blocked on the same name.
        if (!mAwaiting.compareAndSet(false, true)) {
            return;
        }
        new Thread(() -> {
            try {
                IBinder b = ServiceManager.waitForService("ims");
                if (b == null) {
                    Log.e(TAG, "slot " + mSlotId
                            + ": ims service never appeared; feature stays down");
                    setFeatureState(ImsFeature.STATE_NOT_AVAILABLE);
                    return;
                }
                watchForDeath(b);
                Log.i(TAG, "slot " + mSlotId + ": legacy ims service present, feature READY");
                setFeatureState(ImsFeature.STATE_READY);
            } finally {
                mAwaiting.set(false);
            }
        }, "ImsBridge-await").start();
    }

    /**
     * @OEM_APP@ is a separate process and crashes on its own (a property it is not allowed to set is
     * enough). Without this the feature stays READY over a service that is gone, and every
     * framework call into it has to discover that the hard way.
     */
    private void watchForDeath(IBinder b) {
        try {
            b.linkToDeath(() -> {
                Log.w(TAG, "slot " + mSlotId + ": legacy ims service died");
                markDown("binderDied");
            }, 0);
        } catch (RemoteException e) {
            // Already dead between waitForService and here.
            markDown("linkToDeath");
        }
    }

    private IImsService legacyOrNull() {
        IBinder b = ServiceManager.getService("ims");
        if (b == null) {
            Log.w(TAG, "slot " + mSlotId + ": ims service not registered");
            return null;
        }
        return IImsService.Stub.asInterface(b);
    }

    /**
     * The legacy service for a call, or null if it is not there -- in which case the feature is
     * taken down and a waiter armed for its return.
     *
     * Only from READY: before that the constructor's waiter is still running and a missing service
     * is just the startup race, not a fault. Reporting NOT_AVAILABLE there would have the framework
     * give up on a feature that is seconds away from working.
     */
    private IImsService legacyOrDown(String what) {
        IImsService s = legacyOrNull();
        if (s == null && getFeatureState() == ImsFeature.STATE_READY) {
            markDown(what);
        }
        return s;
    }

    /** Report the feature down and wait for the legacy service to come back. */
    private void markDown(String what) {
        Log.w(TAG, "slot " + mSlotId + ": " + what
                + " with no legacy ims service; feature NOT_AVAILABLE");
        setFeatureState(ImsFeature.STATE_NOT_AVAILABLE);
        awaitLegacyService();
    }

    /**
     * A call that failed across the bridge. Logged and absorbed, never rethrown -- see the note on
     * the class. A RemoteException here is usually the service having died mid-transaction, so
     * treat it the same as finding it absent; if it is in fact alive, the waiter returns at once
     * and the feature is READY again.
     */
    private void failed(String what, RemoteException e) {
        Log.e(TAG, what + " failed across the bridge", e);
        markDown(what);
    }

    @Override
    public int startSession(PendingIntent incomingCallIntent, IImsRegistrationListener listener) {
        IImsService svc = legacyOrDown("startSession");
        if (svc == null) {
            return INVALID_SERVICE_ID;
        }
        try {
            mRegistration.add(listener);
            mServiceId = svc.open(mSlotId, SERVICE_CLASS_MMTEL, incomingCallIntent,
                    mRegistration);
            Log.i(TAG, "slot " + mSlotId + ": legacy session open, serviceId=" + mServiceId);
            // State is published by awaitLegacyService(); the framework only reaches this method
            // because the feature already reported READY.
            // Probe now in case @OEM_APP@ is already registered, and again if/when it becomes
            // registered: it registers tens of seconds after the framework opens the session, and
            // it only emits a feature bitmap on a UC state change, so the open()-time probe alone
            // always runs while registration is still disconnected and gives up.
            mRegistration.setOnConnected(this::probeFeatureBitmapIfMissing);
            probeFeatureBitmapIfMissing();
            return mServiceId;
        } catch (RemoteException e) {
            failed("startSession", e);
            return INVALID_SERVICE_ID;
        }
    }

    /**
     * @OEM_APP@ replays registrationConnected to a fresh listener (synchronously, from inside open())
     * but emits registrationFeatureCapabilityChanged only when its UC state later CHANGES. A bridge
     * that opens after registration already completed would therefore report "registered, voice
     * disabled" forever and every call would fall back to CS. Reconstruct the bitmap from
     * isConnected(), which reads the same UC state the bitmap is derived from: callType 2 = voice
     * over LTE, 4 = video. (Legacy 6-slot convention: slot i holds feature i or -1.)
     */
    private void probeFeatureBitmapIfMissing() {
        if (!mRegistration.isConnected() || mRegistration.hasFeatureBitmap()) {
            Log.i(TAG, "slot " + mSlotId + ": bitmap probe skipped (connected="
                    + mRegistration.isConnected() + " haveBitmap="
                    + mRegistration.hasFeatureBitmap() + ")");
            return;
        }
        IImsService s = legacyOrDown("probeFeatureBitmap");
        if (s == null) {
            return;
        }
        try {
            // isConnected(NORMAL, 0) is UCStateTracker.isRegistered(); isConnected(NORMAL, VOICE)
            // additionally demands isVoiceCallSupported() && isVoiceCallRegistered(), OEM
            // UC-layer flags fed by provisioning the stack will not let us write
            // (setProvisionedValue is refused). Those flags stay false while MMTEL is registered and
            // voice calls demonstrably work, so registration is the ground truth and the VOICE
            // probe is only an additional yes-vote, never a veto.
            boolean registered = s.isConnected(mServiceId, 1 /* SERVICE_TYPE_NORMAL */, 0);
            boolean voice = registered
                    || s.isConnected(mServiceId, 1, 2 /* CALL_TYPE_VOICE */);
            // Do not advertise video. the OEM app's VT needs the MMPF media path, whose modem-side
            // address query fails here (see IMS.md), so offering it would just produce calls that
            // cannot carry media. isConnected(NORMAL, 4) answers true regardless.
            boolean video = false;
            int[] enabled = {-1, -1, -1, -1, -1, -1};
            int[] disabled = {-1, -1, -1, -1, -1, -1};
            // The array is indexed BY legacy feature id and the value must equal the index;
            // MmTelFeatureCompatAdapter.convertCapabilities() reads enabledFeatures[i] == i and
            // treats -1 (FEATURE_TYPE_UNKNOWN) as disabled. 0 VOICE_OVER_LTE, 1 VOICE_OVER_WIFI,
            // 2 VIDEO_OVER_LTE, 3 VIDEO_OVER_WIFI, 4 UT_OVER_LTE, 5 UT_OVER_WIFI -- so video
            // belongs at 2, not 1. Only enabledFeatures is read; disabled is sent for symmetry.
            (voice ? enabled : disabled)[0] = 0;   // FEATURE_TYPE_VOICE_OVER_LTE
            (video ? enabled : disabled)[2] = 2;   // FEATURE_TYPE_VIDEO_OVER_LTE
            disabled[1] = 1;                       // no VoWiFi from @OEM_APP@ yet (registered over LTE)
            disabled[3] = 3;
            disabled[4] = 4;                       // UT goes over the Ut interface, not a feature
            disabled[5] = 5;
            Log.i(TAG, "slot " + mSlotId + ": synthesizing feature bitmap; registered="
                    + registered + " voice=" + voice + " video=" + video);
            mRegistration.registrationFeatureCapabilityChanged(SERVICE_CLASS_MMTEL, enabled,
                    disabled);
        } catch (RemoteException e) {
            Log.w(TAG, "feature bitmap probe failed", e);
        }
    }

    @Override
    public void endSession(int sessionId) {
        try {
            IImsService s = legacyOrNull();
            if (s != null) {
                s.close(sessionId);
            }
        } catch (RemoteException e) {
            Log.e(TAG, "endSession failed", e);
        } finally {
            mServiceId = INVALID_SERVICE_ID;
            setFeatureState(ImsFeature.STATE_NOT_AVAILABLE);
        }
    }

    @Override
    public boolean isConnected(int callSessionType, int callType) {
        if (mServiceId == INVALID_SERVICE_ID) return false;
        IImsService svc = legacyOrDown("isConnected");
        if (svc == null) {
            return false;
        }
        try {
            return svc.isConnected(mServiceId, callSessionType, callType);
        } catch (RemoteException e) {
            failed("isConnected", e);
            return false;
        }
    }

    @Override
    public boolean isOpened() {
        if (mServiceId == INVALID_SERVICE_ID) return false;
        IImsService svc = legacyOrDown("isOpened");
        if (svc == null) {
            return false;
        }
        try {
            return svc.isOpened(mServiceId);
        } catch (RemoteException e) {
            failed("isOpened", e);
            return false;
        }
    }

    @Override
    public void addRegistrationListener(IImsRegistrationListener listener) {
        // No legacy call: the one adapter handed to open() already receives everything, and it
        // replays the last state (including the feature bitmap) to this late joiner itself.
        mRegistration.add(listener);
    }

    @Override
    public void removeRegistrationListener(IImsRegistrationListener listener) {
        mRegistration.remove(listener);
    }

    @Override
    public ImsCallProfile createCallProfile(int sessionId, int callSessionType, int callType) {
        IImsService svc = legacyOrDown("createCallProfile");
        if (svc == null) {
            return null;
        }
        try {
            return Convert.toModern(
                    svc.createCallProfile(sessionId, callSessionType, callType));
        } catch (RemoteException e) {
            failed("createCallProfile", e);
            return null;
        }
    }

    @Override
    public void turnOnIms() {
        IImsService svc = legacyOrDown("turnOnIms");
        if (svc == null) {
            return;
        }
        try {
            svc.turnOnIms(mSlotId);
        } catch (RemoteException e) {
            failed("turnOnIms", e);
        }
    }

    @Override
    public void turnOffIms() {
        IImsService svc = legacyOrDown("turnOffIms");
        if (svc == null) {
            return;
        }
        try {
            svc.turnOffIms(mSlotId);
        } catch (RemoteException e) {
            failed("turnOffIms", e);
        }
    }

    @Override
    public void setUiTTYMode(int uiTtyMode, Message onComplete) {
        IImsService svc = legacyOrDown("setUiTTYMode");
        if (svc == null) {
            return;
        }
        try {
            svc.setUiTTYMode(mServiceId, uiTtyMode, onComplete);
        } catch (RemoteException e) {
            failed("setUiTTYMode", e);
        }
    }

    // --- Not yet bridged -------------------------------------------------------------------
    // Each returns or consumes a 7.0 sub-interface where the modern side wants the 17 interface of
    // the same name with a different method set, so each needs a wrapper -- and the corresponding
    // legacy .aidl filled in with its real method order first (see the note in those files).
    // Throwing is deliberate: returning null defers the failure to somewhere unrelated.

    @Override
    public IImsCallSession createCallSession(int sessionId, ImsCallProfile profile,
            IImsCallSessionListener listener) {
        IImsService svc = legacyOrDown("createCallSession");
        if (svc == null) {
            return null;
        }
        try {
            // The listener is attached to the wrapper, not passed down: 7.0 takes it at creation
            // while the modern side may also call setListener later, and routing both through the
            // one adapter keeps a single path back to the framework.
            @LEGACY_PKG@.internal.IImsCallSession s =
                    svc.createCallSession(sessionId, Convert.toLegacy(profile), null);
            if (s == null) {
                Log.w(TAG, "createCallSession returned null from the legacy service");
                return null;
            }
            CallSessionWrapper w = new CallSessionWrapper(s);
            if (listener != null) {
                w.setListener(listener);
            }
            return w;
        } catch (RemoteException e) {
            failed("createCallSession", e);
            return null;
        }
    }

    @Override
    public IImsCallSession getPendingCallSession(int sessionId, String callId) {
        IImsService svc = legacyOrDown("getPendingCallSession");
        if (svc == null) {
            return null;
        }
        try {
            @LEGACY_PKG@.internal.IImsCallSession s =
                    svc.getPendingCallSession(sessionId, callId);
            // Marked incoming: this is the only path an MT session arrives by, and the listener
            // adapter has to tell MT from MO to deliver a pre-answer hangup correctly.
            return s == null ? null : new CallSessionWrapper(s, true);
        } catch (RemoteException e) {
            failed("getPendingCallSession", e);
            return null;
        }
    }

    @Override
    public ImsUtImplBase getUtInterface() {
        IImsService svc = legacyOrDown("getUtInterface");
        if (svc == null) {
            return null;
        }
        try {
            @LEGACY_PKG@.internal.IImsUt u = svc.getUtInterface(mServiceId);
            return u == null ? null : new UtWrapper(u);
        } catch (RemoteException e) {
            failed("getUtInterface", e);
            return null;
        }
    }

    @Override
    public IImsConfig getConfigInterface() {
        IImsService svc = legacyOrDown("getConfigInterface");
        if (svc == null) {
            return null;
        }
        try {
            // Config is keyed by phone id on 7.0, not by the session's serviceId.
            @LEGACY_PKG@.internal.IImsConfig c = svc.getConfigInterface(mSlotId);
            return c == null ? null : new ConfigWrapper(c);
        } catch (RemoteException e) {
            failed("getConfigInterface", e);
            return null;
        }
    }

    @Override
    public ImsEcbmImplBase getEcbmInterface() {
        IImsService svc = legacyOrDown("getEcbmInterface");
        if (svc == null) {
            return null;
        }
        try {
            @LEGACY_PKG@.internal.IImsEcbm ecbm = svc.getEcbmInterface(mServiceId);
            return ecbm == null ? null : new EcbmWrapper(ecbm);
        } catch (RemoteException e) {
            failed("getEcbmInterface", e);
            return null;
        }
    }

    @Override
    public ImsMultiEndpointImplBase getMultiEndpointInterface() {
        IImsService svc = legacyOrDown("getMultiEndpointInterface");
        if (svc == null) {
            return null;
        }
        try {
            @LEGACY_PKG@.internal.IImsMultiEndpoint m =
                    svc.getMultiEndpointInterface(mServiceId);
            return m == null ? null : new MultiEndpointWrapper(m);
        } catch (RemoteException e) {
            failed("getMultiEndpointInterface", e);
            return null;
        }
    }
}
