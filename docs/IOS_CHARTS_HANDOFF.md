# iOS energy charts — 0.4.18, build 22

Current source and confirmed installation are **0.4.22/26**. Its signed build,
154 tests and simulator clock check passed; exact-device Wi-Fi installation
and version lookup succeeded. The new clock layout awaits physical confirmation;
the preceding 0.4.21 received positive overall user feedback.
See [weather handoff](IOS_WEATHER_HANDOFF.md) for evidence and the new clock
layout. Chart behavior is unchanged from 0.4.20/24:
Solar has Total/PV1/PV2 together in one chart and
Today has Solar/Load/PV1/PV2 together in one chart. PV1 stays blue and PV2 purple;
legend toggles and point inspection remain. The 0.4.20 signed native build and all
125 tests passed; Wi-Fi installation succeeded and a subsequent device lookup
verified 0.4.20/build 24. Physical feedback on the combined charts has not yet
been collected.
Real ring/snapshot and two-way audio checks were deferred by the user. See the
[doorbell and Today handoff](IOS_DOORBELL_HANDOFF.md). The 0.4.18 evidence below
records the latest user-confirmed physical chart validation.

On 2026-11-16, **0.4.18/22** was installed and confirmed. The
simulator suite passed all **81 tests**: 62 existing tests, 10 chart-loading
tests and 9 chart-data tests. The final signed device build passed. Signature
and provisioning checks verified the exact target iPad, then direct Wi-Fi
installation reached 100% and exited with code 0. A subsequent device lookup
confirmed version 0.4.18/build 22. On 2026-11-16 the user confirmed that the
portrait charts are noticeably better and that point inspection and vertical
scrolling work smoothly on the physical iPad.
The preceding 0.4.17/21 daytime clock and wake brightness were confirmed by the user.
Earlier kiosk recovery and the verified Wi-Fi installation path remain in
[IOS_KIOSK_HANDOFF.md](IOS_KIOSK_HANDOFF.md).

## Behavior

- Energy details use a normal vertical ScrollView with current readings and
  six metric buttons. Current, summary and server-status polling continues on
  the detail page, so live values do not freeze while a chart is open.
- Panels stack in portrait and can sit side by side in landscape. Watts,
  volts, percentages and temperatures have distinct panels and scales.
- Legend buttons toggle individual series. A tap or horizontal drag inspects
  a sample; vertical gestures scroll the page. VoiceOver can move the selected
  sample through an accessibility adjustment action.
- Null, missing-channel and nonfinite data split line segments. Power domains
  preserve negative values, and dates use the returned start/end and interval
  metadata. Without timing metadata, labels identify sample positions.
- Each panel uses one Canvas for axes and paths, with no view per sample or
  continuous chart animation. Equatable panels keep unrelated current-reading
  updates from redrawing an unchanged chart. The client retains all server
  buckets, typically 180 for energy and 60 for System; no downsampling is added.
- Cache keys include server and metric. Fresh energy charts last 60 seconds;
  System lasts 10 seconds. Cached charts appear immediately, including stale
  charts while refreshing. Foreground detail pages poll at those intervals;
  manual refresh bypasses the cache. Leaving the route invalidates its request
  generation without discarding the cache.
- Old metric/server responses and canceled requests cannot replace the current
  route. Cancellation does not show an error; a refresh failure preserves
  visible chart data. Identical chart responses are not republished.

## Validation and artifacts

The simulator checks covered portrait Home Load and Battery, point inspection,
and landscape Battery panels side by side. The 19 new tests cover timing,
gaps, channel/unit mappings, signed domains, cache lifetimes and server
partitioning, late responses, cancellation, invalid-server state and preserving
visible charts after refresh failures.

Build/test evidence is kept locally under the ignored `ios/build/` directory:

- Final device build: `ios/build/recovery-device-0.4.18-final.log`.
- Tests: `ios/build/recovery-tests-0.4.18.log`.
- Result bundle: `ios/build/recovery-tests-0.4.18.xcresult`.
- Wi-Fi installation: `ios/build/recovery-install-0.4.18-wifi.log`.
- Installed IPA: `ios/build/ipad/Felicity-0.4.18-build22.ipa`.
- Current app: `ios/build/ipad/Payload/Felicity Dashboard.app`.
- Previous working app: `ios/build/ipad/confirmed-0.4.17-build21.app`.

The existing signing profile still expires on 2026-11-21 at 17:20:22 UTC
(18:20:22 in Madrid); this release does not extend that expiry.

Portrait readability, point inspection and smooth vertical scrolling were
confirmed by the user on the installed 0.4.18 build. Metric switching, legend
toggles and rotation remain useful regression checks; they were not separately
confirmed in that feedback.
No physical frame-rate, battery-use or wall-power measurements have been made.
Doorbell work is outside this release.
