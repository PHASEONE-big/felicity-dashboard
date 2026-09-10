# Android 0.7.25 — preserve short archive activities

VersionName: `0.7.25`; versionCode: `32`.

Physical testing of 0.7.24 on dragon exposed an additional cause of the original
boar-event problem. The recorder sends the animal activity's opening and closing
boundaries only 100 ms apart. Android removed the closing boundary because it
treated the same type within 250 ms as a duplicate. Both recordings consequently
disappeared from the ONVIF timeline and had no playback boundary. The recorder
could continue into another recording without a client seek.

Deduplication now removes only identical boundaries, comparing timestamp, UTC
offset, type, source, assertion state, motion and ring flags. Distinct opening
and closing boundaries survive. Existing six-second context around an activity
produces two separate intervals for the reported records:

- First boar card 02:19:23: interval 02:19:20.556–02:19:32.656.
- Second boar card 02:20:09: interval 02:20:07.076–02:20:19.176.

Times are local to the tablet on 2026-09-10 (UTC+02:00). These are AI coverage
intervals, including context; they are not measurements of animal visibility.
Automatic advancement after a complete AI interval remains supported.

Three regressions, including the observed boundary fields with relative times,
failed before the correction and pass afterward. All 65 Android unit tests
pass; the debug APK builds and its manifest reports 0.7.25/32. Client-version and
firmware-hash checks pass. iOS 0.4.13 (17) and ESP32/Nextion 0.14.1 are unchanged.

Installed over the existing app on dragon (TM15, Android 10), retaining settings.
Device package inspection confirms 0.7.25/32. The first card opens at 02:19:23;
the restored NEXT target is 02:20:07 and PREV returns to the first recording.
Rapid NEXT/PREV/NEXT settles on the final requested recording. Play/pause holds
the first scene at 02:19:24, and resume continues it. The log then records
`AI segment complete · next=02:20:07`, followed by a successful replay at that
target; the second boar is visible during playback. The recorder itself skips
gaps in stored video. Automatic advancement is retained, not disabled by this fix.

Screenshots and device logs are retained locally under the ignored directory
`android/app/build/device-validation-0.7.25/`; they are not published with code.

APK: `android/app/build/outputs/apk/debug/felicity-android-0.7.25.apk`

SHA-256: `5124ce1006a929ebadd3f32dbb8fc26b4f3628c47792efd63f6c53e323438ab9`
