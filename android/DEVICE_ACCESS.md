# Dragon ADB access

The development tablet identifies as **TM15**, device **ceres-aw**, Android 10.
Its serial and last known LAN endpoint are kept in the ignored local file
`android/local-device.json`. Device addresses and serials are not committed.

From the active repository root, run:

```sh
python3 android/tools/connect_dragon.py
```

The helper discovers the tablet's `_adb._tcp.` mDNS advertisement, connects to
the advertised endpoint and verifies the Android serial. If discovery is
unavailable it tries the saved endpoint, still verifying the device identity.
It prints the connected endpoint and updates the local address cache. It does
not install APKs or change tablet settings.

An empty `adb devices -l` list does **not** establish that the tablet is offline:
a newly started ADB server may need an explicit network connection. Check
`adb mdns services`, then connect. In a sandbox that blocks ADB's local server
socket or LAN access, run the ADB command through the normal approved host
execution path; do not mistake sandbox denial for device unavailability.

On a new Mac/workspace, create `android/local-device.json` with these fields:

```json
{
  "serial": "SERIAL_FROM_THE_TABLET",
  "last_endpoint": "TABLET_IP:5555"
}
```

Confirm the serial on a known/authorized connection with
`adb -s TABLET_IP:5555 shell getprop ro.serialno`. An `unauthorized` result
requires the user to accept the debugging prompt on that device. Do not change
ADB keys or restart debugging on unrelated devices.

Connection recovery on 2026-09-10 succeeded through mDNS and `adb connect` with
the Mac's existing key; no new pairing or tablet configuration was needed.
At that check, the installed Felicity version was still 0.7.23 (30).
