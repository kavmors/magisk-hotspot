import android.content.Context;
import android.net.ConnectivityManager;
import android.os.Build;
import android.os.Looper;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.BitSet;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Small app_process entry point for Android's privileged tethering APIs. */
public final class HotspotCtl {
    private static final int TETHERING_WIFI = 0;
    private static final int BAND_2GHZ = 1;
    private static final int BAND_5GHZ = 2;
    private static final int BAND_ANY = 7;
    private static final int SECURITY_TYPE_OPEN = 0;
    private static final int SECURITY_TYPE_WPA2_PSK = 1;

    private HotspotCtl() {}

    public static void main(String[] args) {
        try {
            exemptHiddenApis();
            Context context = getSystemContext();
            if (args.length == 0) usage();

            switch (args[0]) {
                case "configure":
                    if (args.length != 4) usage();
                    configure(context, args[1], args[2], parseBand(args[3]));
                    System.out.println("configuration saved");
                    System.exit(0);
                    return;
                case "start":
                    start(context);
                    System.exit(0);
                    return;
                case "stop":
                    stop(context);
                    System.exit(0);
                    return;
                case "dns-server":
                    if (args.length != 4) usage();
                    int port = Integer.parseInt(args[3]);
                    if (port < 1 || port > 65535) {
                        throw new IllegalArgumentException("invalid DNS port: " + port);
                    }
                    new DnsServer(context, args[1], args[2], port).serve();
                    return;
                default:
                    usage();
            }
        } catch (Throwable error) {
            error.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void usage() {
        throw new IllegalArgumentException(
                "usage: HotspotCtl configure <ssid> <password> <2|5|any> | start | stop"
                        + " | dns-server <address> <domain> <port>");
    }

    private static Context getSystemContext() throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepareMainLooper();
        }
        Class<?> activityThreadClass = Class.forName("android.app.ActivityThread");
        Object activityThread = activityThreadClass.getMethod("systemMain").invoke(null);
        Method getSystemContext = activityThreadClass.getMethod("getSystemContext");
        return (Context) getSystemContext.invoke(activityThread);
    }

    private static void exemptHiddenApis() {
        try {
            Class<?> vmRuntimeClass = Class.forName("dalvik.system.VMRuntime");
            Object runtime = vmRuntimeClass.getDeclaredMethod("getRuntime").invoke(null);
            Method method = vmRuntimeClass.getDeclaredMethod(
                    "setHiddenApiExemptions", String[].class);
            method.invoke(runtime, (Object) new String[] {"L"});
        } catch (Throwable ignored) {
            // Android versions without hidden-API enforcement do not expose this method.
        }
    }

    private static int parseBand(String value) {
        switch (value) {
            case "2": return BAND_2GHZ;
            case "5": return BAND_5GHZ;
            case "any": return BAND_ANY;
            default: throw new IllegalArgumentException("invalid band: " + value);
        }
    }

    private static void configure(Context context, String ssid, String password, int band)
            throws Exception {
        Object wifiManager = context.getSystemService(Context.WIFI_SERVICE);
        if (wifiManager == null) throw new IllegalStateException("Wi-Fi service unavailable");

        boolean saved;
        if (Build.VERSION.SDK_INT >= 30) {
            saved = configureModern(wifiManager, ssid, password, band);
        } else {
            saved = configureAndroid10(wifiManager, ssid, password, band);
        }
        if (!saved) throw new IllegalStateException("Android rejected the hotspot configuration");
    }

    private static boolean configureModern(
            Object wifiManager, String ssid, String password, int band) throws Exception {
        Class<?> builderClass = Class.forName("android.net.wifi.SoftApConfiguration$Builder");
        Object builder = builderClass.getConstructor().newInstance();
        builderClass.getMethod("setSsid", String.class).invoke(builder, ssid);
        if (password.isEmpty()) {
            builderClass.getMethod("setPassphrase", String.class, int.class)
                    .invoke(builder, null, SECURITY_TYPE_OPEN);
        } else {
            builderClass.getMethod("setPassphrase", String.class, int.class)
                    .invoke(builder, password, SECURITY_TYPE_WPA2_PSK);
        }
        builderClass.getMethod("setBand", int.class).invoke(builder, band);
        Object config = builderClass.getMethod("build").invoke(builder);
        Object result = invokeCompatible(wifiManager, "setSoftApConfiguration", config);
        return !(result instanceof Boolean) || (Boolean) result;
    }

    private static boolean configureAndroid10(
            Object wifiManager, String ssid, String password, int band) throws Exception {
        Class<?> configClass = Class.forName("android.net.wifi.WifiConfiguration");
        Object config = configClass.getConstructor().newInstance();
        setField(configClass, config, "SSID", ssid);
        BitSet keyManagement = (BitSet) configClass.getField("allowedKeyManagement").get(config);
        keyManagement.clear();
        if (password.isEmpty()) {
            setField(configClass, config, "preSharedKey", null);
            keyManagement.set(0); // WifiConfiguration.KeyMgmt.NONE
        } else {
            setField(configClass, config, "preSharedKey", password);
            keyManagement.set(4); // WifiConfiguration.KeyMgmt.WPA2_PSK
        }

        int legacyBand = band == BAND_2GHZ ? 0 : band == BAND_5GHZ ? 1 : -1;
        setField(configClass, config, "apBand", legacyBand);
        Object result = invokeCompatible(wifiManager, "setWifiApConfiguration", config);
        return !(result instanceof Boolean) || (Boolean) result;
    }

    private static void setField(Class<?> owner, Object target, String name, Object value)
            throws Exception {
        Field field = owner.getField(name);
        field.set(target, value);
    }

    private static Object invokeCompatible(Object target, String name, Object argument)
            throws Exception {
        for (Method method : target.getClass().getMethods()) {
            Class<?>[] parameters = method.getParameterTypes();
            if (method.getName().equals(name) && parameters.length == 1
                    && parameters[0].isAssignableFrom(argument.getClass())) {
                return method.invoke(target, argument);
            }
        }
        throw new NoSuchMethodException(name);
    }

    private static void start(Context context) throws Exception {
        ConnectivityManager connectivity =
                (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivity == null) {
            throw new IllegalStateException("connectivity service unavailable");
        }

        CountDownLatch result = new CountDownLatch(1);
        boolean[] started = new boolean[1];
        ConnectivityManager.OnStartTetheringCallback callback =
                new ConnectivityManager.OnStartTetheringCallback() {
                    @Override
                    public void onTetheringStarted() {
                        started[0] = true;
                        result.countDown();
                    }

                    @Override
                    public void onTetheringFailed() {
                        result.countDown();
                    }
                };

        connectivity.startTethering(
                TETHERING_WIFI, false, callback, null);
        if (!result.await(20, TimeUnit.SECONDS)) {
            throw new IllegalStateException("timed out waiting for tethering service");
        }
        if (!started[0]) throw new IllegalStateException("tethering service reported failure");
        System.out.println("tethering started");
    }

    private static void stop(Context context) {
        ConnectivityManager connectivity =
                (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivity != null) connectivity.stopTethering(TETHERING_WIFI);
        System.out.println("tethering stopped");
    }
}
