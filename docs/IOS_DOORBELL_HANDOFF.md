# iOS doorbell and Today PV details — 0.4.26, build 30

Current source and confirmed installation are **0.4.26/30**, adding a sun icon
beside clock generation and
a Spanish idle-clock date. Its final signed build, 159 tests and simulator
icon/date checks passed. USB installation completed and a separate exact-device
USB lookup verified 0.4.26/build 30. Physical icon/date checks are pending.
The preceding **0.4.25/29** clock consumption / solar readout is described in
[kiosk handoff](IOS_KIOSK_HANDOFF.md). Its signed build, 159 tests
and simulator clock readout check passed. After earlier Wi-Fi failures, USB
installation completed and a separate exact-device USB lookup verified 0.4.25/29.
The user acknowledged the installed 0.4.25 and requested the new sun icon.
Doorbell behavior is unchanged from the preceding **0.4.24/28**. Its signed build,
all 159 native simulator tests and simulator control checks passed. Exact-device
trusted Wi-Fi installation reached 100%, exited with code 0 and was version-verified.
On 2026-11-17, using the preceding **0.4.23/27**, the user
confirmed that a real ring opened the call and that the caller thumbnail
appeared after the call ended. The thumbnail's close button did not respond.
Version 0.4.24 repairs thumbnail touch handling. On 2026-11-17, the user
confirmed both actions on the physical iPad: tapping the thumbnail reopens the
full camera view with the Talk button, and X dismisses the card. Two-way audio
has not been verified.

## Thumbnail control repair — 2026-11-17

The overlay compared a cached SwiftUI global rectangle with UIKit window touch
coordinates. Version 0.4.24 uses a native view probe and converts the touch
position at input time, so the card's hit region follows its actual layout.
The close button has a 44-point target and plain button styling. Tapping the
image should reopen live video with audio off; reopening also explicitly stops
any prior audio/pending microphone work. Build, tests and simulator control
checks passed; the user confirmed thumbnail reopening and dismissal on the
physical iPad on 2026-11-17.

## Release checks for 0.4.24/28

- Signed device build passed: `ios/build/recovery-device-0.4.24.log`.
- All 159 native simulator tests passed with no failures, including five UIKit
  tests for coordinate conversion, detached views and full-call hit testing.
  Evidence: `ios/build/recovery-tests-0.4.24.log` and
  `ios/build/recovery-tests-0.4.24.xcresult`.
- Simulator coordinate clicks verified that tapping the thumbnail opens the
  full doorbell view with a 60-second timer and sound/microphone off; closing
  the call returns the original thumbnail, and its X button dismisses it.
  This used a synthetic image and a localhost test stream, without accessing
  an actual camera or microphone. The fixture was cleared and the original
  simulator state restored.
- On 2026-11-17, the user repeated the physical 0.4.24 check and confirmed that
  tapping the image opens the full camera view with Talk available, and tapping
  X dismisses the thumbnail. This confirms those controls, not microphone
  capture or two-way speech.
- Strict signature verification passed. The embedded profile includes the
  exact requested iPad and expires on 2026-11-21 at 17:20:22 UTC, unchanged.
- Verified package: `ios/build/ipad/Felicity-0.4.24-build28.ipa`.
  Previous installed app: `ios/build/ipad/installed-0.4.23-build27.app`.
  Successful exact-device Wi-Fi installation and version verification:
  `ios/build/recovery-install-0.4.24-wifi.log`.

## Missed-ring diagnosis — 2026-11-16

The iPad had one running app process and persisted doorbell status remained
at **Connecting**. A read-only recorder probe reproduced the transport failure:
an unauthenticated SOAP POST using `Connection: keep-alive` received HTTP/1.1
401 with neither `Content-Length` nor `Transfer-Encoding`; the recorder kept
the connection open without EOF, so reading the challenge response timed out.
The same request with `Connection: close` reached EOF immediately.

The existing camera-discovery SOAP transport already requests connection close;
the doorbell event transport did not. Version 0.4.23 adds that header to event
SOAP requests. After the user opened 0.4.23 on 2026-11-17, a fresh exact-device
probe confirmed **Listening for doorbell**, replacing the earlier connecting
state. The user then confirmed real-ring delivery and a visible caller
thumbnail. The subsequent thumbnail-control repair and its physical
confirmation are described above.
No diagnostic action triggered a ring or enabled the microphone. Two-way audio
remains physically unverified.

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

On 2026-11-17, the user confirmed opening the installed 0.4.23. A fresh read-only
probe of the exact iPad found one running app process, doorbell enabled and
status **Listening for doorbell**. Safe evidence:
`ios/build/recovery-doorbell-status-0.4.23-2026-11-17.json`.
The immediate post-install check had found no running app and only a retained
pre-update **Connecting** value; the new probe supersedes that status.

Later on 2026-11-17, the user confirmed that a real ring opened the call and the
caller thumbnail was visible after it ended. This verifies delivery and image
appearance, but the close button failed. The 0.4.24 repair restored dismiss and
reopen controls, confirmed by the user on 2026-11-17; two-way audio remains
unverified.

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
documented above. Ring delivery and thumbnail appearance were subsequently
confirmed on 0.4.23; thumbnail controls and audio are covered separately above.

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

Thumbnail dismissal and reopening were physically confirmed on 0.4.24.
Touch pass-through outside the card and separate audio,
microphone permission, safety-deadline and background-privacy checks remain
unverified; the user's ring/image confirmation does not establish those results.
Check Today PV1/PV2 against the corresponding Solar readings. Actual energy
consumption and acoustic performance have not been measured.

Weather is implemented; its latest hour-label adjustment and remaining work
are tracked in [IOS_ROADMAP.md](IOS_ROADMAP.md).
