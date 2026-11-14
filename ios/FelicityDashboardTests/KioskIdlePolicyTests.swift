import XCTest
@testable import FelicityDashboard

final class KioskIdlePolicyTests: XCTestCase {
    func testAdaptiveBrightnessIsDimAtNightAndIncreasesWithLight() {
        let dark = KioskBrightnessPolicy.dashboard(level: 0, adjustment: 0)
        let room = KioskBrightnessPolicy.dashboard(level: 0.5, adjustment: 0)
        let day = KioskBrightnessPolicy.dashboard(level: 1, adjustment: 0)
        XCTAssertLessThan(dark, 0.1)
        XCTAssertLessThan(dark, room)
        XCTAssertLessThan(room, day)
        XCTAssertGreaterThan(day, 0.6)
    }

    func testBrightnessAdjustmentStaysInSafeDisplayRange() {
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(level: -1, adjustment: -1), 0.05)
        XCTAssertEqual(KioskBrightnessPolicy.dashboard(level: 2, adjustment: 1), 0.85)
        XCTAssertTrue(KioskBrightnessPolicy.dashboard(level: .nan, adjustment: .nan).isFinite)
        XCTAssertGreaterThan(KioskBrightnessPolicy.dashboard(level: 0.4, adjustment: 0.1), KioskBrightnessPolicy.dashboard(level: 0.4, adjustment: 0))
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
