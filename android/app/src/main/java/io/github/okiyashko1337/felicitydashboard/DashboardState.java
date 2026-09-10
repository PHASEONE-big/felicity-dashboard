package io.github.okiyashko1337.felicitydashboard;

import java.util.ArrayList;
import java.util.List;

final class DashboardState {
    double pv, pv1, pv2, mppt1, mppt2;
    double load, l1, l2, l3;
    double soc, batteryV, batteryW, bms1, bms2;
    double gridV1, gridV2, gridV3, gridW, frequency;
    double cpu, ram, temperature, disk;
    double todayPv, todayLoad, coverage, gridImport, gridExport;
    String version = "—";
    String serverUrl = "—";
    String onvifStatus = "Not configured";
    String networkRecoveryStatus = "OBSERVING";
    String networkRecoveryDetail = "No network events";
    final String[] networkDiagnostics = new String[8];
    long lastCurrentMs;
    long lastSummaryMs;
    boolean serverOnline;
    String error = "Waiting for data";
    double latitude = Double.NaN, longitude = Double.NaN;
    String location = "Locating…";
    double weatherTemperature;
    int weatherCode = -1;
    long weatherUpdatedMs;
    final String[] forecastDate = new String[7];
    final int[] forecastCode = new int[7];
    final double[] forecastMin = new double[7];
    final double[] forecastMax = new double[7];
    final List<float[]> chart = new ArrayList<>();
    int chartChannels;
    final ThreeEyeState threeEye = new ThreeEyeState();

    boolean live(long now) { return serverOnline && now - lastCurrentMs < 12_000; }
    boolean hasData() { return lastCurrentMs > 0; }
    boolean hasWeather() { return weatherUpdatedMs > 0; }
}
