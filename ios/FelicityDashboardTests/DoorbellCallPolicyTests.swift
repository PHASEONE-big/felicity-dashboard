import XCTest
@testable import FelicityDashboard

final class DoorbellCallPolicyTests: XCTestCase {
    func testRingOpensMutedAndClosesAtSixtySeconds() {
        var policy = DoorbellCallPolicy()
        XCTAssertTrue(policy.ring(at: 0))
        XCTAssertTrue(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 60)
        XCTAssertFalse(policy.update(at: 59.999))
        XCTAssertTrue(policy.update(at: 60))
        XCTAssertFalse(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertNil(policy.deadline)
        XCTAssertFalse(policy.update(at: 61))
    }

    func testDuplicateRingDoesNotExtendDeadline() {
        var policy = DoorbellCallPolicy()
        XCTAssertTrue(policy.ring(at: 100))
        XCTAssertFalse(policy.ring(at: 104.999))
        XCTAssertEqual(policy.deadline, 160)
        XCTAssertTrue(policy.ring(at: 105))
        XCTAssertEqual(policy.deadline, 165)
    }

    func testAcceptedNewRingStopsTalkingAndRestartsVideoDeadline() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 100)
        policy.beginTalking(at: 101)
        XCTAssertFalse(policy.ring(at: 104))
        XCTAssertTrue(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 131)
        XCTAssertTrue(policy.ring(at: 105))
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 165)
    }

    func testTalkingClosesWholeCallAfterThirtySeconds() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 100)
        policy.beginTalking(at: 110)
        XCTAssertTrue(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 140)
        XCTAssertFalse(policy.update(at: 139.999))
        XCTAssertTrue(policy.update(at: 140))
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertFalse(policy.isPresenting)
    }

    func testRepeatedBeginTalkingCannotExtendMicrophoneSafetyDeadline() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 0)
        policy.beginTalking(at: 10)
        policy.beginTalking(at: 39)
        XCTAssertEqual(policy.deadline, 40)
        XCTAssertTrue(policy.update(at: 40))
    }

    func testStoppingTalkRestartsSixtySecondsOnlyOnce() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 0)
        policy.beginTalking(at: 10)
        policy.endTalking(at: 20)
        XCTAssertTrue(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 80)
        policy.endTalking(at: 50)
        XCTAssertEqual(policy.deadline, 80)
        XCTAssertTrue(policy.update(at: 80))
    }

    func testExplicitCloseClearsMediaStateAndPreservesDuplicateProtection() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 100)
        policy.beginTalking(at: 101)
        policy.close()
        XCTAssertFalse(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertNil(policy.deadline)
        XCTAssertFalse(policy.ring(at: 102))
        XCTAssertFalse(policy.isPresenting)
        XCTAssertTrue(policy.ring(at: 105))
    }

    func testInactivePolicyCannotStartOrExtendACall() {
        var policy = DoorbellCallPolicy()
        policy.beginTalking(at: 10)
        policy.endTalking(at: 20)
        XCTAssertFalse(policy.update(at: 100))
        XCTAssertFalse(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertNil(policy.deadline)
    }

    func testManualPreviewBypassesRingDeduplicationAndStartsMuted() {
        var policy = DoorbellCallPolicy()
        policy.ring(at: 100)
        policy.beginTalking(at: 101)
        policy.close()
        policy.openPreview(at: 102)
        XCTAssertTrue(policy.isPresenting)
        XCTAssertFalse(policy.microphoneActive)
        XCTAssertEqual(policy.deadline, 162)
        XCTAssertFalse(policy.ring(at: 103))
        XCTAssertTrue(policy.update(at: 162))
    }
}
