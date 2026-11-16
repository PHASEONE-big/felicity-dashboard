# iOS doorbell and Today PV details — 0.4.19, build 23

As of 2026-11-16, source and confirmed installation are **0.4.19/23**. The final
signed release build and all **125 simulator tests passed**. Direct Wi-Fi
installation reached 100% and exited with code 0; a subsequent exact-device
lookup confirmed version 0.4.19/build 23. The user answered “Проверю позже”
(“I'll check later”) for both the real ring/snapshot and two-way audio checks.
Those physical behaviors remain unverified; no immediate user action is pending.

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

Today retains its Solar/Load overview and gains separate PV1/PV2 watt panels.
The client fetches the existing `today` and `pv` chart endpoints concurrently,
joining only equal finite start/end windows with equal bucket counts. This
prevents cross-midnight responses from attaching strings to the wrong day.
Real PV readings can remain visible when the matching overview bucket is
missing; absent or invalid channel values stay gaps. A failed PV request leaves
the Today overview available. No backend deployment or invented voltage/current
history is involved. Solar also retains its overview and has separate PV1/PV2
panels. Existing 60-second chart caching limits these requests; stable missing
values compare equal so repeated partial data does not force chart redraws.

## Validation and remaining checks

The 125-test suite comprises 81 previous tests, one PV-scale test, 10 Today
chart tests, nine call-policy tests, 11 event tests, nine audio tests and three
controller tests. It covers chart merging and HTTP fallback, call deadlines,
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

Deferred physical acceptance includes a real doorbell press,
initially muted video over an open app route, explicit listening, microphone
permission and two-way speech, the 30-second safety close, the 60-second video
close, background privacy, and the static thumbnail after returning home.
Check Today PV1/PV2 against the corresponding Solar readings. Actual energy
consumption and acoustic performance have not been measured.

The user's requested weather work is deferred until after the doorbell work;
its scope is saved in [IOS_ROADMAP.md](IOS_ROADMAP.md).
