# ONVIF audio: full-stack implementation plan

## Goal

Play the doorbell's original G.722 wideband audio together with the live H.264 video, and provide a privacy-safe push-to-talk backchannel. The receive path must not transcode audio.

## Known source characteristics

- RTSP server: ONVIF doorbell, TCP port 8554.
- Video: H.264, `trackID=1`, currently decoded by LibVLC.
- Incoming audio: G.722 wideband, `trackID=2`, receive-only.
- Backchannel audio: G.722, `trackID=3`, send-only.
- The recorder advertises incoming audio as `G722/16000`. G.722 audio is sampled at 16 kHz, but RTP payload type 9 uses an 8 kHz RTP timestamp clock. The audio payload itself must remain unchanged.
- Android LibVLC 3.5.1 receives the track but exposes it as `undf`: both its
  live555 and WAV codec-tag mappings omit G.722, although the bundled decoder
  itself exists.

## Receive path

1. Keep H.264 video on the proven direct LibVLC RTSP/TCP path.
2. Open a second authenticated RTSP/TCP session for receive-only `trackID=2`.
3. Remove the RTP header and decode each original G.722 payload locally with
   the public-domain decoder adapted from Android Open Source Project.
4. Play the resulting 16 kHz mono PCM through Android `AudioTrack`.
5. Connect the speaker privacy control to `AudioTrack` volume. Muting does not
   stop video and no incoming network audio is transcoded or re-encoded.

This receive path was physically verified on the Echo Show 5: incoming
doorbell sound is audible with normal playback.

## Talk-back path

Status: the control, microphone capture and experimental G.722 send path are
present, but outgoing sound has **not** been heard at the ONVIF doorbell and is
therefore not considered working. Do not describe two-way audio as complete.

1. Keep the separate ONVIF backchannel negotiation for `trackID=3` because this is a send-only media direction.
2. Capture mono PCM from `AudioRecord` at 16 kHz only while the microphone
   control in the persistent top bar is enabled. There is no control overlaid
   on the video.
3. Encode PCM to G.722 and packetize it as RTP payload type 9 for the negotiated server port. This is required source encoding, not transcoding of the incoming stream.
4. Pause local playback while talking to prevent acoustic feedback; restore it immediately on release.
5. Enforce privacy coupling:
   - speaker mute immediately disables and stops the microphone/backchannel;
   - enabling the microphone automatically enables incoming sound;
   - microphone off stops transmission but may leave listening enabled;
   - no audio capture exists while the top-bar microphone is disabled.

## Ring lifecycle

1. Keep the ONVIF PullPoint subscription active only in the home activity.
2. Open the camera only for an active `RingDetector` notification, not motion/object events or the falling edge of Ring.
3. Start one 60-second viewing timer after opening.
4. Suspend the timer during active push-to-talk and restart it on release.
5. On expiry, close RTSP/audio/backchannel resources and return to the dashboard home screen.

## Diagnostics and acceptance tests

- Log control-plane states without URLs containing credentials: SDP accepted, video track, audio track, decoder opened, AudioTrack opened, backchannel started/stopped.
- Record packet/byte counters and RTP sequence gaps, but never record audio payloads in production logs.
- Verified: audible incoming doorbell sound, stable video and mute/unmute.
- Still required: confirm outgoing push-to-talk at the doorbell before marking
  two-way audio complete.
- Test repeated rings, network interruption, doorbell reboot, app cold start and 30-minute continuous viewing for resource leaks.
