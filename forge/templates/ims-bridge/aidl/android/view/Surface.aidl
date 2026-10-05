package android.view;

/*
 * android.view.Surface is a framework parcelable with no .aidl of its own -- the platform resolves
 * it through framework.aidl's preprocessed parcelable list, which a device module does not get.
 * Declaring it here only tells aidl "this is a parcelable"; the real class still comes from the
 * framework at runtime.
 */
parcelable Surface;
