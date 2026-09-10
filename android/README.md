# Felicity Android kiosk

Native Android client for the Felicity Dashboard LAN API. It is an alternative
to the ESP32 + Nextion monitor: both clients use the same `/api/device/*`
endpoints, but the Android version runs directly on an Echo Show 5 or another
dedicated landscape display.

The reference device is an Echo Show 5 (2nd generation, `cronos`) running
Android 11 at 960×480. The app has no Google Services, WebView, Home Assistant
token, or third-party Android library dependency.

## Features

- six live Solar, Home Load, Battery, Grid, System, and Today cards;
- detail pages with labelled time and value axes;
- current conditions and a seven-day Open-Meteo forecast;
- Android device location with a saved city override when a provider is
  unavailable;
- visible and media-volume-controlled click feedback for active touch targets;
- retained last telemetry while the server reconnects;
- landscape immersive mode, keep-screen-on, boot receiver, and optional HOME
  launcher role;
- on-device Settings page for API address, weather city, refresh intervals,
  kiosk state, device uptime, and client/server versions;
- automatic red-only night rendering at 1 lux or below, with 18% display
  brightness and a 4-lux return threshold to prevent flicker;
- ONVIF ring detection, live H.264 video, caller snapshot, 60-second
  automatic return, pinch/pan/double-tap zoom, and stream statistics;
- verified incoming ONVIF G.722 audio with privacy-safe speaker control.

Tap the yin-yang mark on the home page to open Settings. It is deliberately
inactive on detail pages. Tap the weather item in the header for the forecast.

## Server setup

The Android device must reach the Felicity HTTP port on the trusted LAN. For
the Home Assistant app, map TCP port `8000` in its network configuration. Do
not forward this port on the Internet: the compact device API is intentionally
unauthenticated for local displays.

The initial address is `http://homeassistant.local:8000`. Open Settings and
replace it with the Home Assistant IP when mDNS is not available.

## Build

Install Android SDK 32 and a Java 11+ runtime, then run:

```sh
cd android
./gradlew :app:assembleDebug
```

The APK is written to `app/build/outputs/apk/debug/app-debug.apk`.

## Install and kiosk mode

With network ADB enabled on the Android display:

```sh
adb connect DISPLAY_IP:5555
adb -s DISPLAY_IP:5555 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s DISPLAY_IP:5555 shell cmd package set-home-activity \
  io.github.okiyashko1337.felicitydashboard/.MainActivity
adb -s DISPLAY_IP:5555 shell locksettings set-disabled true
```

The first device command makes Felicity Dashboard the HOME app. The second
disables the non-secure swipe lock screen on a dedicated kiosk, preventing it
from covering the dashboard after a cold boot. Do not disable a PIN, password,
or pattern on a general-purpose device. The app also requests dismissal of a
non-secure keyguard and contains a `BOOT_COMPLETED` receiver.

Location permission is used only to choose forecast coordinates. If the device
has no functional fused/network location backend, open Settings, tap **Weather
location**, and enter its city once. The resulting coordinates are stored in
the app's private preferences.

## Refresh schedule

- `/api/device/current`: 2 seconds;
- `/api/status`: 5 seconds;
- `/api/device/summary`: 10 seconds;
- System chart: 10 seconds while visible;
- daily charts: immediately on entry, then 60 seconds while visible;
- Open-Meteo forecast: 15 minutes.

The server caches `/api/device/summary` for ten seconds, allowing Android and
Nextion displays to refresh together without repeating the daily aggregation.

## Network diagnostics

The kiosk passively checks the local gateway, Felicity backend, and configured
ONVIF recorder every 30 seconds. It records only state transitions: the start of a
full LAN outage, confirmation after ten minutes, and recovery. It never toggles
Wi-Fi or reboots the device. The latest event is visible in Settings. Tap the
**Network** card to read the last eight events directly on the display. The
complete persistent log can also be collected over ADB:

```sh
adb -s DISPLAY_IP:5555 shell run-as io.github.okiyashko1337.felicitydashboard \
  cat files/network-diagnostics.log
```

## ONVIF doorbell integration

Open Settings and configure the ONVIF Profile G recorder and credentials. Credentials
remain in Android private preferences. The home activity listens for
`RingDetector` events; a ring opens the camera, captures one caller snapshot,
and returns to the energy dashboard after 60 seconds. The camera tile also
opens the same view manually.

Video uses direct RTSP/TCP through LibVLC. The ONVIF receive-only audio track is
G.722 on `trackID=2`. Android LibVLC 3.5.1 exposes that track as an unidentified
codec, so the app receives the ordered RTP stream separately, decodes the
original G.722 payload locally, and writes 16 kHz mono PCM to Android
`AudioTrack`. This path was physically verified on the reference Echo Show 5.

The speaker and microphone controls remain visible in the camera header.
Speaker mute also disables the microphone; enabling the microphone enables
listening. Outgoing ONVIF backchannel code is experimental: no sound has yet
been heard at the ONVIF doorbell, so two-way audio must not be considered
complete. See [ONVIF_AUDIO_PLAN.md](ONVIF_AUDIO_PLAN.md) for protocol details and
remaining acceptance work.

Avoid verbose RTSP logs in production because authenticated media URLs can
contain credentials.

## Ambient red night mode

The app uses the device light sensor when available. It enters a red-only
palette at 1 lux or below and holds the state until illumination reaches 4
lux. This hysteresis prevents rapid switching near the threshold. Night mode
applies to every dashboard page, graphs, weather icons, the camera preview,
and camera controls. Display brightness is fixed at 18% in night mode and
returns to the system setting during the day.

## Operational checks

- Confirm cold boot returns directly to the dashboard when it is the HOME app.
- Verify normal and red themes by crossing both light thresholds.
- Confirm incoming doorbell audio, speaker mute, ring-only camera activation,
  caller snapshot, and automatic return after one minute.
- Test network interruption and repeated camera opens for resource cleanup.
