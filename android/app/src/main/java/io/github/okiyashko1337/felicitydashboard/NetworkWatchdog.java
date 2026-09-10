package io.github.okiyashko1337.felicitydashboard;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.DhcpInfo;
import android.net.wifi.WifiManager;
import android.util.Log;
import java.io.FileOutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.net.URI;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

final class NetworkWatchdog {
    private static final String TAG = "FelicityWatchdog";
    private static final long CONFIRM_OUTAGE_AFTER_MS = 10 * 60_000L;

    private final Context context;
    private final DashboardState state;
    private final SharedPreferences preferences;
    private long outageStartedMs;
    private boolean confirmedOutageLogged;

    NetworkWatchdog(Context context, DashboardState state, SharedPreferences preferences) {
        this.context = context.getApplicationContext();
        this.state = state;
        this.preferences = preferences;
        refreshDiagnostic(System.currentTimeMillis(), "OBSERVING");
        loadLog();
        appendLog("Diagnostics started");
    }

    void check() {
        long now = System.currentTimeMillis();
        String backend = uriHost(state.serverUrl);
        String recorder = recorderHost(preferences.getString("profile_g_host", ""));
        String gateway = gatewayAddress();
        boolean backendUp = ping(backend);
        boolean recorderUp = ping(recorder);
        boolean gatewayUp = ping(gateway);

        if (backendUp || recorderUp || gatewayUp) {
            if (outageStartedMs > 0 && now - outageStartedMs >= 60_000L) {
                record("Network recovered after " + duration(now - outageStartedMs), now);
            }
            outageStartedMs = 0;
            confirmedOutageLogged = false;
            refreshDiagnostic(now, "ONLINE");
            return;
        }

        if (outageStartedMs == 0) {
            outageStartedMs = now;
            record("Full LAN outage detected", now);
        }
        long outageMs = now - outageStartedMs;
        if (outageMs < CONFIRM_OUTAGE_AFTER_MS) {
            state.networkRecoveryStatus = "OUTAGE " + duration(outageMs);
            state.networkRecoveryDetail = "Confirming for 10m";
            return;
        }
        state.networkRecoveryStatus = "OUTAGE CONFIRMED";
        state.networkRecoveryDetail = "Logged · manual reboot only";
        if (!confirmedOutageLogged) {
            confirmedOutageLogged = true;
            record("Full LAN outage confirmed after " + duration(outageMs), now);
        }
    }

    private void refreshDiagnostic(long now, String status) {
        state.networkRecoveryStatus = status;
        long eventMs = preferences.getLong("recovery_last_event_ms", 0);
        String event = preferences.getString("recovery_last_event", "No network events");
        state.networkRecoveryDetail = eventMs > 0 ? event + " · " + ago(now - eventMs) : event;
    }

    private void record(String event, long now) {
        preferences.edit().putString("recovery_last_event", event)
                .putLong("recovery_last_event_ms", now).apply();
        state.networkRecoveryDetail = event;
        appendLog(event);
        Log.w(TAG, event);
    }

    private void appendLog(String event) {
        String timestamp = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(new Date());
        String line = timestamp + " · " + event + "\n";
        try (FileOutputStream output = context.openFileOutput("network-diagnostics.log", Context.MODE_APPEND)) {
            output.write(line.getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) {
            Log.e(TAG, "Unable to persist diagnostics", error);
        }
        pushLine(line.trim());
    }

    private void loadLog() {
        try (BufferedReader input = new BufferedReader(new InputStreamReader(
                context.openFileInput("network-diagnostics.log"), StandardCharsets.UTF_8))) {
            String line;
            while ((line = input.readLine()) != null) pushLine(line);
        } catch (Exception ignored) {
        }
    }

    private void pushLine(String line) {
        synchronized (state.networkDiagnostics) {
            System.arraycopy(state.networkDiagnostics, 1, state.networkDiagnostics, 0,
                    state.networkDiagnostics.length - 1);
            state.networkDiagnostics[state.networkDiagnostics.length - 1] = line;
        }
    }

    private String gatewayAddress() {
        try {
            WifiManager wifi = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
            DhcpInfo info = wifi == null ? null : wifi.getDhcpInfo();
            int address = info == null ? 0 : info.gateway;
            if (address == 0) return null;
            return (address & 0xff) + "." + ((address >> 8) & 0xff) + "."
                    + ((address >> 16) & 0xff) + "." + ((address >> 24) & 0xff);
        } catch (RuntimeException ignored) {
            return null;
        }
    }

    private static String uriHost(String value) {
        try { return value == null ? null : URI.create(value).getHost(); }
        catch (RuntimeException ignored) { return null; }
    }

    private static String recorderHost(String value) {
        if (value == null || value.trim().isEmpty()) return null;
        try { return URI.create("http://" + value.trim()).getHost(); }
        catch (RuntimeException ignored) { return null; }
    }

    private static boolean ping(String host) {
        if (host == null || host.isEmpty()) return false;
        Process process = null;
        try {
            process = new ProcessBuilder("/system/bin/ping", "-c", "1", "-W", "2", host)
                    .redirectErrorStream(true).start();
            return process.waitFor(3, TimeUnit.SECONDS) && process.exitValue() == 0;
        } catch (Exception ignored) {
            return false;
        } finally {
            if (process != null) process.destroy();
        }
    }

    private static String duration(long millis) {
        long minutes = Math.max(0, millis / 60_000L);
        return minutes < 1 ? "<1m" : minutes + "m";
    }

    private static String ago(long millis) {
        if (millis < 60_000L) return "now";
        if (millis < 60 * 60_000L) return millis / 60_000L + "m ago";
        if (millis < 24 * 60 * 60_000L) return millis / (60 * 60_000L) + "h ago";
        return new SimpleDateFormat("dd MMM", Locale.US).format(new Date(System.currentTimeMillis() - millis));
    }
}
