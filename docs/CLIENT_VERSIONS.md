# Client versions and repository layout

This repository contains three independently versioned native clients. The
Home Assistant backend has its own version; do not use it to identify a mobile
APK, iOS app, or display firmware.

| Client | Current source version | Build | Source | Git snapshot |
|---|---|---|---|---|
| iOS / iPadOS | 0.4.13 | 17 | `ios/` | `snapshots/ios/0.4.13-build17` |
| Android / dragon | 0.7.23 | 30 | `android/app/` | `snapshots/android/0.7.23-build30` |
| ESP32 + Nextion | 0.14.1 | — | `esp32/`, `nextion/`, `firmware/` | `snapshots/esp32-nextion/0.14.1` |

These tags preserve recovered development baselines, not newly tested releases.
iOS includes the previously uncommitted 0.4.13 changes. Android's event/archive
jump remains open. The ESP32 binary reports 0.14.1; Nextion has no independently
verified semantic version, so its exact HMI/TFT files are identified by hashes
in the 0.14.1 hardware bundle. No new device release was issued during recovery.
Verification passed: 51 Android unit tests and a debug APK build; 25 iOS tests
on an iPad simulator; source-version and firmware-hash checks. These checks do
not replace physical device testing of archive playback.

## Version sources and validation

[`../clients.json`](../clients.json) records these three baselines. Build tools
continue to read their native version declarations:

- iOS: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
- Android: `versionName` and `versionCode` in `android/app/build.gradle`.
- ESP32: `PROJECT_VER` in `esp32/CMakeLists.txt`.
- Nextion: SHA-256 of the HMI source and compiled TFT in the hardware bundle.

Run `python3 tools/check_client_versions.py` before committing a version change.
It checks version declarations, the embedded ESP32 binary version, firmware
hashes, and equality of the bundled firmware copies. Update `clients.json`
together with a client's native version declaration and corresponding artifacts.
Snapshot tags identify the historical baselines and must never be moved to
newer code. Create a new tag when preserving a new baseline.

Version numbers are independent. Before PR #48 was merged, `main` had Android
0.15.1 while the more developed archive client was 0.7.23 on `feature/ios-client`.
That numeric mismatch reflected divergent development histories. PR #48 is
now merged and `main` contains the archive client. Identify builds using both
client version and build number, and compare Git commits rather than assuming
the larger version string represents newer source code.

## Repository and workspace

- GitHub: `https://github.com/okiyashko1337/felicity-dashboard`
- Active workspace for the recovered task: `/Users/ok/felicity-dashboard`
- Recovery branch: `codex/client-baselines`
- PR #48 merge: `bf10aa36fca366bc158645aae28eb32dab18f181`, now in `main`
- Recovered source base: `b378c92c30109b04b4f039016db0c2ab951cc29c`
- Recovery details and pending Android work:
  [`ANDROID_ARCHIVE_HANDOFF.md`](ANDROID_ARCHIVE_HANDOFF.md)

The old `.codex/.chatgpt-projects/.../felicity-dashboard` workspace is retained
as a reference. Subsequent work for this task happens in the active workspace.
Historical branches are retained. PR #48 reconciled the two committed
histories; the recovery branch also preserves the previously local iOS work.

Use one repository with the three client directories; splitting repositories
would separate shared API contracts and firmware distribution unnecessarily.
Use a task branch for a change and a client-specific tag to identify a baseline.

GitHub stores pushed commits, not live local files. Each local clone has its
own checkout, branch and uncommitted changes. Fetch updates remote references;
it does not switch branches or upload local edits. To check synchronization:

```sh
git fetch origin
git status --short --branch
git rev-list --left-right --count HEAD...origin/main
git diff --stat origin/main
```

On a clean, synchronized main checkout the counts are `0 0` and the diff is
empty. On a task branch, the diff describes intentional unpublished or
unmerged work. Commit and push that work, then integrate its PR to make it
part of GitHub main. Build caches and local installers are intentionally ignored.

## Build outputs

- Android: `android/app/build/outputs/apk/debug/app-debug.apk`; check its adjacent
  `output-metadata.json` or APK manifest to identify the actual build.
- iOS: build/archive through `ios/FelicityDashboard.xcodeproj`; identify the
  produced app by its bundle version, not a README label.
- ESP32 + Nextion: distributed binaries are in `firmware/`, mirrored under
  `felicity_dashboard_addon/app/firmware/`; the TFT is also in `nextion/`.

The user-supplied Android 0.7.23 APK is retained locally under
`android/app/build/outputs/apk/baseline-0.7.23/`; its hash is in the handoff note.
It is not a new build. Android rescue/prototype sources are auxiliary tools,
not additional Felicity client release lines. Third-party bootstrap APKs in
`android/setup-dragon/` stay local and are excluded from Git.
