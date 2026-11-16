# iOS follow-up work

## Weather — implemented in 0.4.21/25

Authorized on 2026-11-16 and now implemented: manual city search, a dashboard
weather button, weather on the idle clock, and a full-screen hourly/seven-day
forecast. All views share Open-Meteo data and a 30-minute foreground refresh
interval, without GPS. No default city is assigned to the user.

The final signed build, all 151 native simulator tests, simulator UI checks and
public-city API check passed. Version **0.4.21/25** was installed over Wi-Fi on
the exact requested iPad and verified by device lookup. Physical setup still
requires selecting the user's city, then checking the header, clock and forecast
page. See [weather handoff](IOS_WEATHER_HANDOFF.md)
for the implementation and current validation status.

Physical doorbell ring/snapshot and two-way audio checks remain deferred by the
user; adding weather does not mark those checks complete.
