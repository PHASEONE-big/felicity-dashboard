# iPad restoration and clock mode

Requested device: iPad Pro, user-confirmed current LAN address `192.168.13.188`.
Confirmed USB UDID: `86d36a369fdaeb458f5a65ba0136bec628ffd018`.
USB detection now identifies this device as **iPad Pro (9.7-inch), J127AP**,
running **iPadOS 16.7.16 (20H392)**.
Source: iOS **0.4.25, build 29**; its signed build, 159 tests and simulator
readout check passed. Wi-Fi installation did not complete; the signed IPA is
ready, and the installed version remains 0.4.24/28. See
[weather handoff](IOS_WEATHER_HANDOFF.md) for the actual-hour forecast label and
[doorbell handoff](IOS_DOORBELL_HANDOFF.md) for confirmed ring/thumbnail delivery
on 0.4.23 and the physically confirmed thumbnail controls on 0.4.24.
Last confirmed installation: **0.4.24, build 28**, over direct Wi-Fi, with
the installed version verified by device lookup. The user confirmed 0.4.21
works well on the physical iPad.
Android and hardware versions are unchanged.
The bundle identifier and configured signing team are preserved.

## Latest status — 2026-11-17

Version 0.4.25 displays **household consumption / solar generation**, in watts,
on the idle clock. Both values use the existing current snapshot and freshness
state; no polling requests or clock timers are added. The signed device build
and all 159 native simulator tests passed, with no new tests for this UI-only
change. The portrait simulator clock showed **1350 / 580 W**, matching Home
1350 W and Solar 580 W on the preceding dashboard. Both readings fit on one
line, weather remained below them, and the existing white/day and red/night
foreground handling is unchanged. Physical readout confirmation is pending.

Current release evidence:

- Signed build: `ios/build/recovery-device-0.4.25.log`.
- Tests/result: `ios/build/recovery-tests-0.4.25.log` and
  `ios/build/recovery-tests-0.4.25.xcresult`.
- Strict signature verification passed; the embedded profile includes the
  exact requested iPad and expires on 2026-11-21 at 17:20:22 UTC, unchanged.
- Verified IPA: `ios/build/ipad/Felicity-0.4.25-build29.ipa`.
  Previous app: `ios/build/ipad/installed-0.4.24-build28.app`.
- Wi-Fi installation did not complete. Logs:
  `ios/build/recovery-install-0.4.25-wifi.log`,
  `ios/build/recovery-install-0.4.25-wifi-retry.log`,
  `ios/build/recovery-install-0.4.25-wifi-unlocked.log` and
  `ios/build/recovery-install-0.4.25-wifi-final.log`.

Three standard attempts and a final attempt supplying the existing pairing
escrow to `StartService` failed after authenticating the exact trusted iPad.
AFC/installation service channels disconnected with `ConnectionTerminatedError`.
The final attempt exited with code 1 during the pre-install lookup, before any
package upload. This is a service-channel failure after a successful trusted
connection, not evidence that the device is offline or that the new readout or
IPA is defective. No further device attempts were made after the final try.
The installed app remains **0.4.24/28**; 0.4.25 has no physical acceptance.

The installed 0.4.24 passed its signed build and 159 tests. On 2026-11-17, the
user confirmed tapping its caller thumbnail reopens the full camera view with
Talk available, and X dismisses the card. Two-way audio remains unverified.

The preceding 0.4.20/24 combined Solar and Today series into one chart per screen;
its signed build and 125 tests passed, followed by a successful, version-verified
Wi-Fi installation. Physical feedback on these combined charts has not yet been
collected. The earlier 0.4.19/23 added doorbell calls and Today PV1/PV2 data; its final signed
release build and 125 tests passed, followed by a successful, version-verified
Wi-Fi installation. The user initially deferred physical ring/snapshot and
two-way audio checks; the later missed-ring failure on 0.4.22 is tracked in the
[doorbell handoff](IOS_DOORBELL_HANDOFF.md); kiosk history below is retained.

The subsequent **0.4.18/22** chart release passed its signed build and all
81 simulator tests, then was installed and version-verified over Wi-Fi on this
exact iPad. The user confirmed improved portrait readability, working point
inspection and smooth vertical scrolling. See the
[charts handoff](IOS_CHARTS_HANDOFF.md). The kiosk validation below records 0.4.17.

**0.4.17/21** adds white daytime and red nighttime clocks, plus independent
day/night brightness settings for the dashboard and clock. Selected brightness
applies directly up to 100%, replacing the old 85% dashboard cap and brightness
bias. Existing nighttime clock brightness is preserved. Camera sampling, motion
detection, the darkness shortcut and idle polling are unchanged.

