import XCTest
@testable import FelicityDashboard

final class KioskIdlePolicyTests: XCTestCase {
    @MainActor
    func testLegacyClockBrightnessMigratesWithoutLimitingDayDashboard() throws {
        let suite = "Felicity.KioskMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.17, forKey: "kiosk.clockBrightness")
        defaults.set(0.25, forKey: "kiosk.brightnessAdjustment")

        let controller = KioskController(defaults: defaults)

        XCTAssertEqual(controller.nightClockBrightness, 0.17)
        XCTAssertEqual(controller.dayClockBrightness, 0.5)
        XCTAssertEqual(controller.dayDashboardBrightness, 1)
        XCTAssertEqual(controller.nightDashboardBrightness, 0.12)
    }

    @MainActor
    func testExplicitDayNightBrightnessPreferencesRestoreAndPersist() throws {
        let suite = "Felicity.KioskBrightness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.7, forKey: "kiosk.clockBrightness")
        defaults.set(1.0, forKey: "kiosk.dayClockBrightness")
        defaults.set(0.09, forKey: "kiosk.nightClockBrightness")
        defaults.set(1.0, forKey: "kiosk.dayDashboardBrightness")
        defaults.set(0.16, forKey: "kiosk.nightDashboardBrightness")

        let controller = KioskController(defaults: defaults)
        XCTAssertEqual(controller.dayClockBrightness, 1)
        XCTAssertEqual(controller.nightClockBrightness, 0.09)
        XCTAssertEqual(controller.dayDashboardBrightness, 1)
        XCTAssertEqual(controller.nightDashboardBrightness, 0.16)

        controller.dayClockBrightness = 0.75
        controller.nightClockBrightness = 0.12
        controller.nightDashboardBrightness = 0.2
        let restored = KioskController(defaults: defaults)
        XCTAssertEqual(restored.dayClockBrightness, 0.75)
        XCTAssertEqual(restored.nightClockBrightness, 0.12)
        XCTAssertEqual(restored.dayDashboardBrightness, 1)
        XCTAssertEqual(restored.nightDashboardBrightness, 0.2)
    }

