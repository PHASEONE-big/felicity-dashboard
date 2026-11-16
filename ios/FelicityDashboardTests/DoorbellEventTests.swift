import XCTest
@testable import FelicityDashboard

final class DoorbellEventTests: XCTestCase {
    private let ringTopic = "rules:RuleEngine/vendor:RingDetector/Detection"

    func testParsesNamespacesSingleQuotesAndObservedDetectedField() throws {
        let events = try DoorbellNotification.parse(envelope(notification(operation: "Changed", source: "front&amp;door", fields: "<t:SimpleItem Name='Detected' Value='true'/>")))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.topic, ringTopic)
        XCTAssertEqual(event.operation, "Changed")
        XCTAssertEqual(event.sourceToken, "front&door")
        XCTAssertTrue(event.active)
        XCTAssertTrue(event.valueKnown)
        XCTAssertTrue(event.isRing)
    }

    func testInitializationNeverRingsAndActiveSnapshotDoesNotCreateFalseEdge() {
        var filter = DoorbellRingFilter()
        XCTAssertFalse(filter.accept(event("Initialized", active: true), at: 100))
        XCTAssertFalse(filter.accept(event("Changed", active: true), at: 101))
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 108))
    }

    func testRisingEdgeSuppressesDuplicateAndReleaseAllowsNextPress() {
        var filter = DoorbellRingFilter()
        XCTAssertFalse(filter.accept(event("Initialized", active: false), at: 100))
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 101))
        XCTAssertFalse(filter.accept(event("Changed", active: true), at: 102))
        XCTAssertFalse(filter.accept(event("Changed", active: false), at: 103))
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 104))
    }

    func testLostReleaseRecoversAtEightSecondsWithoutExtendingLatchOnDuplicates() {
        var filter = DoorbellRingFilter()
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 10))
        XCTAssertFalse(filter.accept(event("Changed", active: true), at: 17.9))
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 18))
        XCTAssertFalse(filter.accept(event("Changed", active: true), at: 19))
    }

    func testRingLatchesAreIndependentForDifferentSourceTokens() {
        var filter = DoorbellRingFilter()
        XCTAssertTrue(filter.accept(event("Changed", active: true, source: "front"), at: 1))
        XCTAssertTrue(filter.accept(event("Changed", active: true, source: "back"), at: 2))
        XCTAssertFalse(filter.accept(event("Changed", active: false, source: "back"), at: 3))
        XCTAssertFalse(filter.accept(event("Changed", active: true, source: "front"), at: 4))
        XCTAssertTrue(filter.accept(event("Changed", active: true, source: "back"), at: 4))
    }

    func testMissingOperationAllowsRealStateTransition() throws {
        let idle = try XCTUnwrap(DoorbellNotification.parse(envelope(notification(operation: nil, fields: "<t:SimpleItem Name='Detected' Value='false'/>"))).first)
        let press = try XCTUnwrap(DoorbellNotification.parse(envelope(notification(operation: nil, fields: "<t:SimpleItem Name='Detected' Value='true'/>"))).first)
        var filter = DoorbellRingFilter()
        XCTAssertEqual(idle.operation, "")
        XCTAssertFalse(filter.accept(idle, at: 1))
        XCTAssertTrue(filter.accept(press, at: 2))
        XCTAssertFalse(filter.accept(press, at: 3))
    }

    func testUnknownOrDeletedValuesDoNotClearAnActiveLatch() {
        var filter = DoorbellRingFilter()
        XCTAssertTrue(filter.accept(event("Changed", active: true), at: 1))
        let unknown = DoorbellNotification(topic: ringTopic, operation: "Changed", active: false, valueKnown: false, sourceToken: "front")
        XCTAssertFalse(filter.accept(unknown, at: 2))
        XCTAssertFalse(filter.accept(event("Deleted", active: false), at: 3))
        XCTAssertFalse(filter.accept(event("Changed", active: true), at: 4))
    }

    func testSourceTokensAndUnrelatedBooleanDataCannotTriggerRing() throws {
        let xml = envelope(notification(source: "1", fields: "<t:SimpleItem Name='Confidence' Value='1'/><t:SimpleItem Name='Detected' Value='unknown'/>"))
        let parsed = try XCTUnwrap(DoorbellNotification.parse(xml).first)
        XCTAssertEqual(parsed.sourceToken, "1")
        XCTAssertFalse(parsed.active)
        XCTAssertFalse(parsed.valueKnown)
        var filter = DoorbellRingFilter()
        XCTAssertFalse(filter.accept(parsed, at: 1))
    }

    func testNonRingNotificationNeverRingsAndDoesNotLeakAcrossMessages() throws {
        let motion = notification(topic: "rules:MotionDetector/Detection", source: "motion-camera", fields: "<t:SimpleItem Name='State' Value='true'/>")
        let idle = notification(source: "front", fields: "<t:SimpleItem Name='State' Value='false'/>")
        let parsed = try DoorbellNotification.parse(envelope(motion + idle))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map(\.sourceToken), ["motion-camera", "front"])
        XCTAssertEqual(parsed.map(\.active), [true, false])
        var filter = DoorbellRingFilter()
        XCTAssertFalse(filter.accept(parsed[0], at: 1))
        XCTAssertFalse(filter.accept(parsed[1], at: 2))
    }

    func testUnknownSourceIsPreservedForExplicitControllerFallback() throws {
        let parsed = try XCTUnwrap(DoorbellNotification.parse(envelope(notification(source: "", fields: "<t:SimpleItem Name='Button' Value='pressed'/>"))).first)
        XCTAssertEqual(parsed.sourceToken, "")
        var filter = DoorbellRingFilter()
        XCTAssertTrue(filter.accept(parsed, at: 1))
        XCTAssertFalse(filter.accept(parsed, at: 2))
    }

    func testMalformedXMLDoesNotDeliverPartiallyParsedEvents() {
        let valid = envelope(notification(fields: "<t:SimpleItem Name='Detected' Value='true'/>"))
        XCTAssertThrowsError(try DoorbellNotification.parse(String(valid.dropLast(8))))
    }

    private func event(_ operation: String, active: Bool, source: String = "front") -> DoorbellNotification {
        .init(topic: ringTopic, operation: operation, active: active, valueKnown: true, sourceToken: source)
    }

    private func notification(topic: String? = nil, operation: String? = "Changed", source: String = "front", fields: String) -> String {
        let operation = operation.map { " PropertyOperation='\($0)'" } ?? ""
        return "<n:NotificationMessage><n:Topic>\(topic ?? ringTopic)</n:Topic><n:Message><t:Message\(operation)><t:Source><t:SimpleItem Name='VideoSourceToken' Value='\(source)'/></t:Source><t:Data>\(fields)</t:Data></t:Message></n:Message></n:NotificationMessage>"
    }

    private func envelope(_ messages: String) -> String {
        "<s:Envelope xmlns:s='http://www.w3.org/2003/05/soap-envelope' xmlns:n='http://docs.oasis-open.org/wsn/b-2' xmlns:t='http://www.onvif.org/ver10/schema'><s:Body>\(messages)</s:Body></s:Envelope>"
    }
}
