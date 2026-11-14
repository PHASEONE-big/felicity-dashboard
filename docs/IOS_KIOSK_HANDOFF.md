# iPad restoration and clock mode

Requested device: iPad Pro, supplied LAN address `192.168.13.188`.
Confirmed USB UDID: `86d36a369fdaeb458f5a65ba0136bec628ffd018`.
USB detection now identifies this device as **iPad Pro (9.7-inch), J127AP**,
running **iPadOS 16.7.16 (20H392)**.
Source and last confirmed installation: iOS **0.4.16, build 20**.
Android and hardware versions are unchanged.
The bundle identifier and configured signing team are preserved.

## Current recovery status — 2026-11-14

The signed 0.4.14/18 app was installed over the existing application on the exact
USB device above. The installer reported `InstallComplete`; no uninstall was
performed. The user then opened Felicity manually and explicitly confirmed that
it opens and the dashboard displays data. After the follow-up fixes below, the
rebuilt 0.4.14 app was also installed successfully with `InstallComplete` and
exit code 0.

At task start, `git fetch origin` succeeded, and the checked-out
commit and upstream were both `2935d4a`, with ahead/behind counts `0 0` before
creating the task branch **`codex/ios-kiosk-recovery`**. Recovered uncommitted
changes were preserved.

The 0.4.14 follow-up fixes saved settings before clock preview and reset the idle
interval on return to the dashboard. That physical-device build and 38
simulator tests passed. On the physical iPad, however, the user reported that
neither the automatic clock nor “Show clock now” appeared, then clarified that
touch controls did not work while dashboard data continued updating.

The user then requested a practical, inexpensive motion trigger: remove complex
recognition, use a very small camera image, show only large red clock/date/home
consumption in dim mode, and adapt dashboard brightness to the light when motion
wakes it. The resulting **0.4.15/19 source** removes Vision recognition and
replaces the global zero-distance SwiftUI drag gesture with a passive UIKit
window touch observer. The signed 0.4.15/19 build and all
48 updated simulator tests passed. The exact iPad received the final update
over USB: signature/profile validation succeeded, followed by `InstallComplete`
and exit code 0. The user then confirmed that **touch controls work and the red
clock appears** on the physical iPad. The reported failure to switch immediately
when the camera was covered was not a completed inactivity-timeout test: the
user expected a quick darkness transition rather than waiting 60 seconds.

The installed **0.4.16/20** adds that behavior: the clock appears when the smoothed
camera light estimate stays below an adjustable threshold (default 0.18) for
three seconds. Smoothing precedes the hold, so covering the camera is expected
to show the clock in roughly 5–10 seconds, pending physical confirmation. The
shortcut triggers once per dark episode, so motion/touch wake is followed by
ordinary inactivity; hysteresis prevents threshold flicker. The signed native
build, all 55 simulator tests and exact-device USB installation passed. Final
physical darkness, motion, night-lighting and adaptive-brightness acceptance
remain pending.

## Installation

Use `/Users/ok/felicity-dashboard/ios/FelicityDashboard.xcodeproj`, scheme
`FelicityDashboard`. Do not use the older project copy in Xcode's recent list.

1. Connect and unlock the exact iPad identified above; accept Trust if asked.
2. Build for a physical iOS device using the active project. This iPadOS 16
   device uses the legacy USB installation path described below; do not select
   the unrelated `ipad-rei` as a substitute destination.
3. Check Signing & Capabilities: automatic signing, existing team and bundle ID.
   Renew the existing Apple Account session in Xcode if necessary. A Personal
   Team works without a paid membership, but its profile expires after 7 days.
4. Install over the existing app through the exact-UDID legacy USB path; do not
   uninstall it. Open Felicity on the iPad and allow local-network and
   front-camera access. The front camera is optional; touch wake still works
   without permission.

The former installed version/profile was not recovered, but the replacement
signed app has now been verified and installed; see the signing details below.
The historical project's `UserInterfaceState.xcuserstate` records this exact
UDID as an `iphoneos_arm64` run destination, last used 2026-09-02 at 19:28 Madrid.
The same file records a separate destination for rei and a successful Build at
19:41; that build report does not identify the device. The previous target is
therefore recovered, while the former installed version/profile is not.
Device Hub discovered a connected `ipad-rei` (iPad Pro 13-inch M4), but the user
explicitly confirmed that this is a different iPad. Nothing was installed or
launched on it. Do not use `ipad-rei` for this task. Use the confirmed USB UDID
above for all subsequent installation commands.

### Signing and installation after target recovery

