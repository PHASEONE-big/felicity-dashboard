# iOS follow-up work

## Weather — after the doorbell work

Requested on 2026-11-16 and explicitly deferred until the doorbell feature is
finished. It is not implemented in 0.4.19.

Version 0.4.19/23 is installed. The user deferred its physical ring/snapshot and
two-way audio checks; this does not mark those checks complete or start weather work.

- Use the configured location for weather.
- Show a cloud/weather icon and temperature on the clock screen.
- Add a small weather button at the top of the dashboard.
- Open a full-screen weather view with the current day's hourly forecast and
  a seven-day forecast.

Keep the existing low-energy intent when choosing refresh and rendering
behavior. Provider details and the weather implementation remain future work.
