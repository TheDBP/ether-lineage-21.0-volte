package org.lineageos.ims.bridge;

import android.os.Message;
import android.os.RemoteException;
import android.telephony.ims.ImsCallProfile;
import android.telephony.ims.ImsStreamMediaProfile;
import android.telephony.ims.compat.stub.ImsCallSessionImplBase;
import android.util.Log;

import com.android.ims.internal.IImsVideoCallProvider;

import @LEGACY_PKG@.internal.IImsCallSession;

/**
 * A 7.0 call session presented as a modern one.
 *
 * All 28 of the legacy interface's methods exist on ImsCallSessionImplBase with the same shape, so
 * this is delegation plus parcelable conversion. The base supplies no-op defaults for everything 17
 * added (RTT, transfer, call quality), which 7.0 has no notion of -- leaving those unimplemented is
 * the correct behaviour, not a gap.
 */
public class CallSessionWrapper extends ImsCallSessionImplBase {
    private static final String TAG = ImsBridgeService.TAG;

    private final IImsCallSession mLegacy;
    private final boolean mIncoming;

    CallSessionWrapper(IImsCallSession legacy) {
        this(legacy, false);
    }

    /** @param incoming true for a session adopted from an incoming call (MT), false for a dial. */
    CallSessionWrapper(IImsCallSession legacy, boolean incoming) {
        mLegacy = legacy;
        mIncoming = incoming;
    }

    IImsCallSession legacy() {
        return mLegacy;
    }

    /** MT or MO. The listener adapter needs this to route startFailed; see the note there. */
    boolean isIncoming() {
        return mIncoming;
    }

    /**
     * A failed call on the legacy session. Logged and absorbed, never rethrown: these run on a
     * binder thread serving com.android.phone, which does not catch RuntimeException from an
     * ImsService -- see the note on LegacyMMTelFeature. A RemoteException here means the OEM stack
     * went away mid-call, and the session is over either way; killing the phone process on top of
     * that turns a dropped call into an unusable handset.
     */
    private static void failed(String what, RemoteException e) {
        Log.e(TAG, "call session: " + what + " failed", e);
    }

    @Override
    public void setListener(com.android.ims.internal.IImsCallSessionListener listener) {
        try {
            mLegacy.setListener(
                    listener == null ? null : new CallSessionListenerAdapter(listener, this));
        } catch (RemoteException e) {
            failed("setListener", e);
        }
    }

    @Override
    public void close() {
        try { mLegacy.close(); } catch (RemoteException e) { failed("close", e); }
    }

    @Override
    public String getCallId() {
        try { return mLegacy.getCallId(); } catch (RemoteException e) { failed("getCallId", e); return null; }
    }

    @Override
    public ImsCallProfile getCallProfile() {
        try { return Convert.toModern(mLegacy.getCallProfile()); }
        catch (RemoteException e) { failed("getCallProfile", e); return null; }
    }

    @Override
    public ImsCallProfile getLocalCallProfile() {
        try { return Convert.toModern(mLegacy.getLocalCallProfile()); }
        catch (RemoteException e) { failed("getLocalCallProfile", e); return null; }
    }

    @Override
    public ImsCallProfile getRemoteCallProfile() {
        try { return Convert.toModern(mLegacy.getRemoteCallProfile()); }
        catch (RemoteException e) { failed("getRemoteCallProfile", e); return null; }
    }

    @Override
    public String getProperty(String name) {
        try { return mLegacy.getProperty(name); }
        catch (RemoteException e) { failed("getProperty", e); return null; }
    }

    @Override
    public int getState() {
        try { return mLegacy.getState(); } catch (RemoteException e) { failed("getState", e); return State.INVALID; }
    }

    @Override
    public boolean isInCall() {
        try { return mLegacy.isInCall(); } catch (RemoteException e) { failed("isInCall", e); return false; }
    }

    @Override
    public void setMute(boolean muted) {
        try { mLegacy.setMute(muted); } catch (RemoteException e) { failed("setMute", e); }
    }

    @Override
    public void start(String callee, ImsCallProfile profile) {
        try { mLegacy.start(callee, Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("start", e); }
    }

    @Override
    public void startConference(String[] participants, ImsCallProfile profile) {
        try { mLegacy.startConference(participants, Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("startConference", e); }
    }

    @Override
    public void accept(int callType, ImsStreamMediaProfile profile) {
        try { mLegacy.accept(callType, Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("accept", e); }
    }

    @Override
    public void reject(int reason) {
        try { mLegacy.reject(reason); } catch (RemoteException e) { failed("reject", e); }
    }

    @Override
    public void terminate(int reason) {
        try { mLegacy.terminate(reason); } catch (RemoteException e) { failed("terminate", e); }
    }

    @Override
    public void hold(ImsStreamMediaProfile profile) {
        try { mLegacy.hold(Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("hold", e); }
    }

    @Override
    public void resume(ImsStreamMediaProfile profile) {
        try { mLegacy.resume(Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("resume", e); }
    }

    @Override
    public void merge() {
        try { mLegacy.merge(); } catch (RemoteException e) { failed("merge", e); }
    }

    @Override
    public void update(int callType, ImsStreamMediaProfile profile) {
        try { mLegacy.update(callType, Convert.toLegacy(profile)); }
        catch (RemoteException e) { failed("update", e); }
    }

    @Override
    public void extendToConference(String[] participants) {
        try { mLegacy.extendToConference(participants); }
        catch (RemoteException e) { failed("extendToConference", e); }
    }

    @Override
    public void inviteParticipants(String[] participants) {
        try { mLegacy.inviteParticipants(participants); }
        catch (RemoteException e) { failed("inviteParticipants", e); }
    }

    @Override
    public void removeParticipants(String[] participants) {
        try { mLegacy.removeParticipants(participants); }
        catch (RemoteException e) { failed("removeParticipants", e); }
    }

    @Override
    public void sendDtmf(char c, Message result) {
        try { mLegacy.sendDtmf(c, result); } catch (RemoteException e) { failed("sendDtmf", e); }
    }

    @Override
    public void startDtmf(char c) {
        try { mLegacy.startDtmf(c); } catch (RemoteException e) { failed("startDtmf", e); }
    }

    @Override
    public void stopDtmf() {
        try { mLegacy.stopDtmf(); } catch (RemoteException e) { failed("stopDtmf", e); }
    }

    @Override
    public void sendUssd(String ussdMessage) {
        try { mLegacy.sendUssd(ussdMessage); } catch (RemoteException e) { failed("sendUssd", e); }
    }

    @Override
    public IImsVideoCallProvider getVideoCallProvider() {
        // The legacy provider is a different interface from 17's of the same name and would need its
        // own wrapper. Video calling is not reachable until VoLTE itself works, so returning null --
        // which the framework treats as "no video" -- is honest rather than deferred breakage.
        Log.d(TAG, "getVideoCallProvider: not bridged, reporting no video support");
        return null;
    }

    @Override
    public boolean isMultiparty() {
        try { return mLegacy.isMultiparty(); }
        catch (RemoteException e) { failed("isMultiparty", e); return false; }
    }
}