Initially Xcode reported no account and no development profile. The user signed
in to the Apple Account in Xcode. A new physical-device build then succeeded
with the unchanged `io.github.homedashboard.ios` identifier and team NH364DL3M9.
`codesign --verify --deep --strict` passed. The embedded profile explicitly
includes USB UDID `86d36a369fdaeb458f5a65ba0136bec628ffd018` and expires
**2026-11-21 at 18:20:22 Madrid (17:20:22 UTC)**.

Current verified 0.4.16/20 products:

- `ios/build/ipad/Payload/Felicity Dashboard.app`
- `ios/build/ipad/Felicity-0.4.16-build20.ipa`

Both contain the final rebuilt 0.4.16 app. The 0.4.15 build with physically
confirmed touch/clock behavior is retained as
`ios/build/ipad/confirmed-0.4.15-build19.app` and
`ios/build/ipad/Felicity-0.4.15-build19.ipa`. The previous 0.4.14 products are
retained locally, including `ios/build/ipad/Felicity-0.4.14-build18.ipa`.
The initial signed products are preserved as `ios/build/ipad/initial-build18.app` and
`ios/build/ipad/Felicity-0.4.14-build18.initial.ipa`.

The standard 0.4.16 `xcodebuild` device build succeeded without special Swift
compiler overrides.

The earlier `devicectl device install app --device` attempt timed out at 15
seconds without an installation result. The subsequent legacy USB installation
succeeded with `InstallComplete`, and the user confirmed manual launch and a
working dashboard. The earlier CoreDevice timeout is not an outstanding
installation blocker.

### Legacy USB path

The target's iPadOS 16.7.16 version is confirmed by `ios-deploy`. The current
Xcode installation lacks the legacy `DeveloperDiskImage.dmg` needed by
`ios-deploy --justlaunch`, so that launch command fails. This does not prevent
USB installation or opening the app manually; both have now succeeded.

Upstream `ios-control/ios-deploy` was compiled locally with Apple clang for the
legacy device transport. Exact-UDID USB detection and installation succeed on
the confirmed target.

`ios/build/ipad/Install-Felicity.command` installed the final 0.4.16/20 on the Mac.
It checks the app signature, bundle/version, target inclusion and profile expiry,
then uses the locally compiled helper at `ios/build/device-tools/ios-deploy` to
install over the existing app through USB, with the exact known UDID and no
uninstall/debugger options. It does not change global permissions or restart any
system service. The helper's source provenance and licenses are adjacent to it.
The installer validated the version, signature and profile before reporting
`InstallComplete`. Installation of 0.4.16 is confirmed complete; final physical
darkness/motion acceptance remains pending. The user confirmed touch and
red-clock behavior on the preceding 0.4.15 build.

## Requested behaviour in 0.4.16/20

- Default: 60 seconds since touch or camera movement → a black screen with only
  large red time, date and household power consumption, at 4% brightness.
  Clock brightness is adjustable from 1–20%; timeout is 30 seconds to 5 minutes.
- Darkness shortcut: a smoothed light estimate below the adjustable threshold
  (default 0.18, range 0.05–0.45) for three seconds shows the clock without waiting
  for the full inactivity timeout. Smoothing occurs before that hold: allow
  roughly 5–10 seconds after covering the camera, pending physical timing
  confirmation. It triggers only once per dark episode. After motion
  or touch wakes the dashboard, normal inactivity applies until the scene
  becomes bright enough to rearm the shortcut; hysteresis avoids flicker.
- The clock redraws once per minute. Current power data refreshes every 30
  seconds, with no summary/status requests while idle. Normal dashboard polling
  keeps its existing 2-second cadence.
- Camera capture uses low resolution and a low supported frame rate. Processing
  compares an **8 × 6 brightness grid about once per second**. There is no Vision,
  face, body or other object recognition. A still person may let the display dim.
- Camera movement or touch wakes the dashboard. Dashboard brightness follows
  a camera-derived light estimate within **5–85%**, with a manual brightness
  adjustment. Automatic brightness changes happen at most once every 10 seconds.
  Motion sensitivity is adjustable. The camera estimate is not a calibrated lux
  measurement and does not use the restricted ambient-light sensor.
- Three-second recalibration after dim/wake avoids screen reflections causing
  immediate wake. Slow daylight drift and a single global flicker are filtered.
- Camera frames are processed in memory on the iPad, with no audio, recording or
  upload. The camera indicator stays visible while capture is running.
- Camera capture/idle clock pause outside the root energy dashboard. Brightness
  and idle-timer settings are restored when inactive/backgrounded or disabled.
- App locking, termination or background operation cannot perform presence wake.
  Keep Felicity open; Guided Access is optional for a dedicated wall display.

