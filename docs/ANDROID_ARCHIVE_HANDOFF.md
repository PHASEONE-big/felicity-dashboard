# Android archive task — recovered context

## Canonical workspace for this task

- Working directory: `/Users/ok/felicity-dashboard`
- Git remote: `https://github.com/okiyashko1337/felicity-dashboard.git`
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

## Investigation so far — not yet a verified diagnosis

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

No Android archive fix has been applied and no version has been increased.
A verification APK was built in a temporary PR-merge workspace; it is still
0.7.23, not an archive fix, and was not installed. Continue diagnosis, add meaningful
regression coverage, fix the confirmed issue, then build a version newer
than 0.7.23 with a versionCode greater than 30. Preserve the imported iOS work.

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
