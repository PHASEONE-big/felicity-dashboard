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

## Latest status — 2026-11-16

Current source and confirmed installation are **0.4.21, build 25**, adding city
weather to the dashboard and idle clock plus a full-screen hourly/seven-day
forecast. The final signed build,
all **151 native simulator tests**, simulator UI checks and a live public-city
API check passed. Direct Wi-Fi installation on the exact requested iPad reached
100%, and device lookup verified the installed version. The physical iPad's city
is not yet selected; physical weather checks remain pending. See the
[weather handoff](../docs/IOS_WEATHER_HANDOFF.md).

The preceding **0.4.20, build 24** release combined all Solar
series in one chart and all Today series in one chart. Its signed
native build and all **125 simulator tests passed**. Wi-Fi installation on the
exact requested iPad succeeded, with its installed version verified afterward.
Physical feedback on the combined charts has not yet been collected.
The user chose to check the real ring/snapshot and two-way audio later; those
physical behaviors remain unverified.
See the [doorbell handoff](../docs/IOS_DOORBELL_HANDOFF.md).

Version 0.4.18 passed its signed build and 81 simulator tests, was installed and
version-verified over Wi-Fi, and received physical confirmation of improved
portrait readability, working point inspection and smooth vertical scrolling.
See the [charts handoff](../docs/IOS_CHARTS_HANDOFF.md).