The signed device build and all **62 simulator tests passed**. With the exact
iPad connected by USB, signature/profile verification passed and installation
of **0.4.17/21** completed with `InstallComplete` and exit code 0. The same IPA
was then installed over direct Wi-Fi, with installation progress reaching 100%
and a subsequent device lookup confirming version 0.4.17/build 21. The user
confirmed that the daytime clock is white and dashboard brightness on wake is
now sufficient.

The earlier wireless probes failed while `EnableWifiConnections` was false.
It was enabled through the existing trusted USB pairing and read back as true.
Direct TCP authentication then verified the same iPad UDID using the existing
pairing record; no automatic pairing was needed.

## Historical recovery — 2026-11-14

Recovery used branch **`codex/ios-kiosk-recovery`**, preserving the uncommitted
changes. At that task's start, fetching succeeded and HEAD/upstream were both
`2935d4a`, with ahead/behind counts `0 0`.

The signed 0.4.14/18 restored the app and dashboard data, but physical testing
exposed unresponsive touch controls. Version 0.4.15/19 replaced the global
SwiftUI drag gesture with a passive UIKit touch observer and removed Vision
recognition. Its build, 48 simulator tests and exact-device USB installation
passed; the user confirmed working touch controls and the red clock.

Version 0.4.16/20 added the three-second darkness hold after the smoothed light
estimate crosses the threshold. Its signed build, 55 simulator tests and USB
installation passed. On 2026-11-14 the user confirmed that covering the camera
shows the red clock and hand movement returns the dashboard. Exact latency,
overnight stability and energy use were not measured. Historical results and
artifact paths are retained below.

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

Verified 0.4.17/21 products; this build is installed on the requested iPad:

- `ios/build/ipad/Payload/Felicity Dashboard.app`
- `ios/build/ipad/Felicity-0.4.17-build21.ipa`

The preceding installed build is preserved as
`ios/build/ipad/confirmed-0.4.16-build20.app` and
`ios/build/ipad/Felicity-0.4.16-build20.ipa`. The 0.4.15 build with physically
confirmed touch/clock behavior is retained as
`ios/build/ipad/confirmed-0.4.15-build19.app` and
`ios/build/ipad/Felicity-0.4.15-build19.ipa`. The previous 0.4.14 products are
retained locally, including `ios/build/ipad/Felicity-0.4.14-build18.ipa`.
The initial signed products are preserved as `ios/build/ipad/initial-build18.app` and
`ios/build/ipad/Felicity-0.4.14-build18.initial.ipa`.

The native 0.4.17 device build and simulator tests passed; see the checks below.

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

`ios/build/ipad/Install-Felicity.command` installed 0.4.17/21 over USB on the Mac.
It checks the app signature, bundle/version, target inclusion and profile expiry,
then uses the locally compiled helper at `ios/build/device-tools/ios-deploy` to
install over the existing app through USB, with the exact known UDID and no
uninstall/debugger options. It does not change global permissions or restart any
system service. The helper's source provenance and licenses are adjacent to it.
The installer validated the version, signature and profile before reporting
`InstallComplete`. Earlier basic darkness/motion transitions were physically
confirmed on 0.4.16; touch and red-clock behavior were confirmed on 0.4.15.
The user also confirmed the white daytime clock and dashboard wake brightness
on 0.4.17.

### Verified Wi-Fi path

The trusted iPad at `192.168.13.188` accepted an actual network installation of
0.4.17/21. Keep the Mac and iPad on the same Wi-Fi network. To reinstall this
verified package with the helper pinned to the exact iPad and IPA:

```sh
/private/tmp/felicity-network-ios-env/bin/python /private/tmp/felicity-install-known-ipad-wifi.py
```

The helper uses `pymobiledevice3` 11.55.1, the existing Mac pairing record and
`autopair=False`; it verifies the device identity and installed version. Its
IPA path and version assertions are specific to 0.4.17/21; update both for a
future release before running it. Its runtime and script are temporary
`/private/tmp` files. The successful run is
recorded in `ios/build/recovery-install-0.4.17-wifi.log`.

## Behaviour in 0.4.17/21

- Default: 60 seconds since touch or camera movement → a black screen with only
  large time, date and household power consumption: **white in daylight, red
  at night**. Timeout is adjustable from 30 seconds to 5 minutes.
