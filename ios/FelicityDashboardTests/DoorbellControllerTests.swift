import XCTest
import UIKit
@testable import FelicityDashboard

final class DoorbellControllerTests: XCTestCase {
    @MainActor
    func testCallerSnapshotRemainsIndependentOfLaterCameraPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraPreviewStore(root: root)
        let doorbell = camera(id: "front", source: "source", doorbell: true)
        func frame(_ color: UIColor) throws -> Data {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
            }
            return try XCTUnwrap(image.pngData())
        }
        let original = await store.saveAndReturn(try frame(.red), for: doorbell)
        let caller = try XCTUnwrap(original)
        let callerData = try XCTUnwrap(caller.pngData())
        await store.save(try frame(.blue), for: doorbell)
        let latest = await store.image(for: doorbell)
        let latestData = try XCTUnwrap(latest?.pngData())
        XCTAssertNotEqual(callerData, latestData)
        XCTAssertEqual(caller.pngData(), callerData)
    }

    @MainActor
    func testSourceSelectsMatchingDoorbellAndNeverAnUnrelatedCamera() {
        let regular = camera(id: "drive", source: "source-1", doorbell: false)
        let first = camera(id: "front", source: "source-2", doorbell: true)
        let second = camera(id: "side", source: "source-3", doorbell: true)
        let cameras = [regular, first, second]
        XCTAssertEqual(DoorbellController.camera(for: "source-3", in: cameras)?.id, "side")
        XCTAssertEqual(DoorbellController.camera(for: "source-1", in: cameras)?.id, "front")
        XCTAssertEqual(DoorbellController.camera(for: "", in: cameras)?.id, "front")
        XCTAssertNil(DoorbellController.camera(for: "source-1", in: [regular]))
    }

    @MainActor
    func testInactiveAndDisabledAppCannotPresentOrStartMicrophone() throws {
        let name = "DoorbellControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DoorbellController(defaults: defaults)
        let doorbell = camera(id: "front", source: "source-2", doorbell: true)
        controller.receiveRing(sourceToken: "source-2", cameras: [doorbell])
        XCTAssertNil(controller.session)
        controller.setActive(true)
        controller.enabled = false
        controller.receiveRing(sourceToken: "source-2", cameras: [doorbell])
        XCTAssertNil(controller.session)
        XCTAssertFalse(controller.audio.microphoneEnabled)
    }

    @MainActor
    func testRingStartsMutedAndBackgroundClosesCall() throws {
        let name = "DoorbellControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = DoorbellController(defaults: defaults)
        let doorbell = camera(id: "front", source: "source-2", doorbell: true)
        controller.setActive(true)
        controller.receiveRing(sourceToken: "source-2", cameras: [doorbell])
        XCTAssertEqual(controller.session?.camera.id, "front")
        XCTAssertTrue(controller.session?.captureCaller == true)
        XCTAssertFalse(controller.audio.microphoneEnabled)
        XCTAssertFalse(controller.audio.listeningEnabled)
        controller.setActive(false)
        XCTAssertNil(controller.session)
        XCTAssertFalse(controller.audio.microphoneEnabled)
    }

    private func camera(id: String, source: String, doorbell: Bool) -> CameraDescriptor {
        .init(id: id, name: id, host: "recorder.invalid", sourceToken: source,
              mainProfile: "main", subProfile: "sub", mainURI: "rtsp://recorder.invalid/main", subURI: "rtsp://recorder.invalid/sub",
              mainRecording: nil, subRecording: nil, mainWidth: 1280, mainHeight: 720,
              subWidth: 640, subHeight: 360, rotationDegrees: 0, isDoorbell: doorbell, isCorridor: false)
    }
}