    func testSelectedDashboardDayAndNightBrightnessAreUsedDirectly() {
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: false, day: 0.9, night: 0.35, adaptive: true), 0.9)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: true, day: 0.9, night: 0.35, adaptive: true), 0.35)
    }

    func testSelectedBrightnessClampsBoundsAndRemainsFinite() {
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: false, day: 2, night: -1, adaptive: true), 1)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: true, day: 2, night: -1, adaptive: true), 0.05)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: false, day: .nan, night: 0.2, adaptive: true), 0.05)
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: false, day: 2, night: -1), 1)
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: true, day: 2, night: -1), 0.01)
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: true, day: 0.8, night: .nan), 0.01)
    }

    func testDashboardDaySettingCanReachFullBrightness() {
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: false, day: 1, night: 0.2, adaptive: true), 1)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: false, day: 1, night: 0.2, adaptive: false), 1)
    }

    func testManualDashboardBrightnessIgnoresAmbientMode() {
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: true, day: 0.9, night: 0.1, adaptive: false), 0.9)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(isNight: true, day: 0.25, night: 0.8, adaptive: false), 0.25)
    }

    func testClockUsesIndependentDayAndNightBrightness() {
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: false, day: 0.75, night: 0.18), 0.75)
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: true, day: 0.75, night: 0.18), 0.18)
        XCTAssertEqual(KioskBrightnessPolicy.clock(isNight: true, day: 0.75, night: 1), 1)
    }

    func testLightModeUsesHysteresisAroundDarkThreshold() {
        var mode = KioskLightMode()
        let threshold = 0.18
        mode.update(level: threshold, darkThreshold: threshold)
        XCTAssertFalse(mode.isNight)
        mode.update(level: 0.17, darkThreshold: threshold)
        XCTAssertTrue(mode.isNight)
        mode.update(level: 0.23, darkThreshold: threshold)
        XCTAssertTrue(mode.isNight)
        mode.update(level: threshold + 0.06, darkThreshold: threshold)
        XCTAssertFalse(mode.isNight)
        mode.update(level: 0.21, darkThreshold: threshold)
        XCTAssertFalse(mode.isNight)
        mode.update(level: 0.17, darkThreshold: threshold)
        XCTAssertTrue(mode.isNight)
    }

    func testLightModeIgnoresMissingAndInvalidSamples() {
        var mode = KioskLightMode()
        let invalidLevels: [Double?] = [nil, .nan, .infinity, -0.1, 1.1]
        for level in invalidLevels {
            mode.update(level: level, darkThreshold: 0.18)
            XCTAssertFalse(mode.isNight)
        }
        mode.update(level: 0.1, darkThreshold: 0.18)
        for level in invalidLevels {
            mode.update(level: level, darkThreshold: 0.18)
            XCTAssertTrue(mode.isNight)
        }
        mode.update(level: 1, darkThreshold: .nan)
        XCTAssertTrue(mode.isNight)
    }

    func testSleepsExactlyAtInactivityThreshold() {
        var policy = KioskIdlePolicy(now: 100)

        policy.update(at: 159.9, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)

        policy.update(at: 160, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testRepeatedPresenceOrTouchesHoldDashboardAwake() {
        var policy = KioskIdlePolicy(now: 0)

        for now in stride(from: 30.0, through: 300.0, by: 30.0) {
            policy.recordActivity(at: now)
            policy.update(at: now, idleTimeout: 60, eligible: true)
            XCTAssertFalse(policy.isSleeping)
        }

        policy.update(at: 359, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 360, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testActivityWakesClockAndStartsNewIdlePeriod() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 60, idleTimeout: 60, eligible: true)

        policy.recordActivity(at: 75)
        XCTAssertFalse(policy.isSleeping)
        XCTAssertEqual(policy.lastActivity, 75)

        policy.update(at: 134, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 135, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testIneligibleRouteWakesAndDefersSleepAfterReturning() {
        var policy = KioskIdlePolicy(now: 0)
        policy.showClock(at: 10)

        policy.update(at: 120, idleTimeout: 60, eligible: false)
        XCTAssertFalse(policy.isSleeping)
        XCTAssertEqual(policy.lastActivity, 120)

        policy.update(at: 179, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 180, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testClockPreviewSleepsImmediatelyAndCanBeWoken() {
        var policy = KioskIdlePolicy(now: 100)

        policy.showClock(at: 101)
        XCTAssertTrue(policy.isSleeping)
        XCTAssertEqual(policy.lastActivity, 101)

        policy.recordActivity(at: 102)
        XCTAssertFalse(policy.isSleeping)
        XCTAssertEqual(policy.lastActivity, 102)
    }

    func testIncreasingTimeoutDoesNotWakeSleepingClock() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 60, idleTimeout: 60, eligible: true)

        policy.update(at: 61, idleTimeout: 300, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testOlderTimestampsCannotMoveActivityDeadlineBackwards() {
        var policy = KioskIdlePolicy(now: 100)
        policy.recordActivity(at: 90)
        XCTAssertEqual(policy.lastActivity, 100)

        policy.update(at: 99, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 159, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 160, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }

    func testInitialSustainedDarknessSleepsAfterThreeSecondsDespiteActivity() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        for time in 1...2 {
            policy.recordActivity(at: Double(time))
            policy.update(at: Double(time), idleTimeout: 60, eligible: true, lightLevel: 0.1)
            XCTAssertFalse(policy.isSleeping)
        }
        policy.recordActivity(at: 3)
        policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertTrue(policy.isSleeping)
    }

    func testBriefDarkFlickerDoesNotShortenTheNextDarknessDelay() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.update(at: 2, idleTimeout: 60, eligible: true, lightLevel: 0.5)
        policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.update(at: 5.9, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 6, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertTrue(policy.isSleeping)
    }

    func testDarkHysteresisDoesNotRearmUntilLightClearsExitThreshold() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.update(at: 1, idleTimeout: 60, eligible: true, lightLevel: 0.21)
        policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.21)
        XCTAssertTrue(policy.isSleeping)
        policy.recordActivity(at: 4)
        policy.update(at: 10, idleTimeout: 60, eligible: true, lightLevel: 0.23)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 11, idleTimeout: 60, eligible: true, lightLevel: 0.25)
        policy.update(at: 12, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.update(at: 15, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertTrue(policy.isSleeping)
    }

    func testWakeInSameDarknessUsesOrdinaryIdleTimeout() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.recordActivity(at: 4)
        policy.update(at: 7, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 63, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 64, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertTrue(policy.isSleeping)
    }

    func testMissingLightAndIneligibleContextResetDarknessTracking() {
        for interruptWithMissingLight in [true, false] {
            var policy = KioskIdlePolicy(now: 0)
            policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.1)
            policy.update(at: 2, idleTimeout: 60, eligible: interruptWithMissingLight,
                          lightLevel: interruptWithMissingLight ? nil : 0.1)
            policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.1)
            policy.update(at: 5.9, idleTimeout: 60, eligible: true, lightLevel: 0.1)
            XCTAssertFalse(policy.isSleeping)
            policy.update(at: 6, idleTimeout: 60, eligible: true, lightLevel: 0.1)
            XCTAssertTrue(policy.isSleeping)
        }
    }

    func testPreviewInDarknessDoesNotRestartDarknessDelayAfterWake() {
        var policy = KioskIdlePolicy(now: 0)
        policy.showClock(at: 0)
        policy.update(at: 1, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        policy.recordActivity(at: 2)
        policy.update(at: 5, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 61, idleTimeout: 60, eligible: true, lightLevel: 0.1)
        XCTAssertFalse(policy.isSleeping)
    }

    func testCustomDarkThresholdAndInvalidLightFallback() {
        var policy = KioskIdlePolicy(now: 0)
        policy.update(at: 0, idleTimeout: 60, eligible: true, lightLevel: 0.25, darkThreshold: 0.3)
        policy.update(at: 3, idleTimeout: 60, eligible: true, lightLevel: 0.25, darkThreshold: 0.3)
        XCTAssertTrue(policy.isSleeping)
        policy.recordActivity(at: 4)
        policy.update(at: 5, idleTimeout: 60, eligible: true, lightLevel: .nan)
        policy.update(at: 63, idleTimeout: 60, eligible: true)
        XCTAssertFalse(policy.isSleeping)
        policy.update(at: 64, idleTimeout: 60, eligible: true)
        XCTAssertTrue(policy.isSleeping)
    }
}
