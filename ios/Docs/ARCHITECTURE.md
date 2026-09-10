# iOS architecture

The iOS app is a native SwiftUI client. Platform APIs remain native:

- `URLSession` / `Network.framework` for HTTP and RTSP transports;
- VideoToolbox for H.264 and HEVC;
- AVAudioEngine for G.722 PCM playback and microphone capture;
- Keychain for recorder credentials;
- SwiftUI/UIKit for adaptive iPhone and iPad interfaces.

`CoreContracts.swift` is the boundary for the shared domain layer. The first
shared extraction covers models, ONVIF metadata, event filters, archive marker
TTL, timeline/seek rules, RTP depacketization and G.722. Media decoding,
rendering, persistence and application lifecycle are deliberately excluded.

Kotlin 2.4.10 is officially tested through Xcode 26.4 while this workspace uses
Xcode 26.6. The first native target therefore does not depend on an unsupported
Kotlin/Native toolchain. KMP integration follows behind the stable contracts
after its iOS compiler is verified independently.

Push notifications are intentionally out of scope. ONVIF ring events are
received only while the app is active.

## Archive transport

Archive playback is owned by one direct RTSP-over-TCP session per open archive
screen. `PAUSE`, `PLAY` and range seeks share that session; the app never sends
synthetic keep-alive video frames. A lightweight `GET_PARAMETER` keeps a paused
recorder session alive. The displayed clock and timeline cursor are updated from
the recorder's absolute NTP extension on a delivered RTP access unit, never from the
requested seek target.

ONVIF Profile G activity is queried through its replay metadata track with
`Rate-Control: no` and the recorder's activity-only metadata filter. The compact
protobuf batch is decoded locally into person, animal, vehicle and ring intervals. Plain motion is
ignored; face points come from 3ye because the ONVIF activity bit mask does not
carry a separate face class.
