package android.net;

import android.os.Handler;

/** Compile-only declarations for Android hidden tethering APIs. */
public class ConnectivityManager {
    public static abstract class OnStartTetheringCallback {
        public void onTetheringStarted() {}
        public void onTetheringFailed() {}
    }

    public void startTethering(
            int type,
            boolean showProvisioningUi,
            OnStartTetheringCallback callback,
            Handler handler) {}

    public void stopTethering(int type) {}

    public Network getActiveNetwork() { return null; }
    public Network[] getAllNetworks() { return new Network[0]; }
    public LinkProperties getLinkProperties(Network network) { return null; }
    public NetworkCapabilities getNetworkCapabilities(Network network) { return null; }
}
