# iOS weather — 0.4.23, build 27

## Status — 2026-11-16

Current source and confirmed installation are **0.4.23/27**. The idle clock
labels its six-hour outlook with
the forecast's actual local hour, replacing **In 6h**. It uses the forecast
city's time zone and the same hourly cache, with no additional requests or
timers. Its signed build and all 154 native simulator tests passed. Exact-device
Wi-Fi installation reached 100%, exited with code 0 and was version-verified.
The portrait simulator displayed **Now** cloud/temperature →
**23:00** moon-cloud/temperature, with no **In 6h** or city-name label.
See [release evidence](IOS_DOORBELL_HANDOFF.md#release-checks-for-042327) for
the current build, tests, signature and package.

The preceding **0.4.22/26** passed its signed build and 154 tests, and its
exact-device Wi-Fi installation was version-verified.
The user reported a missed doorbell ring while its idle clock was visible;
the separate transport fix is tracked in [doorbell handoff](IOS_DOORBELL_HANDOFF.md).

The preceding **0.4.21/25** was confirmed by the user to work well on the
physical iPad. Its signed build, 151 simulator tests,
UI/API checks and exact-device Wi-Fi installation passed; evidence is retained
below. The new actual-hour label has not yet received physical confirmation.
No user location is assigned as a source default.

## Behavior and setup

- Choose a city in **Settings → Weather location**. Search starts after two
  characters and a 500 ms pause, returning at most five matches. The selected
  city persists locally. There is no GPS request or automatic location access.
- One shared forecast feeds the dashboard's small weather button, the idle
  clock's **Now → forecast hour** icons and temperatures, and the full-screen weather page.
  The clock has no city-name label and retains its white daytime/red nighttime
  appearance. The six-hour outlook uses the same cached hourly forecast, and
  its displayed hour uses the forecast city's time zone.
- The weather page shows current conditions, the selected city's hourly entries
  for today and the seven-day forecast, with refresh and city controls. The
  hourly strip initially scrolls to the current hour. Weather pauses the idle
  clock and presence camera; a foreground doorbell call still takes priority.
- Empty, loading, failure and saved-forecast states are visible. Switching city
  clears the previous city's forecast, and canceled or late responses cannot
  overwrite the new selection.

## Data, time and power

The provider is [Open-Meteo](https://open-meteo.com/), using its public
[Forecast API](https://open-meteo.com/en/docs) and
[Geocoding API](https://open-meteo.com/en/docs/geocoding-api). The weather page
links its Open-Meteo attribution. No API key is required by these endpoints;
geocoding location data comes from [GeoNames](https://www.geonames.org/).
Search text goes to the geocoding endpoint and the selected coordinates to the
forecast endpoint. Neither is logged by the client.

Forecast requests use Celsius, km/h, seven days, `timezone=auto` and Unix
timestamps. Current conditions include temperature, feels-like temperature,
humidity, wind and cloud cover. Hourly entries include condition codes,
day/night flags and precipitation probability. Daily entries carry minimum and
maximum temperatures and precipitation probability. Missing/invalid series
rows are skipped; missing optional values do not become zeros.

Hourly labels and today's boundaries use the returned named time zone, including
23- and 25-hour daylight-saving days. Daily dates compensate for the API's fixed
request-time UTC offset so a later DST change does not shift the displayed day.

The foreground refresh interval is 30 minutes, shared by all three views.
Automatic requests have a five-minute minimum retry delay after a failure;
manual refresh can retry immediately. The small local forecast cache is usable
for up to six hours. Saved data is marked stale after one hour, a refresh error
or a change of local day. Backgrounding cancels the refresh loop. Requests have
a 12-second timeout, and weather adds no GPS, extra camera work or continuous
animation. Physical energy use has not been measured.

## Historical validation of 0.4.22/26

- Signed device build passed: `ios/build/recovery-device-0.4.22.log`.
- All 154 native simulator tests passed with no failures, including 15
  weather model/service and 14 weather view-model tests. Evidence:
  `ios/build/recovery-tests-0.4.22.log` and
  `ios/build/recovery-tests-0.4.22.xcresult`.
- In the portrait simulator, **Show clock now** displayed the white clock and
  **Now** cloud/temperature → **In 6h** moon-cloud/temperature, with no city
  name. The existing shared foreground color still supplies red night mode;
  the new layout has not yet been physically confirmed.
- Strict signature verification passed. The embedded profile includes the
  exact requested iPad and expires on 2026-11-21 at 17:20:22 UTC, unchanged.
- Verified package: `ios/build/ipad/Felicity-0.4.22-build26.ipa`.
  Previous installed app: `ios/build/ipad/installed-0.4.21-build25.app`.
  Successful exact-device Wi-Fi installation and version verification log:
  `ios/build/recovery-install-0.4.22-wifi.log`.

## Historical validation of 0.4.21/25

- Swift model/service typechecking and source parse checks passed.
- The production Swift service successfully searched and fetched the public
  demonstration city Madrid: five location matches, `Europe/Madrid`, 168 hourly
  entries with day/night flags, 24 entries for that day and seven daily entries.
  Madrid was used only for API smoke testing and simulator demonstration, not
  as the user's location.
- All 151 native simulator tests passed. Twelve model/service tests cover
  request parameters, city-name encoding,
  invalid current data, null/short arrays, DST boundaries, condition symbols
  and cache round-trips. Fourteen view-model tests cover caching and request
  lifecycles, including cancellation cleanup and rapid background/foreground
  restarts without an old refresh loop canceling the new request.
- Simulator UI checks used manual search for Madrid, Spain: the header showed
  its current temperature; the weather page opened with today's hour strip,
  all seven daily entries and conditions accessible by scrolling. **Show clock
  now** displayed the white idle clock with a cloud icon, temperature and city.
  These checks do not establish physical iPad acceptance.
- Final signed build log: `ios/build/recovery-device-0.4.21-final2.log`.
  Test log/result: `ios/build/recovery-tests-0.4.21-final2.log` and
  `ios/build/recovery-tests-0.4.21-final2.xcresult`.
- Strict code-signature verification passed. The embedded provisioning profile
  contains the exact requested iPad UDID and still expires on 2026-11-21 at
  17:20:22 UTC; this release does not extend that expiry.
- Exact-device trusted Wi-Fi installation log:
  `ios/build/recovery-install-0.4.21-wifi-final2.log`. Installed IPA:
  `ios/build/ipad/Felicity-0.4.21-build25.ipa`. The previous app is retained at
  `ios/build/ipad/installed-0.4.20-build24.app`.

The user subsequently confirmed that 0.4.21 works well on the physical iPad;
this was an overall acceptance, not a report of separate checks for each view.
Physical validation of the new 0.4.23 forecast-hour label is pending. The missed
ring on 0.4.22 is under repair; two-way audio remains unverified. See
[kiosk recovery](IOS_KIOSK_HANDOFF.md) for the exact
target iPad and signing/install path.
