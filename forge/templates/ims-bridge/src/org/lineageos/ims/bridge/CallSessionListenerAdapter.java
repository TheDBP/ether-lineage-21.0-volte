package org.lineageos.ims.bridge;

import android.os.RemoteException;
import android.util.Log;

import @LEGACY_PKG@.ImsCallProfile;
import @LEGACY_PKG@.ImsConferenceState;
import @LEGACY_PKG@.ImsReasonInfo;
import @LEGACY_PKG@.ImsStreamMediaProfile;
import @LEGACY_PKG@.ImsSuppServiceNotification;
import @LEGACY_PKG@.internal.IImsCallSession;
import @LEGACY_PKG@.internal.IImsCallSessionListener;

/**
 * Carries the OEM app's 7.0 call-session callbacks back to the modern listener.
 *
 * All 30 legacy callbacks exist on 17 with matching shape, so this is a straight forward plus
 * parcelable conversion. (17 adds six more -- RTT, transfer, call quality -- which 7.0 never emits.)
 *
 * The session argument needs care: every callback hands back a *legacy* session, and the modern
 * listener expects a modern one. For the session this adapter belongs to, the answer is the wrapper
 * we already built -- reusing it keeps object identity stable, which the telephony stack relies on
 * to match callbacks to calls. Only the genuinely new sessions handed over by merge and conference
 * extension get a fresh wrapper.
 */
class CallSessionListenerAdapter extends IImsCallSessionListener.Stub {
    private static final String TAG = ImsBridgeService.TAG;

    private final com.android.ims.internal.IImsCallSessionListener mTarget;
    private final CallSessionWrapper mOwner;

    CallSessionListenerAdapter(com.android.ims.internal.IImsCallSessionListener target,
            CallSessionWrapper owner) {
        mTarget = target;
        mOwner = owner;
    }

    /** The modern session for a legacy one: the owner if it matches, otherwise a new wrapper. */
    private com.android.ims.internal.IImsCallSession modern(IImsCallSession legacy) {
        if (legacy == null) return null;
        if (mOwner != null && mOwner.legacy() != null
                && mOwner.legacy().asBinder().equals(legacy.asBinder())) {
            return mOwner;
        }
        return new CallSessionWrapper(legacy);
    }

    @Override
    public void callSessionProgressing(IImsCallSession s, ImsStreamMediaProfile p)
            throws RemoteException {
        mTarget.callSessionProgressing(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionStarted(IImsCallSession s, ImsCallProfile p) throws RemoteException {
        mTarget.callSessionStarted(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionStartFailed(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionStartFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionTerminated(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionTerminated(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionHeld(IImsCallSession s, ImsCallProfile p) throws RemoteException {
        mTarget.callSessionHeld(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionHoldFailed(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionHoldFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionHoldReceived(IImsCallSession s, ImsCallProfile p) throws RemoteException {
        mTarget.callSessionHoldReceived(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionResumed(IImsCallSession s, ImsCallProfile p) throws RemoteException {
        mTarget.callSessionResumed(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionResumeFailed(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionResumeFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionResumeReceived(IImsCallSession s, ImsCallProfile p)
            throws RemoteException {
        mTarget.callSessionResumeReceived(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionMergeStarted(IImsCallSession s, IImsCallSession newSession,
            ImsCallProfile p) throws RemoteException {
        mTarget.callSessionMergeStarted(modern(s), modern(newSession), Convert.toModern(p));
    }

    @Override
    public void callSessionMergeComplete(IImsCallSession s) throws RemoteException {
        mTarget.callSessionMergeComplete(modern(s));
    }

    @Override
    public void callSessionMergeFailed(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionMergeFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionUpdated(IImsCallSession s, ImsCallProfile p) throws RemoteException {
        mTarget.callSessionUpdated(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionUpdateFailed(IImsCallSession s, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionUpdateFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionUpdateReceived(IImsCallSession s, ImsCallProfile p)
            throws RemoteException {
        mTarget.callSessionUpdateReceived(modern(s), Convert.toModern(p));
    }

    @Override
    public void callSessionConferenceExtended(IImsCallSession s, IImsCallSession newSession,
            ImsCallProfile p) throws RemoteException {
        mTarget.callSessionConferenceExtended(modern(s), modern(newSession), Convert.toModern(p));
    }

    @Override
    public void callSessionConferenceExtendFailed(IImsCallSession s, ImsReasonInfo r)
            throws RemoteException {
        mTarget.callSessionConferenceExtendFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionConferenceExtendReceived(IImsCallSession s, IImsCallSession newSession,
            ImsCallProfile p) throws RemoteException {
        mTarget.callSessionConferenceExtendReceived(
                modern(s), modern(newSession), Convert.toModern(p));
    }

    @Override
    public void callSessionInviteParticipantsRequestDelivered(IImsCallSession s)
            throws RemoteException {
        mTarget.callSessionInviteParticipantsRequestDelivered(modern(s));
    }

    @Override
    public void callSessionInviteParticipantsRequestFailed(IImsCallSession s, ImsReasonInfo r)
            throws RemoteException {
        mTarget.callSessionInviteParticipantsRequestFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionRemoveParticipantsRequestDelivered(IImsCallSession s)
            throws RemoteException {
        mTarget.callSessionRemoveParticipantsRequestDelivered(modern(s));
    }

    @Override
    public void callSessionRemoveParticipantsRequestFailed(IImsCallSession s, ImsReasonInfo r)
            throws RemoteException {
        mTarget.callSessionRemoveParticipantsRequestFailed(modern(s), Convert.toModern(r));
    }

    @Override
    public void callSessionConferenceStateUpdated(IImsCallSession s, ImsConferenceState state)
            throws RemoteException {
        mTarget.callSessionConferenceStateUpdated(modern(s), Convert.toModern(state));
    }

    @Override
    public void callSessionUssdMessageReceived(IImsCallSession s, int mode, String ussdMessage)
            throws RemoteException {
        mTarget.callSessionUssdMessageReceived(modern(s), mode, ussdMessage);
    }

    @Override
    public void callSessionHandover(IImsCallSession s, int srcAccessTech, int targetAccessTech,
            ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionHandover(modern(s), srcAccessTech, targetAccessTech, Convert.toModern(r));
    }

    @Override
    public void callSessionHandoverFailed(IImsCallSession s, int srcAccessTech,
            int targetAccessTech, ImsReasonInfo r) throws RemoteException {
        mTarget.callSessionHandoverFailed(
                modern(s), srcAccessTech, targetAccessTech, Convert.toModern(r));
    }

    @Override
    public void callSessionTtyModeReceived(IImsCallSession s, int mode) throws RemoteException {
        mTarget.callSessionTtyModeReceived(modern(s), mode);
    }

    @Override
    public void callSessionMultipartyStateChanged(IImsCallSession s, boolean isMultiparty)
            throws RemoteException {
        mTarget.callSessionMultipartyStateChanged(modern(s), isMultiparty);
    }

    @Override
    public void callSessionSuppServiceReceived(IImsCallSession s, ImsSuppServiceNotification n)
            throws RemoteException {
        mTarget.callSessionSuppServiceReceived(modern(s), Convert.toModern(n));
    }
}
