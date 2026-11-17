import XCTest
import UIKit
@testable import FelicityDashboard

final class DoorbellOverlayHitTests: XCTestCase {
    @MainActor
    func testNestedCardAcceptsImageAndFooterButPassesOutsideThrough() {
        let window = DoorbellOverlayWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let content = UIView(frame: CGRect(x: 0, y: 24, width: 768, height: 980))
        let card = DoorbellCardHitRegionView(frame: CGRect(x: 16, y: 795, width: 208, height: 161))
        window.addSubview(content)
        content.addSubview(card)

        XCTAssertTrue(window.acceptsTouch(at: card.convert(CGPoint(x: 104, y: 58), to: window)))
        XCTAssertTrue(window.acceptsTouch(at: card.convert(CGPoint(x: 184, y: 139), to: window)))
        XCTAssertFalse(window.acceptsTouch(at: CGPoint(x: 350, y: 900)))
        XCTAssertNil(window.hitTest(CGPoint(x: 350, y: 900), with: nil))
        XCTAssertFalse(window.canBecomeKey)
    }

    @MainActor
    func testMovingAndRotatingAnAncestorUsesCurrentCoordinatesWithoutReregistration() {
        let window = DoorbellOverlayWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let content = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let card = DoorbellCardHitRegionView(frame: CGRect(x: 16, y: 560, width: 208, height: 161))
        window.addSubview(content)
        content.addSubview(card)
        let oldPoint = card.convert(CGPoint(x: 100, y: 100), to: window)
        XCTAssertTrue(window.acceptsTouch(at: oldPoint))

        content.transform = CGAffineTransform(translationX: 300, y: -250).rotated(by: .pi / 4)
        let newPoint = card.convert(CGPoint(x: 100, y: 100), to: window)
        XCTAssertNotEqual(oldPoint, newPoint)
        XCTAssertTrue(window.acceptsTouch(at: newPoint))
        XCTAssertFalse(window.acceptsTouch(at: oldPoint))
    }

    @MainActor
    func testDetachedCardCannotInterceptTouchesAndNewWindowRegistersIt() {
        let first = DoorbellOverlayWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let second = DoorbellOverlayWindow(frame: first.bounds)
        let card = DoorbellCardHitRegionView(frame: CGRect(x: 16, y: 800, width: 208, height: 161))
        first.addSubview(card)
        let point = CGPoint(x: 100, y: 850)
        XCTAssertTrue(first.acceptsTouch(at: point))
        card.removeFromSuperview()
        XCTAssertFalse(first.acceptsTouch(at: point))
        second.addSubview(card)
        XCTAssertFalse(first.acceptsTouch(at: point))
        XCTAssertTrue(second.acceptsTouch(at: point))
    }

    @MainActor
    func testRemovingOldCardDoesNotClearTheNewCardRegistration() {
        let window = DoorbellOverlayWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let old = DoorbellCardHitRegionView(frame: CGRect(x: 16, y: 800, width: 208, height: 161))
        let current = DoorbellCardHitRegionView(frame: CGRect(x: 300, y: 800, width: 208, height: 161))
        window.addSubview(old)
        window.addSubview(current)
        old.removeFromSuperview()
        XCTAssertTrue(window.acceptsTouch(at: CGPoint(x: 400, y: 850)))
        XCTAssertFalse(window.acceptsTouch(at: CGPoint(x: 100, y: 850)))
    }

    @MainActor
    func testFullCallAcceptsWholeWindowAndReturnsToCardOnlyAfterTimeout() {
        let window = DoorbellOverlayWindow(frame: CGRect(x: 0, y: 0, width: 768, height: 1024))
        let card = DoorbellCardHitRegionView(frame: CGRect(x: 16, y: 800, width: 208, height: 161))
        window.addSubview(card)
        window.fullScreen = true
        XCTAssertTrue(window.acceptsTouch(at: CGPoint(x: 700, y: 100)))
        window.fullScreen = false
        XCTAssertFalse(window.acceptsTouch(at: CGPoint(x: 700, y: 100)))
        XCTAssertTrue(window.acceptsTouch(at: CGPoint(x: 100, y: 850)))
        card.isHidden = true
        XCTAssertFalse(window.acceptsTouch(at: CGPoint(x: 100, y: 850)))
    }
}
