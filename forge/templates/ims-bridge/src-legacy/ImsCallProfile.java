package @LEGACY_PKG@;

import android.os.Bundle;
import android.os.Parcel;
import android.os.Parcelable;

/**
 * The OEM's 7.x com.android.ims.ImsCallProfile, renamed. Wire order must match the stock framework's
 * writeToParcel exactly (read it from the deodexed smali): AOSP 7.x is serviceType, callType,
 * callExtras, mediaProfile. Some OEMs append fields -- LG appends restrictCause -- and a mismatch does
 * not throw, it shifts every later read by one. WIRE_HAS_RESTRICT_CAUSE is set by new-ims-bridge.sh.
 */
public class ImsCallProfile implements Parcelable {
    /** OEM wire extension: a trailing restrictCause int after mediaProfile (LG). */
    public static final boolean WIRE_HAS_RESTRICT_CAUSE = @RESTRICT_CAUSE@;

    public int mServiceType;
    public int mCallType;
    public int mRestrictCause;
    public Bundle mCallExtras;
    public ImsStreamMediaProfile mMediaProfile;

    public ImsCallProfile() {
        mCallExtras = new Bundle();
        mMediaProfile = new ImsStreamMediaProfile();
    }

    public ImsCallProfile(int serviceType, int callType) {
        mServiceType = serviceType;
        mCallType = callType;
        mCallExtras = new Bundle();
        mMediaProfile = new ImsStreamMediaProfile();
    }

    private ImsCallProfile(Parcel in) { readFromParcel(in); }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mServiceType);
        out.writeInt(mCallType);
        out.writeParcelable(mCallExtras, 0);
        out.writeParcelable(mMediaProfile, 0);
        if (WIRE_HAS_RESTRICT_CAUSE) out.writeInt(mRestrictCause);
    }

    private void readFromParcel(Parcel in) {
        mServiceType = in.readInt();
        mCallType = in.readInt();
        mCallExtras = in.readParcelable(Bundle.class.getClassLoader(), Bundle.class);
        mMediaProfile = in.readParcelable(
                ImsStreamMediaProfile.class.getClassLoader(), ImsStreamMediaProfile.class);
        if (WIRE_HAS_RESTRICT_CAUSE) mRestrictCause = in.readInt();
    }

    public static final Creator<ImsCallProfile> CREATOR = new Creator<ImsCallProfile>() {
        @Override
        public ImsCallProfile createFromParcel(Parcel in) { return new ImsCallProfile(in); }
        @Override
        public ImsCallProfile[] newArray(int size) { return new ImsCallProfile[size]; }
    };
}
