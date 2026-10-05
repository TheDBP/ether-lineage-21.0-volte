package org.lineageos.ims.bridge;

/**
 * Parcelable conversion between the 7.0 types the @OEM_APP@ speaks and the modern ones the platform
 * expects. Every one of these is a handful of fields: the originals look enormous only because
 * ImsReasonInfo carries 88 constants alongside its 3 instance fields.
 */
public final class Convert {
    private Convert() { }

    public static android.telephony.ims.ImsReasonInfo toModern(
            @LEGACY_PKG@.ImsReasonInfo in) {
        if (in == null) return null;
        return new android.telephony.ims.ImsReasonInfo(in.mCode, in.mExtraCode, in.mExtraMessage);
    }

    public static @LEGACY_PKG@.ImsReasonInfo toLegacy(
            android.telephony.ims.ImsReasonInfo in) {
        if (in == null) return null;
        return new @LEGACY_PKG@.ImsReasonInfo(
                in.getCode(), in.getExtraCode(), in.getExtraMessage());
    }

    public static android.telephony.ims.ImsStreamMediaProfile toModern(
            @LEGACY_PKG@.ImsStreamMediaProfile in) {
        if (in == null) return null;
        return new android.telephony.ims.ImsStreamMediaProfile(
                in.mAudioQuality, in.mAudioDirection, in.mVideoQuality, in.mVideoDirection,
                android.telephony.ims.ImsStreamMediaProfile.RTT_MODE_DISABLED);
    }

    public static @LEGACY_PKG@.ImsStreamMediaProfile toLegacy(
            android.telephony.ims.ImsStreamMediaProfile in) {
        if (in == null) return null;
        @LEGACY_PKG@.ImsStreamMediaProfile out =
                new @LEGACY_PKG@.ImsStreamMediaProfile();
        out.mAudioQuality = in.getAudioQuality();
        out.mAudioDirection = in.getAudioDirection();
        out.mVideoQuality = in.getVideoQuality();
        out.mVideoDirection = in.getVideoDirection();
        return out;
    }

    public static android.telephony.ims.ImsCallProfile toModern(
            @LEGACY_PKG@.ImsCallProfile in) {
        if (in == null) return null;
        android.telephony.ims.ImsCallProfile out = new android.telephony.ims.ImsCallProfile(
                in.mServiceType, in.mCallType, in.mCallExtras, toModern(in.mMediaProfile));
        out.setCallRestrictCause(in.mRestrictCause);
        return out;
    }

    public static @LEGACY_PKG@.ImsCallProfile toLegacy(
            android.telephony.ims.ImsCallProfile in) {
        if (in == null) return null;
        @LEGACY_PKG@.ImsCallProfile out =
                new @LEGACY_PKG@.ImsCallProfile(
                        in.getServiceType(), in.getCallType());
        out.mCallExtras = in.getCallExtras();
        out.mMediaProfile = toLegacy(in.getMediaProfile());
        out.mRestrictCause = in.getRestrictCause();
        return out;
    }

    public static android.telephony.ims.ImsConferenceState toModern(
            @LEGACY_PKG@.ImsConferenceState in) {
        if (in == null) return null;
        android.telephony.ims.ImsConferenceState out =
                new android.telephony.ims.ImsConferenceState();
        out.mParticipants.putAll(in.mParticipants);
        return out;
    }

    public static android.telephony.ims.ImsSuppServiceNotification toModern(
            @LEGACY_PKG@.ImsSuppServiceNotification in) {
        if (in == null) return null;
        return new android.telephony.ims.ImsSuppServiceNotification(
                in.notificationType, in.code, in.index, in.type, in.number, in.history);
    }

    public static android.telephony.ims.ImsSsInfo toModern(
            @LEGACY_PKG@.ImsSsInfo in) {
        if (in == null) return null;
        return new android.telephony.ims.ImsSsInfo.Builder(in.mStatus)
                .setIncomingCommunicationBarringNumber(in.mIcbNum)
                .build();
    }

    public static android.telephony.ims.ImsCallForwardInfo toModern(
            @LEGACY_PKG@.ImsCallForwardInfo in) {
        if (in == null) return null;
        return new android.telephony.ims.ImsCallForwardInfo(
                in.mCondition, in.mStatus, in.mToA, in.mServiceClass, in.mNumber, in.mTimeSeconds);
    }
}
