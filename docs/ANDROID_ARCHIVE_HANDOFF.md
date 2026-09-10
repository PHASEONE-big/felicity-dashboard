# Android archive task — recovered context

## Canonical workspace for this task

- Working directory: `/Users/ok/felicity-dashboard`
- Git remote: `https://github.com/PHASEONE-big/felicity-dashboard.git`
- Recovery branch: `codex/client-baselines`; integration branch: `main`
- Baseline commit: `b378c92c30109b04b4f039016db0c2ab951cc29c`
- Baseline Android version: `0.7.23`, versionCode `30`
- Previous workspace: `/Users/ok/.codex/.chatgpt-projects/g-p-6a68d66529d4819197c0cc92d6f7a68e/felicity-dashboard`

The previous workspace was on `feature/ios-client`. The initial inspection
mistakenly used this directory's older checkout of `main`, subsequently
updated to `fea1ca9`, with Android 0.15.1 and live camera support only.
The APK path supplied by the user identified the correct baseline.

On 2026-09-10 this workspace was switched to a new branch at the previous
workspace's HEAD. All 13 modified iOS files and 15 untracked Android files
were copied here. SHA-256 comparisons verified all 224 tracked/untracked
source files against the previous workspace. The previous workspace was
left untouched. Ignored caches and build directories were not imported.

The existing APK was preserved here as an explicitly named baseline:
`android/app/build/outputs/apk/baseline-0.7.23/app-debug.apk`

Baseline APK SHA-256:
`10047fcee4f6a6a39deaf9fb93faa963f144597bd5cb31158cb2a16b983538b8`

## User-reported bug and requested result

On Android device dragon, open a pet event card, then enter the ONVIF
archive. After some time playback switches to a neighboring event. Two
nearby recordings show a boar with a piglet followed by a separate boar;
the user cannot watch the intended recordings reliably. iOS works correctly.
The reference screenshot shows camera `db4 (hw2)`, 2026-09-10 around 02:19:19.
The user requested an Android fix and a version increase for device testing.

## Diagnosis in Android 0.7.23

- `ArchiveActivity` has a direct `OnvifArchiveSession` / `ArchiveMediaDecoder`
  playback path, automatic advancement through AI intervals, and a fallback
  to the nearest event after replay failures.
- `playbackEndFor` currently picks an individual event interval rather than
  merged continuous coverage. It also permits a nearby interval within two
  minutes and defaults to a 15-second segment when no interval is available.
- `togglePlayback` clears `strictEventTarget` when resuming, enabling fallback
  away from the event selected by the user.
- `acceptDirectFrame` receives a creation request argument but does not check
  it; asynchronous callbacks and reused sessions need careful investigation.
- iOS `ArchiveModels.swift` computes playback ends using merged coverage.

## Android 0.7.24 (build 31)

The fix merges overlapping/touching AI coverage before choosing the playback
end and following recording. It resolves delayed metadata against the selected
playback target, never against a later decoded frame, and does not invent a
15-second clip while metadata is unavailable. Opening an event stays strict
through Play/pause, so a failed replay cannot fall back to a neighboring card.

Delayed event-list/image loads no longer restart or cover a direct RTSP
session. Every seek has a generation propagated from RTSP to the decoder and
UI; late PLAY responses and old access units/render callbacks are rejected.
Decoder presentation IDs remain unique when seeking repeatedly to the same
archive time. Session reuse remains enabled. At the final AI interval the
transport is actually paused.

Eleven new regression tests cover overlapping pet/person detections, chains
of overlap, separate recordings, missing metadata, stale PLAY replies, and
callbacks arriving after seeking back to the same timestamp. All 62 Android
unit tests pass and the debug APK builds. No ADB device was connected, so
physical dragon verification of the two boar events is still pending.

For device verification: open each original pet card on db4, wait for metadata,
play through the full interval, pause/resume, then switch quickly between nearby
timeline positions. Confirm the playhead and camera timestamp remain on the
chosen recording until its complete AI interval ends. A replay error must show
an unavailable message without opening another event. iOS/ESP32/Nextion source
versions and their original snapshot tags are unchanged.

## Repository reconciliation

PR #48 was merged on 2026-09-10 as
`bf10aa36fca366bc158645aae28eb32dab18f181`.
It initially conflicted with main's squash commit for PR #47. The underlying
changes were already in the feature branch: `ad8a113` and `fea1ca9` have the
same stable patch ID. Resolving the seven conflicts preserved the feature
branch tree exactly. Android verification passed all 51 unit tests and a
debug APK build. No GitHub Actions checks were configured for PR #48.

The subsequent recovery branch preserves the 13 previously uncommitted iOS
files, auxiliary Android sources, and client version documentation. See
`CLIENT_VERSIONS.md` for baseline tags. The original ChatGPT project workspace
remains untouched as a historical reference.

Recovered iOS 0.4.13 built successfully and passed 25 DashboardModelsTests on
an iPad simulator. The source changes are preserved in commit `c0690f5`.
The user prioritized repository reconciliation and independent client
baselines before resuming the Android archive fix.
