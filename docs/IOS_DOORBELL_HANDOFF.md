# iOS doorbell and Today PV details — 0.4.23, build 27

Current source and confirmed installation are **0.4.23/27**. Its signed build
and all 154 native simulator tests passed. Exact-device trusted Wi-Fi
installation reached 100%, exited with code 0 and was version-verified.
On the preceding **0.4.22/26**, the user reported that a real doorbell ring did not open a call
while the idle clock was visible and the app remained in the foreground.
The new fix is not yet verified by a real ring. See
[weather handoff](IOS_WEATHER_HANDOFF.md) for this release's actual-hour label.

## Missed-ring diagnosis — 2026-11-16

The iPad had one running app process and persisted doorbell status remained
at **Connecting**. A read-only recorder probe reproduced the transport failure:
an unauthenticated SOAP POST using `Connection: keep-alive` received HTTP/1.1
401 with neither `Content-Length` nor `Transfer-Encoding`; the recorder kept
the connection open without EOF, so reading the challenge response timed out.
The same request with `Connection: close` reached EOF immediately.

The existing camera-discovery SOAP transport already requests connection close;
the doorbell event transport did not. Version 0.4.23 adds that header to event
SOAP requests. This addresses the observed
authentication stall; successful event subscription and an actual ring still
need verification after installation. No diagnostic action triggered a ring or
enabled the microphone. Two-way audio remains physically unverified.

## Release checks for 0.4.23/27

- Signed device build passed: `ios/build/recovery-device-0.4.23.log`.
- All 154 native simulator tests passed with no failures. This one-header
  transport change did not add a test. Evidence:
  `ios/build/recovery-tests-0.4.23.log` and
  `ios/build/recovery-tests-0.4.23.xcresult`.
- Strict signature verification passed. The embedded profile includes the
  exact requested iPad and still expires on 2026-11-21 at 17:20:22 UTC.
- Verified package: `ios/build/ipad/Felicity-0.4.23-build27.ipa`.
  Previous app: `ios/build/ipad/installed-0.4.22-build26.app`.
  Successful exact-device Wi-Fi installation and version verification:
  `ios/build/recovery-install-0.4.23-wifi.log`.
- The portrait simulator clock showed **Now** cloud/temperature → **23:00**
  moon-cloud/temperature, with neither **In 6h** nor a city name. This checks
  the separate weather-label change, not doorbell delivery.

Open the installed Felicity and verify event-subscription status and a
real doorbell press, including while the idle clock is visible. **Listening**
status and successful real-ring delivery have not yet been confirmed.
The post-install process check found the app was not running; the retained
**Connecting** value came from before the update and is not a new subscription
result. Manual opening and fresh status/ring verification remain pending.

## Historical release evidence

The preceding **0.4.20/24** combined all Solar
series in one chart and all Today series in one chart. The signed native build
and all 125 tests passed. Wi-Fi installation on the exact iPad exited with code
0, and a subsequent lookup verified 0.4.20/build 24. Physical feedback on the
combined charts has not yet been collected. Doorbell behavior below is unchanged.

0.4.20 release evidence: `ios/build/recovery-device-0.4.20.log`,
`ios/build/recovery-tests-0.4.20.log`,
`ios/build/recovery-tests-0.4.20.xcresult` and
`ios/build/recovery-install-0.4.20-wifi.log`. Installed IPA:
`ios/build/ipad/Felicity-0.4.20-build24.ipa`; previous app retained at
`ios/build/ipad/installed-0.4.19-build23.app`.