- Four independent brightness settings apply directly: day dashboard defaults
  to **100%**, night dashboard to **12%**, day clock to **50%**, and night clock
  preserves the legacy clock setting (otherwise **4%**). Dashboard settings
  allow 5–100%; clock settings allow 1–100%. The old brightness bias is ignored.
- Day/night mode uses the existing darkness threshold and a 0.06 hysteresis gap.
  Clock color and brightness change together. Motion/touch wake immediately
  applies the selected dashboard brightness; disabling adaptive dashboard
  brightness uses the day dashboard value in both modes.
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
- Camera movement or touch wakes the dashboard. Motion sensitivity is
  adjustable. The camera estimate is not a calibrated lux
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

## Checks for 0.4.17/21

The signed native device build passed. Full XCTest execution passed
**62 tests, 0 failures**: 27 Dashboard tests, 23 Kiosk tests and 12 Presence tests.
The new checks cover explicit brightness up to 100%, day/night mode hysteresis,
legacy clock-setting migration and preference persistence. Code-signature
verification passed, and the profile includes the exact requested iPad UDID
with the unchanged expiry shown above. The USB installer rechecked the signature
and profile, then reported `InstallComplete` and exit code 0 on that exact iPad.
The same IPA was subsequently installed through authenticated direct TCP over
Wi-Fi; InstallationProxy reached 100%, and a network lookup verified 0.4.17/21.
The user confirmed the white daytime clock and sufficient dashboard brightness
on wake. These checks do not constitute a power measurement or exhaustive
regression testing.

Verification artifacts:

- Device build log: `ios/build/recovery-device-0.4.17.log`
- Test log: `ios/build/recovery-tests-0.4.17.log`
- XCTest result bundle: `ios/build/recovery-tests-0.4.17.xcresult`
- Installation log: `ios/build/recovery-install-0.4.17.log`
- Wi-Fi installation log: `ios/build/recovery-install-0.4.17-wifi.log`

## Historical checks — installed 0.4.16/20

The final signed native device build passed. Full XCTest execution passed
**55 tests, 0 failures**: 27 Dashboard tests, 16 Kiosk tests and 12 Presence tests.
Signature and profile validation passed; the exact requested iPad received the
app over USB with `InstallComplete` and exit code 0.

Verification artifacts:

- Device build log: `ios/build/recovery-device-0.4.16.log`
- Test log: `ios/build/recovery-tests-0.4.16.log`
- XCTest result bundle: `ios/build/recovery-tests-0.4.16.xcresult`
- Installation log: `ios/build/recovery-install-0.4.16.log`

On 2026-11-14 the user confirmed the physical cover/uncover-and-move test:
red clock on darkness, dashboard on movement. Exact transition latency was not
measured. The user plans an overnight run; its outcome, actual energy use and
day/night adaptive-brightness behavior remain unverified.

### Historical 0.4.15/19 evidence

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

### Historical 0.4.14/18 evidence

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

## Physical acceptance and regression checklist

On 2026-11-16 the user confirmed the white daytime clock and sufficient
dashboard brightness on wake in 0.4.17. Darkness/motion transitions were
confirmed on 0.4.16. The checklist below is retained for broader regression
coverage in future changes; not every scenario has been executed.

1. Confirm Settings, buttons, scrolling and manual clock preview still work.
2. Darken or cover the camera: once the smoothed light estimate remains below
   the chosen threshold for three seconds, the red clock appears. Allow roughly
   5–10 seconds from covering the camera and record the actual delay. Move or tap to wake in
   darkness; the dashboard should remain until ordinary inactivity expires.
   Brighten then darken again to verify the quick transition rearms.
3. Leave the scene still: the time/date/home-load screen appears at the selected
   timeout, white in daylight and red in darkness, without a self-wake loop.
   A still visible person is allowed to time out; no person detector is used.
4. Approach or pass beside the iPad in day/night lighting: motion wakes the
   dashboard at its selected day/night brightness. Set day dashboard brightness
   to 100% and confirm full output; test all four brightness settings, including
   lower night values and persistence after relaunch. Clock color and brightness
   should switch together, without flicker near the threshold.
5. Confirm household power continues to update about every 30 seconds in clock
   mode, and stale/offline data is not presented as a fresh reading.
6. Touch clock, open settings/live/archive/details, rotate, lock/unlock and switch
   apps: no unintended clock overlay; normal brightness returns outside the mode.
7. Deny/re-enable permission, interrupt camera capture, and cover the camera:
   no crash; manual wake remains usable. Measure energy use before making
   quantitative power-saving claims.
