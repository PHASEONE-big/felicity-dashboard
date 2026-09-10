# Android to iOS porting plan

The port is organized as working vertical slices. Each slice must be usable on
an iPad before the next one starts; the Android client remains the behavioural
reference, not a source to translate line by line.

## Milestones

| Milestone | User-visible result | Core work |
|---|---|---|
| 0 — Energy home | Adaptive six-card dashboard, settings and live status | Typed API models, polling lifecycle, server preference |
| 1 — Live cameras | Camera wall, last-frame thumbnails, LQ/HQ and pinch-to-zoom | Camera catalogue, RTSP/RTP transport, VideoToolbox renderer, per-camera quality |
| 2 — Events | Lightweight 3ye event list with camera/class filters | 3ye DTOs, thumbnail cache, event navigation |
| 3 — Archive | ONVIF timeline and deterministic seek | Profile G discovery, replay session, activity metadata filter, activity intervals, real decoded playhead |
| 4 — Audio | Incoming G.722 and privacy-safe talk-back | Native audio session, G.722 vectors, microphone timeout and route handling |
| 5 — Foreground ring | Doorbell opens immediately while Felicity is active | ONVIF event subscription, ring snapshot and 60-second return |

Push notifications and background ring delivery are intentionally excluded.

## Refactoring rules

1. Extract behaviour from Android behind small contracts before reusing it.
   UI activities and Android lifecycle objects never enter the shared core.
2. Preserve protocol code with golden byte-level fixtures. ONVIF metadata, RTP
   depacketization, replay clocks and G.722 must produce the same results on
   Android and iOS before their implementations are consolidated.
3. Keep decoding native. Android MediaCodec/libVLC and Apple VideoToolbox have
   different lifecycle and timing constraints; only their state machines and
   media timestamps are shared.
4. Treat one archive screen as one owned replay session. A new seek cancels the
   previous seek immediately, the cursor moves only after a decoded frame, and
   entering archive is paused at the nearest decodable frame.
5. Keep credentials out of shared preferences and source control. iOS stores
   recorder credentials in Keychain.

## Archive parity contract

- Render only person, animal, vehicle, face and doorbell activity; plain motion
  does not appear on the timeline.
- Add six seconds of available archive context on either side of an activity.
- A tap between activities chooses the temporally nearest recording; if the
  earlier interval is nearer, seek to its final decodable I-frame.
- Preserve the investigation marker across cameras for 30 minutes. If it is
  stale, enter at the selected camera's latest event.
- Keep the previous JPEG visible until the first decoded archive frame replaces
  it. Never advance controls, FPS or playhead from requested time alone.

## Shared-core gate

The Swift contracts in `CoreContracts.swift` are the seam for a future Kotlin
Multiplatform module. KMP is introduced only after its compiler officially
supports the installed Xcode release and the protocol golden tests pass on both
platforms. This avoids coupling the first usable iPad build to an unsupported
toolchain.