The reduced sampling, removed recognition, slower clock updates and reduced
network polling are intended to keep the work inexpensive. Actual battery or
wall-power consumption has not been measured on this iPad.

## Checks for the installed 0.4.16/20

The final signed native device build passed. Full XCTest execution passed
**55 tests, 0 failures**: 27 Dashboard tests, 16 Kiosk tests and 12 Presence tests.
Signature and profile validation passed; the exact requested iPad received the
app over USB with `InstallComplete` and exit code 0.

Verification artifacts:

- Device build log: `ios/build/recovery-device-0.4.16.log`
- Test log: `ios/build/recovery-tests-0.4.16.log`
- XCTest result bundle: `ios/build/recovery-tests-0.4.16.xcresult`
- Installation log: `ios/build/recovery-install-0.4.16.log`

The final physical darkness/motion test is pending. Actual energy use and
day/night adaptive-brightness behavior have not been measured.

### Confirmed 0.4.15/19 evidence

The final signed native device build passed. Full XCTest execution passed
**48 tests, 0 failures**: 27 Dashboard tests (including two polling tests),
9 Kiosk tests and 12 Presence tests.

Verification artifacts:

- Device build log: `ios/build/recovery-device-0.4.15-final.log`
- Test log: `ios/build/recovery-tests-0.4.15-final.log`
- XCTest result bundle: `ios/build/recovery-tests-0.4.15-final.xcresult`
- Installation log: `ios/build/recovery-install-0.4.15.log` (`InstallComplete`,
  exit code 0; installer verified signature and profile before installation)

These results validate the 0.4.15 build and automated behavior. The user also
confirmed physical touch controls and the red clock work. Motion sensitivity,
adaptive brightness and energy use remain unmeasured; these results do not
validate the new 0.4.16 darkness transition.

### Previous 0.4.14/18 evidence

The standard 0.4.14 `xcodebuild` physical-device build passed, including the two
follow-up source fixes, without the earlier compiler sandbox workaround. Full
XCTest execution on the **iPad Pro 13-inch (M5), iOS 26.5 simulator** passed
**38 tests, 0 failures** (25 baseline + 13 new).

0.4.14 verification artifacts (a subsequent build may replace these paths):

- Device build log: `ios/build/recovery-device.log`
- Test log: `ios/build/recovery-tests.log`
- XCTest result bundle: `ios/build/recovery-tests.xcresult`
- Final installation log: `ios/build/recovery-install.log` (`InstallComplete`,
  exit code 0; installer verified signature and profile before installation)

Version/firmware consistency, `git diff --check`, and Info.plist validation passed.
The prepared app was independently identified as 0.4.14/18. Installation on the
requested iPad and manual launch with dashboard data were confirmed before the
follow-up fixes; the final rebuilt bundle has now also been installed
successfully. Real-camera sensitivity, brightness restoration and the physical
clock acceptance checks below are not yet validated. On the installed 0.4.14
version, the user reported that leaving the camera's field of view for about
one minute did **not** show the clock. Settings → “Show clock now” also did not
display it. The user subsequently reported that touch controls were unresponsive
while data kept updating. The new passive touch observer is intended to address
this failure. The installed 0.4.15 replacement passed automated tests, and the
user subsequently confirmed touch controls and the red clock work.

## Pending 0.4.16/20 acceptance

The 0.4.16/20 build, automated tests and installation are complete. Record the
following physical results separately from confirmed 0.4.15 touch/clock behavior
and the earlier 0.4.14 evidence.

1. Confirm Settings, buttons, scrolling and manual clock preview still work.
2. Darken or cover the camera: once the smoothed light estimate remains below
   the chosen threshold for three seconds, the red clock appears. Allow roughly
   5–10 seconds from covering the camera and record the actual delay. Move or tap to wake in
   darkness; the dashboard should remain until ordinary inactivity expires.
   Brighten then darken again to verify the quick transition rearms.
3. Leave the scene still: the red time/date/home-load screen appears at the
   selected timeout and remains dim for two minutes without a self-wake loop.
   A still visible person is allowed to time out; no person detector is used.
4. Approach or pass beside the iPad in day/night lighting: motion wakes the
   dashboard, whose brightness follows the available light. Test sensitivity
   and brightness sliders in the actual installation position.
5. Confirm household power continues to update about every 30 seconds in clock
   mode, and stale/offline data is not presented as a fresh reading.
6. Touch clock, open settings/live/archive/details, rotate, lock/unlock and switch
   apps: no unintended clock overlay; normal brightness returns outside the mode.
7. Deny/re-enable permission, interrupt camera capture, and cover the camera:
   no crash; manual wake remains usable. Measure energy use before making
   quantitative power-saving claims.
