# Android 0.7.24 — event archive playback

VersionName: `0.7.24`; versionCode: `31`.

Opening a pet event and playing its archive could finish at the end of an
overlapping person detection, skipping the remainder of the pet recording.
The player now uses merged continuous AI coverage, anchored to the selected
playback target. Missing metadata no longer invents a 15-second segment or
selects an already-ended neighboring event.

Late event-list/image responses no longer restart a direct RTSP session or
replace its decoded image. Seek generations are carried through RTSP, decoder
input and render callbacks; old PLAY responses and frames cannot advance the
current playhead. Repeated seeks to the same absolute time use distinct decoder
timestamps. Play/pause preserves strict event selection after entry from a card,
so replay errors cannot silently fall back to a different card. Session reuse
and automatic advancement after a complete AI interval remain supported.

Validation: all 62 Android unit tests passed (11 new regressions), debug APK
built, manifest reports 0.7.24/31, and its signing certificate matches the
original 0.7.23 APK. Client-version and hardware artifact checks passed.
At build time no ADB device was connected. Subsequent physical testing found a
remaining metadata deduplication bug; see [Android 0.7.25](ANDROID_0.7.25.md).
iOS and ESP32/Nextion source versions were not changed.

Local APK: `android/app/build/outputs/apk/debug/felicity-android-0.7.24.apk`

SHA-256: `b68a8ceca553eb4f542cc05e59ffce2f97a30f2e6f406449a00ae93990bdf6e6`
