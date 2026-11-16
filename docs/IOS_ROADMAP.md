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

Current source **0.4.22/26** replaces the idle clock's city label with compact
**Now → +6h** weather icons and temperatures, using the existing hourly cache
without new requests or timers. Its signed build, 154 native simulator tests
and simulator clock-layout check passed. Direct Wi-Fi installation completed
and device lookup verified **0.4.22/26**. Physical confirmation of the new
clock layout is pending.
See [weather handoff](IOS_WEATHER_HANDOFF.md)
for the implementation and current validation status.

Physical doorbell ring/snapshot and two-way audio checks remain deferred by the
user; adding weather does not mark those checks complete.
