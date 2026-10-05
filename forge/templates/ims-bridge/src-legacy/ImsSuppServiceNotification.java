package @LEGACY_PKG@;

import android.os.Parcel;
import android.os.Parcelable;

/**
 * The 7.0 com.android.ims.ImsSuppServiceNotification, renamed.
 *
 * Wire order: notificationType, code, index, type, number, history.
 */
public class ImsSuppServiceNotification implements Parcelable {
    public int notificationType;
    public int code;
    public int index;
    public int type;
    public String number;
    public String[] history;

    public ImsSuppServiceNotification() { }

    private ImsSuppServiceNotification(Parcel in) {
        notificationType = in.readInt();
        code = in.readInt();
        index = in.readInt();
        type = in.readInt();
        number = in.readString();
        history = in.createStringArray();
    }

    @Override
    public int describeContents() { return 0; }

    @Override
    public void writeToParcel(Parcel out, int flags) {
        out.writeInt(notificationType);
        out.writeInt(code);
        out.writeInt(index);
        out.writeInt(type);
        out.writeString(number);
        out.writeStringArray(history);
    }

    public static final Creator<ImsSuppServiceNotification> CREATOR =
            new Creator<ImsSuppServiceNotification>() {
        @Override
        public ImsSuppServiceNotification createFromParcel(Parcel in) {
            return new ImsSuppServiceNotification(in);
        }
        @Override
        public ImsSuppServiceNotification[] newArray(int size) {
            return new ImsSuppServiceNotification[size];
        }
    };
}
