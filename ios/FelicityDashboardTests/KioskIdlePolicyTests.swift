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
}
