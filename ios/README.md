# Felicity for iOS

Native iPhone and iPad client for the Felicity energy and ONVIF camera system.

## Open and run

1. Open `FelicityDashboard.xcodeproj` in Xcode.
2. Select the `FelicityDashboard` target and open **Signing & Capabilities**.
3. Enable **Automatically manage signing** and choose your **Personal Team**.
4. Connect the iPad, trust the Mac, enable Developer Mode and press Run.

The default server is `http://homeassistant.local:8000`. Tap the yin-yang mark
to change it. The app requests local-network access on first connection.

Personal Team installs need renewal: Apple's free provisioning profiles expire
after seven days. Rebuild and install with the same team and bundle identifier
(`io.github.homedashboard.ios`) to preserve the existing app's data. Do not delete
the existing app to renew its signature. A network address alone is not enough:
the iPad must already be paired with Xcode, or first connected by USB and trusted.

## Dim clock and motion wake (0.4.16, build 20)

On the energy dashboard, one minute without detected activity shows only large
red time, date and household power consumption on black, at 4% display
brightness by default. The clock updates and shifts position once per minute;
household power refreshes every 30 seconds. A tap or camera movement wakes the
dashboard. Dashboard brightness follows the camera's light estimate, with a
manual adjustment and a 5–85% range; automatic changes occur at most once every
10 seconds.

Version 0.4.16 also switches to the clock when the camera's smoothed light estimate
stays below the darkness threshold for three seconds. Smoothing comes first,
so covering the camera should take roughly 5–10 seconds to show the clock; this
timing still needs confirmation on the physical iPad. The default threshold is 18%
on a relative camera scale, adjustable from 5–45%; it is not a lux measurement.
The quick transition triggers once per dark episode. After motion or a tap
wakes the dashboard, the usual inactivity timeout applies until the scene
becomes bright again. Hysteresis prevents repeated switching near the threshold.

Camera processing compares an 8 × 6 brightness grid about once a second.
Capture uses low resolution and a low supported frame rate. There is no face,
body or other object recognition. A person who remains still may let the clock
appear; this is a motion trigger, not room-occupancy detection.

In **Settings → Clock & presence**, change the timeout (30 seconds to 5 minutes),
clock brightness (1–20%), darkness threshold, motion sensitivity, and dashboard brightness
adjustment. Camera wake and automatic brightness can be disabled, and the clock
can be disabled or previewed.
The camera permission prompt explains its use. Only the front camera is used,
with no microphone, recording, or uploads. The system camera indicator is visible.
If camera access is denied or interrupted, touch wake remains available.

Felicity keeps the device awake only while this mode is enabled and the app is
in the foreground. Camera capture and idle clock pause in settings, camera/event
views and energy details. Original display brightness and idle-timer state are
restored when leaving the mode/app. Idle polling requests only current power;
summary/status requests are skipped. These changes reduce processing and
network work, but battery or wall-power savings have not been measured.

Version 0.4.15/19 replaced the global SwiftUI drag gesture with a passive
UIKit touch observer. That signed build passed 48 simulator tests; the user
confirmed touch controls and the red clock now work on the requested iPad Pro.
The signed 0.4.16/20 build passed 55 simulator tests and is now installed on the
same iPad. On 2026-11-14 the user confirmed that covering the camera shows the
red clock and movement returns the dashboard. An overnight run is planned;
long-term stability, day/night brightness and actual energy use remain unverified.
Darkness, a covered camera, reflections and moving objects can affect motion
detection. See [installation and validation](../docs/IOS_KIOSK_HANDOFF.md) for the
exact device and current validation status.

## Cameras, events and archive

Version 0.4 includes the native camera, 3ye event and Profile G archive slices:

- direct ONVIF discovery from the recorder;
- direct RTSP-over-TCP H.264/H.265 playback with Apple hardware decoding;
- a smooth static-preview camera wall with no background stream churn;
- native pinch, pan and double-tap reset;
- remembered LQ/HQ choice per camera;
- last-frame JPEG continuity while a stream reconnects or changes quality;
- a lightweight authenticated 3ye event wall with static thumbnails;
- camera/all-camera scope plus person, vehicle, animal and face filters; and
- event-to-archive navigation that opens paused on the nearest decodable frame;
- one persistent replay session with fast seek, play/pause and previous/next;
- an ONVIF Profile G activity timeline fetched through the recorder metadata
  track, with plain motion excluded and six seconds of context around AI activity;
- a real decoded-frame playhead, per-camera LQ/HQ and archive pinch-to-zoom;
- a 30-minute cross-camera investigation marker and persisted JPEG continuity;
- automatic IPv4 preference for `.local` Felicity hosts whose advertised IPv6
  address is unreachable.

Open **Settings → ONVIF recorder · Profile G**, enter the recorder address and its
ONVIF credentials, then tap **Discover cameras**. The camera button on the home
screen opens the selected camera; tap its name in Live to switch cameras. Open
**Events** from either the energy or Live header. Event images are fetched with
the 3ye credentials stored in Keychain; generic motion is deliberately excluded.
Passwords are stored in Keychain and are never written into the repository.

Audio follows as the next vertical slice on top of the contracts documented in
[`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) and the behavioural checklist in
[`Docs/PORTING_PLAN.md`](Docs/PORTING_PLAN.md).
