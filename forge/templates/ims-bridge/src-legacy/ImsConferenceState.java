package @LEGACY_PKG@;

import android.os.Bundle;
import android.os.Parcel;
import android.os.Parcelable;

import java.util.HashMap;
import java.util.Map;

/**
 * The 7.0 com.android.ims.ImsConferenceState, renamed.
 *
 * One field, but not a flat one: the map is written as a size followed by key/value pairs, each a
 * String and a Parcelable Bundle. Anything else on the wire desynchronises the read.
 */
public class ImsConferenceState implements Parcelable {
    public HashMap<String, Bundle> mParticipants = new HashMap<String, Bundle>();

    public ImsConferenceState() { }

    private ImsConferenceState(Parcel in) {
        int size = in.readInt();
        mParticipants = new HashMap<String, Bundle>();
        for (int i = 0; i < size; i++) {
            String key = in.readString();
            Bundle value = in.readParcelable(Bundle.class.getClassLoader(), Bundle.class);
            mParticipants.put(key, value);
        }
    }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(mParticipants.size());
        for (Map.Entry<String, Bundle> e : mParticipants.entrySet()) {
            out.writeString(e.getKey());
            out.writeParcelable(e.getValue(), 0);
        }
    }

    public static final Creator<ImsConferenceState> CREATOR = new Creator<ImsConferenceState>() {
        @Override
        public ImsConferenceState createFromParcel(Parcel in) { return new ImsConferenceState(in); }
        @Override
        public ImsConferenceState[] newArray(int size) { return new ImsConferenceState[size]; }
    };
}
