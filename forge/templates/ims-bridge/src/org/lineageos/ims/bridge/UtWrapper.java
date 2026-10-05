package org.lineageos.ims.bridge;

import android.os.Bundle;
import android.os.RemoteException;
import android.telephony.ims.stub.ImsUtImplBase;
import android.util.Log;

import @LEGACY_PKG@.internal.IImsUt;

/**
 * Supplementary services (call barring, forwarding, waiting, CLIR/CLIP/COLR/COLP).
 *
 * Every legacy method has a same-named counterpart on ImsUtImplBase. The int each returns is a
 * request id the result arrives against on the listener, so returning -1 on a dead binder is the
 * documented failure value rather than an invented one.
 */
public class UtWrapper extends ImsUtImplBase {
    private static final String TAG = ImsBridgeService.TAG;

    private final IImsUt mLegacy;

    UtWrapper(IImsUt legacy) {
        mLegacy = legacy;
    }

    private int fail(String what, RemoteException e) {
        Log.e(TAG, "ut " + what + " failed", e);
        return -1;
    }

    @Override
    public void close() {
        try { mLegacy.close(); } catch (RemoteException e) { Log.e(TAG, "ut close failed", e); }
    }

    @Override
    public int queryCallBarring(int cbType) {
        try { return mLegacy.queryCallBarring(cbType); }
        catch (RemoteException e) { return fail("queryCallBarring", e); }
    }

    @Override
    public int queryCallForward(int condition, String number) {
        try { return mLegacy.queryCallForward(condition, number); }
        catch (RemoteException e) { return fail("queryCallForward", e); }
    }

    @Override
    public int queryCallWaiting() {
        try { return mLegacy.queryCallWaiting(); }
        catch (RemoteException e) { return fail("queryCallWaiting", e); }
    }

    @Override
    public int queryCLIR() {
        try { return mLegacy.queryCLIR(); } catch (RemoteException e) { return fail("queryCLIR", e); }
    }

    @Override
    public int queryCLIP() {
        try { return mLegacy.queryCLIP(); } catch (RemoteException e) { return fail("queryCLIP", e); }
    }

    @Override
    public int queryCOLR() {
        try { return mLegacy.queryCOLR(); } catch (RemoteException e) { return fail("queryCOLR", e); }
    }

    @Override
    public int queryCOLP() {
        try { return mLegacy.queryCOLP(); } catch (RemoteException e) { return fail("queryCOLP", e); }
    }

    @Override
    public int transact(Bundle ssInfo) {
        try { return mLegacy.transact(ssInfo); } catch (RemoteException e) { return fail("transact", e); }
    }

    @Override
    public int updateCallBarring(int cbType, int action, String[] barrList) {
        try { return mLegacy.updateCallBarring(cbType, action, barrList); }
        catch (RemoteException e) { return fail("updateCallBarring", e); }
    }

    @Override
    public int updateCallForward(int action, int condition, String number, int serviceClass,
            int timeSeconds) {
        try { return mLegacy.updateCallForward(action, condition, number, serviceClass, timeSeconds); }
        catch (RemoteException e) { return fail("updateCallForward", e); }
    }

    @Override
    public int updateCallWaiting(boolean enable, int serviceClass) {
        try { return mLegacy.updateCallWaiting(enable, serviceClass); }
        catch (RemoteException e) { return fail("updateCallWaiting", e); }
    }

    @Override
    public int updateCLIR(int clirMode) {
        try { return mLegacy.updateCLIR(clirMode); }
        catch (RemoteException e) { return fail("updateCLIR", e); }
    }

    @Override
    public int updateCLIP(boolean enable) {
        try { return mLegacy.updateCLIP(enable); }
        catch (RemoteException e) { return fail("updateCLIP", e); }
    }

    @Override
    public int updateCOLR(int presentation) {
        try { return mLegacy.updateCOLR(presentation); }
        catch (RemoteException e) { return fail("updateCOLR", e); }
    }

    @Override
    public int updateCOLP(boolean enable) {
        try { return mLegacy.updateCOLP(enable); }
        catch (RemoteException e) { return fail("updateCOLP", e); }
    }
}
