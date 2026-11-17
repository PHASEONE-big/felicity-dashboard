# iOS follow-up work

## Clock consumption / solar — 0.4.26/30

Current source and confirmed installation are **0.4.26/30**, adding a sun icon
beside solar generation and a
Spanish weekday/month on the idle clock, retaining the same data, font and
white/day versus red/night colors. Its final signed build, 159 native simulator
tests and portrait UI check passed: the date remained Spanish under a Russian
simulator locale. USB installation completed and a separate exact-device USB
lookup verified **0.4.26/30**. Physical icon/date confirmation is pending.

Version 0.4.25 displays household consumption / solar generation in watts on
the idle clock. Both values come from the same current snapshot and
share freshness handling, without new polling requests or clock timers. Its
signed build, 159 native simulator tests and portrait clock readout check
passed. Earlier Wi-Fi attempts failed in device service channels; after the
user connected USB, installation completed and a separate exact-device USB
lookup verified **0.4.25/29**. The user acknowledged that installed version on
2026-11-17 and requested the sun icon. See
[kiosk handoff](IOS_KIOSK_HANDOFF.md).

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
clock layout is pending. Version **0.4.23/27** replaces **In 6h** with
the outlook's actual hour in the forecast city's time zone, using the same
cache. Its signed build, 154 native simulator tests and portrait clock-label
check passed. Direct Wi-Fi installation completed and device lookup verified
**0.4.23/27**.
See [weather handoff](IOS_WEATHER_HANDOFF.md)
for the implementation and current validation status.

## Doorbell — thumbnail controls confirmed

The user reported that a real ring did not open the doorbell while 0.4.22's idle
clock was visible in the foreground. Recorder probes identified an unterminated
HTTP 401 response on a keep-alive connection; 0.4.23 aligns the event transport
with the existing `Connection: close` discovery path. The signed build and all
154 tests passed, and 0.4.23 is installed and version-verified. After the user
opened it on 2026-11-17, a fresh exact-device probe confirmed **Listening for
doorbell**. The user then confirmed that a real ring opened the call and its
thumbnail appeared after the call ended, but the close button did not respond.

Version **0.4.24/28** repairs the overlay hit region and close button,
retains tapping the image to reopen live video and explicitly stops audio before
reopening. Its signed build, 159 native simulator tests and simulator control
checks passed. Direct Wi-Fi installation completed and device lookup verified
**0.4.24/28**. On 2026-11-17 the user confirmed both physical actions: tapping
the thumbnail reopens the full camera view with the Talk button, and X dismisses
the card. Two-way audio remains unverified. See
[doorbell handoff](IOS_DOORBELL_HANDOFF.md).
