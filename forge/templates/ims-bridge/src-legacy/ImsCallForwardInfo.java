package @LEGACY_PKG@;

import android.os.Parcel;
import android.os.Parcelable;

/**
 * The 7.0 com.android.ims.ImsCallForwardInfo, renamed.
 *
 * Wire order is NOT declaration order: condition, status, toA, number, timeSeconds, serviceClass.
 */
public class ImsCallForwardInfo implements Parcelable {
    public int mCondition;
    public int mStatus;
    public int mToA;
    public String mNumber;
    public int mTimeSeconds;
    public int mServiceClass;

    public ImsCallForwardInfo() { }

    private ImsCallForwardInfo(Parcel in) {
        mCondition = in.readInt();
        mStatus = in.readInt();
        mToA = in.readInt();
        mNumber = in.readString();
        mTimeSeconds = in.readInt();
        mServiceClass = in.readInt();
    }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mCondition);
        out.writeInt(mStatus);
        out.writeInt(mToA);
        out.writeString(mNumber);
        out.writeInt(mTimeSeconds);
        out.writeInt(mServiceClass);
    }

    public static final Creator<ImsCallForwardInfo> CREATOR = new Creator<ImsCallForwardInfo>() {
        @Override
        public ImsCallForwardInfo createFromParcel(Parcel in) { return new ImsCallForwardInfo(in); }
        @Override
        public ImsCallForwardInfo[] newArray(int size) { return new ImsCallForwardInfo[size]; }
    };
}