For the earlier **0.4.17, build 21** release, the signed
build and 62 simulator tests passed; USB installation and a subsequent Wi-Fi
reinstall succeeded on the exact requested iPad. The user confirmed the white
daytime clock and sufficient dashboard brightness on wake. See the
[Wi-Fi installation path](../docs/IOS_KIOSK_HANDOFF.md#verified-wi-fi-path).

## Weather (0.4.21, build 25)

Choose your city in **Settings → Weather location**; there is no preset user
city or GPS request. Search waits 500 ms after typing and offers up to five
matches. A small dashboard weather button opens current conditions, today's
hourly forecast and a seven-day forecast. The idle clock shows the same weather
icon and temperature, retaining its white daytime/red nighttime appearance.
The weather page pauses the idle clock and presence camera; doorbell calls can
still open over it.

The shared [Open-Meteo](https://open-meteo.com/) forecast refreshes every
30 minutes while the app is active. A local cache retains up to six hours of
data, with saved/stale indicators after one hour, a refresh failure or a change
of local day. Failed automatic requests have a five-minute retry guard; manual
refresh is available. Labels use the selected city's time zone and handle
daylight-saving transitions. Weather adds no GPS or continuous animation.
Choose the actual city on the iPad; physical weather acceptance remains
pending. See the [weather handoff](../docs/IOS_WEATHER_HANDOFF.md) for validation.

## Doorbell calls (0.4.19, build 23)

While Felicity is in the foreground, the recorder's ONVIF PullPoint events can
open the matching doorbell over the current screen. Initial subscription state
does not ring. Calls start with speaker and microphone off, and close after
60 seconds. Enable listening separately, or tap the microphone to talk and
listen. Microphone activation requires permission and has a 30-second safety
limit that closes the call; turning it off restarts the 60-second video limit.
Leaving the foreground stops the call, audio and event subscription.

A real ring saves one early video frame. After the call, a static thumbnail
appears at the bottom left for 30 minutes; tapping it reopens live video.
The thumbnail keeps no live stream running, and manually opening it does not
create a new ring or replace the ring snapshot. Recorder passwords remain in Keychain.
Physical speaker, microphone and echo-cancellation checks are deferred.

## Energy charts (0.4.20, build 24)

Tap any energy card to open a vertically scrolling detail page. The six metric
buttons switch between Solar, Home Load, Battery, Grid, System and Today.
Current readings remain live while the charts are open. Panels stack in
portrait and use the available width in landscape; watts, volts, percentages
and degrees have separate scales rather than sharing one axis.

Solar shows **Total, PV1 and PV2 together in one chart**. Today shows **Solar,
Load, PV1 and PV2 together in one chart**, with no additional PV panels to
scroll down to. PV1 is blue and PV2 is purple consistently on both screens.
Each line can still be hidden through its legend item and inspected by point.

Today loads the existing Today and Solar endpoints concurrently and joins them
only when their start, end and bucket count match. Missing readings remain gaps;
if the Solar request fails, the Today Solar/Load lines still work and the PV
lines have no data. These are power histories in watts, not voltage or current
histories.

Tap a legend item to hide or show that series. Tap a chart or drag horizontally
to inspect a sample and its time; vertical movement scrolls the page. VoiceOver
can adjust the selected sample. Gaps remain gaps, signed power values retain
their direction, and time labels use the server's chart metadata.

Previously loaded charts reopen immediately. The cache is separate for each
server and metric, with a 60-second lifetime for energy charts and 10 seconds
for System. Charts refresh only while the detail page is in the foreground;
manual refresh bypasses the cache. A failed refresh keeps the visible chart,
and late or canceled requests cannot replace a newer selection.

Each panel draws its lines and axes in one Canvas. Unchanged chart data is not
republished, and the equatable panel avoids redrawing for unrelated live
readings. There are no per-sample views or continuous chart animations. The
client uses the server's existing buckets, typically 180 energy samples or
60 System samples; it does not downsample them. Frame rate and battery savings
have not been measured on the physical iPad.

## Dim clock and motion wake (0.4.17, build 21)

On the energy dashboard, one minute without detected activity shows large
time, date and household power consumption on black, plus weather when a city
is configured: **white in daylight, red at night**. The clock updates and shifts
position once per minute; household
power refreshes every 30 seconds. A tap or camera movement wakes the dashboard.

Day and night brightness are set independently and apply directly, up to 100%:

| Setting | Default | Range |
|---|---|---|
| Day dashboard | 100% | 5–100% |
| Night dashboard | 12% | 5–100% |
| Day clock · white | 50% | 1–100% |
| Night clock · red | Existing clock setting, otherwise 4% | 1–100% |

Version 0.4.17 preserves the existing nighttime clock brightness and replaces
the old dashboard brightness bias/curve. Day/night mode uses the existing
darkness threshold, with a 0.06 hysteresis gap to avoid flicker. Clock color and
brightness change together; waking applies the selected dashboard brightness
immediately. With automatic dashboard brightness disabled, the day dashboard
setting applies in both lighting conditions.

The clock also appears when the camera's smoothed light estimate
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
the four brightness settings above, darkness threshold and motion sensitivity.
The night dashboard setting is shown when automatic brightness and camera wake
are enabled. Camera wake and automatic dashboard brightness can be disabled,
and the clock can be disabled or previewed.
The camera permission prompt explains its use. Only the front camera is used,
with no microphone, recording, or uploads. The system camera indicator is visible.
If camera access is denied or interrupted, touch wake remains available.

Felicity keeps the device awake only while this mode is enabled and the app is
in the foreground. Camera capture and idle clock pause in settings, camera/event
views, energy details and weather. Original display brightness and idle-timer
state are
restored when leaving the mode/app. Idle polling requests only current power;
summary/status requests are skipped. These changes reduce processing and
network work, but battery or wall-power savings have not been measured.

Historical validation: version 0.4.15/19 replaced the global SwiftUI drag gesture
with a passive UIKit touch observer. That signed build passed 48 simulator tests; the user
confirmed touch controls and the red clock now work on the requested iPad Pro.
The signed 0.4.16/20 build passed 55 simulator tests and was installed on the
same iPad. On 2026-11-14 the user confirmed that covering the camera shows the
red clock and movement returns the dashboard. The white daytime clock and
dashboard wake brightness were subsequently confirmed on 0.4.17. Long-term
stability and actual energy use have not been measured on the physical iPad.
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

The 0.4.19 doorbell audio implementation follows the contracts in
[`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) and the behavioral checklist in
[`Docs/PORTING_PLAN.md`](Docs/PORTING_PLAN.md); physical audio validation remains
deferred. Weather is implemented in 0.4.21; its remaining physical checks are
tracked in the [iOS roadmap](../docs/IOS_ROADMAP.md).
