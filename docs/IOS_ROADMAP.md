# iOS follow-up work

## Weather — implemented in 0.4.21/25

Authorized on 2026-11-16 and now implemented: manual city search, a dashboard
weather button, weather on the idle clock, and a full-screen hourly/seven-day
forecast. All views share Open-Meteo data and a 30-minute foreground refresh
interval, without GPS. No default city is assigned to the user.

The 0.4.21 signed build, all 151 native simulator tests, simulator UI checks and
public-city API check passed. Version **0.4.21/25** was installed over Wi-Fi on
the exact requested iPad and verified by device lookup. The user confirmed
that version works well on the physical iPad.

Version **0.4.22/26** replaces the idle clock's city label with compact
**Now → +6h** weather icons and temperatures, using the existing hourly cache
without new requests or timers. Its signed build, 154 native simulator tests
and simulator clock-layout check passed. Direct Wi-Fi installation completed
and device lookup verified **0.4.22/26**. Physical confirmation of the new
clock layout is pending. Current source **0.4.23/27** replaces **In 6h** with
the outlook's actual hour in the forecast city's time zone, using the same
cache. Its signed build, 154 native simulator tests and portrait clock-label
check passed. Direct Wi-Fi installation completed and device lookup verified
**0.4.23/27**.
See [weather handoff](IOS_WEATHER_HANDOFF.md)
for the implementation and current validation status.

## Doorbell — missed ring under repair

The user reported that a real ring did not open the doorbell while 0.4.22's idle
clock was visible in the foreground. Recorder probes identified an unterminated
HTTP 401 response on a keep-alive connection; 0.4.23 aligns the event transport
with the existing `Connection: close` discovery path. The signed build and all
154 tests passed, and 0.4.23 is installed and version-verified. After the user
opened it on 2026-11-17, a fresh exact-device probe confirmed **Listening for
doorbell**. The user's real-ring and post-timeout thumbnail check is pending;
two-way audio remains unverified. See
[doorbell handoff](IOS_DOORBELL_HANDOFF.md).