On 2026-11-16, **0.4.19/23** was installed and version-verified. Its final
signed release build and all **125 simulator tests passed**. Direct Wi-Fi
installation reached 100% and exited with code 0; a subsequent exact-device
lookup confirmed version 0.4.19/build 23. The user answered “Проверю позже”
(“I'll check later”) for both the real ring/snapshot and two-way audio checks.
Those checks were initially deferred. The later 0.4.22 missed-ring failure is
documented above; successful call/snapshot and audio behavior remain unverified.

## Doorbell behavior and Android parity

The client subscribes directly to the recorder's ONVIF PullPoint service while
in the foreground; it does not poll 3ye for rings. Initial subscription state
does not generate a call. Ring edges are filtered, accepted calls have a
five-second duplicate guard, and an eight-second fallback handles a missing
release event. The call uses a separate UIWindow above the current app route.

Calls open with speaker and microphone off and a 60-second video deadline.
Listening is explicit. Starting the microphone also enables listening and
replaces the video deadline with a 30-second safety deadline, including setup
and permission time. Repeated activation cannot extend that deadline. Expiry
stops audio and closes the call; manually stopping talk restarts 60 seconds.
Closing or backgrounding stops video, speaker, microphone and pending work.
Backgrounding also stops the event subscription. No event enables the microphone.

Native G.722 encoding/decoding is checked against Android golden vectors.
Speaker audio uses RTSP/RTP over TCP; microphone audio uses the UDP backchannel
with the native voice-processing path for echo cancellation. Passing codec
tests does not verify the physical audio path or acoustic echo behavior.

After a real ring, the first usable video frame is captured after a short
700 ms delay and retained as a static bottom-left thumbnail for 30 minutes.
Tapping it opens a fresh, muted 60-second live preview. This manual action
bypasses ring deduplication but does not create a ring or overwrite its image.
The thumbnail does not maintain an RTSP session while the dashboard is idle.
Its image is returned atomically from the preview pipeline, so another camera
preview update cannot replace the captured caller frame.

## Configured target

The existing trusted Wi-Fi pairing was used for a read-only check of the exact
iPad Pro 9.7-inch, iPadOS 16.7.16, at `192.168.13.188`. Its Felicity preferences
already contain recorder `192.168.13.234:8080`, a configured username and
15 cached cameras. The doorbell is `db4 (hw2)`, using stream host
`192.168.13.234:8554`. No Keychain values were read or exported, and the check
did not change device settings, trigger a ring or start audio. See
[kiosk recovery](IOS_KIOSK_HANDOFF.md) for exact-device installation and signing.

## Today and Solar graphs

Version 0.4.19 introduced Today PV1/PV2 power data. Since 0.4.20, Today
shows Solar, Load, PV1 and PV2 in one watt chart; Solar likewise shows Total,
PV1 and PV2 in one chart. PV1 stays blue and PV2 purple across both screens,
with legend toggles and point inspection retained.
The client fetches the existing `today` and `pv` chart endpoints concurrently,
joining only equal finite start/end windows with equal bucket counts. This
prevents cross-midnight responses from attaching strings to the wrong day.
Real PV readings can remain visible when the matching overview bucket is
missing; absent or invalid channel values stay gaps. A failed PV request leaves
the Today overview available. No backend deployment or invented voltage/current
history is involved. Existing 60-second chart caching limits these requests; stable missing
values compare equal so repeated partial data does not force chart redraws.

## Validation and remaining checks

The 0.4.19 suite passed 125 tests. It covers chart merging and HTTP fallback, call deadlines,
duplicate suppression, event filtering, G.722 vectors and cancellation of queued
audio work. Local evidence:

- Final signed build: `ios/build/recovery-device-0.4.19-delivery.log`.
- Tests: `ios/build/recovery-tests-0.4.19-delivery.log`.
- Result bundle: `ios/build/recovery-tests-0.4.19-delivery.xcresult`.
- Wi-Fi installation: `ios/build/recovery-install-0.4.19-delivery-wifi.log`.
- Installed IPA: `ios/build/ipad/Felicity-0.4.19-build23.ipa`.
- Current app: `ios/build/ipad/Payload/Felicity Dashboard.app`.
- Previous confirmed app: `ios/build/ipad/confirmed-0.4.18-build22.app`.

The existing profile expires on 2026-11-21 at 17:20:22 UTC (18:20:22 Madrid);
this release does not extend that expiry.

After the 0.4.23 repair, physical acceptance still requires a real doorbell press,
initially muted video over an open app route, explicit listening, microphone
permission and two-way speech, the 30-second safety close, the 60-second video
close, background privacy, and the static thumbnail after returning home.
Check Today PV1/PV2 against the corresponding Solar readings. Actual energy
consumption and acoustic performance have not been measured.

Weather is implemented; its latest hour-label adjustment and remaining work
are tracked in [IOS_ROADMAP.md](IOS_ROADMAP.md).
