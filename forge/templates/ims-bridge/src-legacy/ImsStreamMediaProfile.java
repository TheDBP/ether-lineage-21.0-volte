package @LEGACY_PKG@;

import android.os.Parcel;
import android.os.Parcelable;

/** The 7.0 com.android.ims.ImsStreamMediaProfile, renamed. Four ints, in 7.0's order. */
public class ImsStreamMediaProfile implements Parcelable {
    public int mAudioQuality;
    public int mAudioDirection;
    public int mVideoQuality;
    public int mVideoDirection;

    public ImsStreamMediaProfile() { }

    private ImsStreamMediaProfile(Parcel in) { readFromParcel(in); }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mAudioQuality);
        out.writeInt(mAudioDirection);
        out.writeInt(mVideoQuality);
        out.writeInt(mVideoDirection);
    }

    private void readFromParcel(Parcel in) {
        mAudioQuality = in.readInt();
        mAudioDirection = in.readInt();
        mVideoQuality = in.readInt();
        mVideoDirection = in.readInt();
    }

    public static final Creator<ImsStreamMediaProfile> CREATOR = new Creator<ImsStreamMediaProfile>() {
        @Override
        public ImsStreamMediaProfile createFromParcel(Parcel in) { return new ImsStreamMediaProfile(in); }
        @Override
        public ImsStreamMediaProfile[] newArray(int size) { return new ImsStreamMediaProfile[size]; }
    };
}
