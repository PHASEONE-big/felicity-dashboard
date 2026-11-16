# iOS weather — 0.4.21, build 25

## Status — 2026-11-16

Weather is implemented in source **0.4.21/25**. The final signed device build
and all **151 native simulator tests passed**, including 26 weather tests.
Simulator UI checks and the live public-city API check passed. Direct Wi-Fi
installation of the final build reached 100% and exited with code 0 on the exact
requested iPad; a subsequent device
lookup verified **0.4.21/build 25**. The physical iPad has no selected weather
city yet, and physical weather acceptance remains pending. No user location has
been assumed or written as a default.

## Behavior and setup

- Choose a city in **Settings → Weather location**. Search starts after two
  characters and a 500 ms pause, returning at most five matches. The selected
  city persists locally. There is no GPS request or automatic location access.
- One shared forecast feeds the dashboard's small weather button, the idle
  clock's weather icon/temperature/city, and the full-screen weather page.
  The clock retains its white daytime/red nighttime appearance.
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

## Validation and remaining checks

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

Select the user's actual city and verify the dashboard
weather button, full-screen hourly/week display and weather on the idle clock.
Those physical checks are not yet confirmed. Earlier doorbell audio/ring checks
remain deferred. See [kiosk recovery](IOS_KIOSK_HANDOFF.md) for the exact target
iPad and signing/install path.
