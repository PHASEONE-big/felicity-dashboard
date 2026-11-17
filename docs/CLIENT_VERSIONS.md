# Client versions and repository layout

This repository contains three independently versioned native clients. The
Home Assistant backend has its own version; do not use it to identify a mobile
APK, iOS app, or display firmware.

| Client | Current source version | Build | Source | Git snapshot |
|---|---|---|---|---|
| iOS / iPadOS | 0.4.26 | 30 | `ios/` | baseline: `snapshots/ios/0.4.13-build17` |
| Android / dragon | 0.7.25 | 32 | `android/app/` | `snapshots/android/0.7.25-build32` |
| ESP32 + Nextion | 0.14.1 | — | `esp32/`, `nextion/`, `firmware/` | `snapshots/esp32-nextion/0.14.1` |

These tags preserve development baselines. Current iOS **0.4.26/30** adds a sun
icon beside solar generation on the idle clock and displays its weekday/month
in Spanish. Data, font and white/day versus red/night colors are unchanged.
The final signed build, all 159 native simulator tests and portrait UI checks
passed, including Spanish date text under a Russian simulator locale.
USB installation completed and a separate exact-device USB lookup verified
**0.4.26/30**. Physical confirmation of the sun icon and Spanish date is pending.

iOS 0.4.25 displays
household consumption / solar generation in watts on the idle clock. Both
readings use the same current snapshot and freshness state, with no additional
polling requests. Its signed build, all 159 native simulator tests and the
portrait clock readout check passed. Earlier Wi-Fi attempts failed in device
service channels; after the user connected USB, installation completed and a
separate exact-device USB lookup verified **0.4.25/29**. The user acknowledged
the installed version on 2026-11-17 and requested the solar icon now in 0.4.26.
See [installation evidence](IOS_KIOSK_HANDOFF.md).

iOS 0.4.24 repairs
doorbell-thumbnail touch handling and ensures reopening starts with audio off.
Its signed build, all 159 native simulator tests and simulator thumbnail
controls passed. Direct Wi-Fi installation completed and device lookup verified
**0.4.24/28**. On 2026-11-17 the user confirmed both repaired actions on the
physical iPad: tapping the thumbnail reopens the full camera view with the Talk
button, and X dismisses the card. Ring delivery and thumbnail appearance were
already confirmed on 0.4.23; two-way audio remains unverified.

iOS 0.4.23 labels the
idle clock's six-hour weather outlook with its actual local forecast hour and
addresses a recorder HTTP authentication response that stalls doorbell event
subscription. The user reported a missed ring on the idle clock in 0.4.22.
The signed build and all 154 native simulator tests passed; the actual-hour
clock label was checked in the simulator. Direct Wi-Fi installation completed
and device lookup verified **0.4.23/27**. After the user opened the app on
2026-11-17, a fresh exact-device probe confirmed **Listening for doorbell**.
The user then confirmed real-ring delivery and thumbnail appearance, exposing
the control failure addressed by 0.4.24. See the
[doorbell handoff](IOS_DOORBELL_HANDOFF.md).

iOS 0.4.22 replaces
the idle clock's city-name label with **Now → +6h** weather icons and
temperatures from the same hourly cache, without extra requests or timers.
Its signed build and all 154 native simulator tests passed, and the new clock
layout was checked in the simulator. Direct Wi-Fi installation completed and
device lookup verified **0.4.22/26**; physical confirmation of its new clock
layout is pending. The user confirmed the preceding 0.4.21 works well on the iPad.

iOS 0.4.21 added manually selected city weather to the dashboard header and idle
clock, plus a full-screen hourly and seven-day forecast. Open-Meteo requests and
cache are shared, with 30-minute foreground refresh and no GPS. Its signed build,
all 151 native simulator tests, simulator UI checks and a live public-city API
check passed. Direct Wi-Fi installation completed on the exact requested iPad,
and device lookup verified **0.4.21/25**. See the
[weather handoff](IOS_WEATHER_HANDOFF.md).

iOS 0.4.20 puts all Solar
series in one chart and all Today series in one chart, so PV1/PV2 no longer
require scrolling to additional panels. Legend toggles and point inspection
remain available, with PV1 blue and PV2 purple on both screens. The signed
native build and all 125 tests passed; 0.4.20/24 was installed over Wi-Fi on
the exact requested iPad and verified by device lookup. Physical feedback on
the combined charts has not yet been collected.

iOS 0.4.19 added foreground
ONVIF doorbell calls, native two-way audio with explicit microphone activation,
and a static last-ring preview, and introduced Today PV1/PV2 power data from
the existing chart endpoints. The final
signed release build and all 125 simulator tests passed. Version 0.4.19/23 was
installed over Wi-Fi on the exact requested iPad and verified by device lookup.
The user initially deferred real ring/snapshot and two-way audio checks;
0.4.22 later exposed the missed-ring failure above. Ring delivery and thumbnail
appearance were confirmed on 0.4.23; controls and audio are tracked separately. See the
[iOS doorbell handoff](IOS_DOORBELL_HANDOFF.md).

iOS 0.4.18 rebuilt the energy
details for portrait scrolling, with separate unit panels, interactive series
legends, point inspection and cached chart loading. Its 81 simulator tests
passed, and portrait/landscape layouts were checked in the simulator. The final
signed build passed and 0.4.18/22 was installed over direct Wi-Fi on the exact
requested iPad, with its installed version verified afterward. On 2026-11-16
the user confirmed improved portrait readability, working point inspection and
smooth vertical scrolling. See the
[iOS charts handoff](IOS_CHARTS_HANDOFF.md) for release behavior and validation.

iOS 0.4.17 added white daytime and red
nighttime clocks, with separate day/night brightness settings for the dashboard
and clock. Selected brightness applies directly, up to 100%; the old brightness
bias and 85% dashboard limit are removed. Existing nighttime clock brightness
is preserved. Tiny-grid motion detection, the darkness shortcut and reduced
idle polling are unchanged. As of 2026-11-16, the signed 0.4.17/21 build and
62 simulator tests passed, and the update was installed on the exact requested
iPad over USB and then successfully reinstalled over Wi-Fi. The user confirmed
the white daytime clock and sufficient dashboard brightness on wake. Earlier
darkness/motion transitions were physically confirmed
on 0.4.16/20 on 2026-11-14. The previous 0.4.13 tag remains the recovery baseline.
See [iOS kiosk handoff](IOS_KIOSK_HANDOFF.md) for installation and validation.
Android 0.7.25 preserves short ONVIF activity boundaries discovered
during physical testing on dragon, and includes 0.7.24's playback/seek fixes.
See [Android 0.7.25](ANDROID_0.7.25.md) for the evidence. The original Android
baseline remains at `snapshots/android/0.7.23-build30`.
The ESP32 binary reports 0.14.1; Nextion has no independently
verified semantic version, so its exact HMI/TFT files are identified by hashes
in the 0.14.1 hardware bundle. No new hardware release was issued.
Baseline verification passed: 65 Android unit tests and a debug APK build; 25 iOS tests
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

- GitHub: `https://github.com/PHASEONE-big/felicity-dashboard`
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
