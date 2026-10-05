package @LEGACY_PKG@;

import android.os.Parcel;
import android.os.Parcelable;

/**
 * The 7.0 com.android.ims.ImsReasonInfo, renamed. Three instance fields; the other 88 members of
 * the original are constants and carry no wire presence. Order matches 7.0 writeToParcel exactly --
 * this has to marshal identically to the copy inside @OEM_APP@ or every call across the bridge
 * silently mis-reads.
 */
public class ImsReasonInfo implements Parcelable {
    public int mCode;
    public int mExtraCode;
    public String mExtraMessage;

    public ImsReasonInfo() { }

    public ImsReasonInfo(int code, int extraCode, String extraMessage) {
        mCode = code;
        mExtraCode = extraCode;
        mExtraMessage = extraMessage;
    }

    private ImsReasonInfo(Parcel in) { readFromParcel(in); }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mCode);
        out.writeInt(mExtraCode);
        out.writeString(mExtraMessage);
    }

    private void readFromParcel(Parcel in) {
        mCode = in.readInt();
        mExtraCode = in.readInt();
        mExtraMessage = in.readString();
    }

    public static final Creator<ImsReasonInfo> CREATOR = new Creator<ImsReasonInfo>() {
        @Override
        public ImsReasonInfo createFromParcel(Parcel in) { return new ImsReasonInfo(in); }
        @Override
        public ImsReasonInfo[] newArray(int size) { return new ImsReasonInfo[size]; }
    };
}
