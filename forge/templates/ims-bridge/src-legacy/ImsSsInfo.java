package @LEGACY_PKG@;

import android.os.Parcel;
import android.os.Parcelable;

/** The 7.0 com.android.ims.ImsSsInfo, renamed. Wire order is mStatus then mIcbNum. */
public class ImsSsInfo implements Parcelable {
    public int mStatus;
    public String mIcbNum;

    public ImsSsInfo() { }

    private ImsSsInfo(Parcel in) {
        mStatus = in.readInt();
        mIcbNum = in.readString();
    }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mStatus);
        out.writeString(mIcbNum);
    }

    public static final Creator<ImsSsInfo> CREATOR = new Creator<ImsSsInfo>() {
        @Override
        public ImsSsInfo createFromParcel(Parcel in) { return new ImsSsInfo(in); }
        @Override
        public ImsSsInfo[] newArray(int size) { return new ImsSsInfo[size]; }
    };
}
