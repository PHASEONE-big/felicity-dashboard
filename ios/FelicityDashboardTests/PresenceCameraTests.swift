import XCTest
@testable import FelicityDashboard

final class PresenceCameraTests: XCTestCase {
    func testCalibrationIgnoresScreenBrightnessChangesAndLearnsNewBaseline() {
        var detector = PresenceLightMotionDetector()
        detector.reset(at: 0)
        XCTAssertFalse(detector.accept(luminance: flat(0.7), exposure: nil, at: 0))
        XCTAssertFalse(detector.accept(luminance: flat(0.1), exposure: nil, at: 1))
        XCTAssertFalse(detector.accept(luminance: flat(0.1), exposure: nil, at: 2.9))
        XCTAssertFalse(detector.accept(luminance: flat(0.1), exposure: nil, at: 3.1))
    }

    func testSustainedLightChangeWakesAfterConfirmation() {
        var detector = calibrated()
        XCTAssertFalse(detector.accept(luminance: flat(0.2), exposure: nil, at: 3.5))
        XCTAssertTrue(detector.accept(luminance: flat(0.2), exposure: nil, at: 4))
    }

    func testSingleGlobalFlickerAndSlowDaylightDriftDoNotWake() {
        var detector = calibrated()
        XCTAssertFalse(detector.accept(luminance: flat(0.8), exposure: nil, at: 3.5))
        XCTAssertFalse(detector.accept(luminance: flat(0.5), exposure: nil, at: 4))
        for step in 1...60 {
            XCTAssertFalse(detector.accept(luminance: flat(0.5 + Double(step) * 0.001), exposure: nil, at: 4 + Double(step) * 0.5))
        }
    }

    func testExposureChangesStillWakeWhenAutoExposureKeepsImageBrightnessStable() {
        var detector = calibrated(exposure: 0)
        XCTAssertFalse(detector.accept(luminance: flat(0.5), exposure: 1.2, at: 3.5))
        XCTAssertTrue(detector.accept(luminance: flat(0.5), exposure: 1.2, at: 4))
    }

    func testStrongLocalShadowWakesWithoutGlobalBrightnessChange() {
        var detector = calibrated()
        let shadow = (0..<48).map { $0.isMultiple(of: 2) ? 0.25 : 0.75 }
        XCTAssertTrue(detector.accept(luminance: shadow, exposure: nil, at: 3.5))
    }

    func testRecalibrationSuppressesWakeAndForgetsPreviousExposure() {
        var detector = calibrated(exposure: 0)
        detector.reset(at: 10)
        XCTAssertFalse(detector.accept(luminance: flat(0.05), exposure: 4, at: 10))
        XCTAssertFalse(detector.accept(luminance: flat(0.05), exposure: 4, at: 12.9))
        XCTAssertFalse(detector.accept(luminance: flat(0.05), exposure: 4, at: 13.1))
    }

    func testStableDarkSceneWithSensorNoiseDoesNotWakeAtHighestSensitivity() {
        var detector = PresenceLightMotionDetector()
        detector.sensitivity = 1
        detector.reset(at: 0)
        _ = detector.accept(luminance: flat(0.05), exposure: 6, at: 0)
        for frame in 1...120 {
            let samples = (0..<48).map { cell in
                0.05 + Double((cell * 17 + frame * 7) % 21 - 10) * 0.002
            }
            XCTAssertFalse(detector.accept(luminance: samples, exposure: 6 + sin(Double(frame)) * 0.15, at: Double(frame)))
        }
    }

    func testAutoExposureGainChangeDoesNotLookLikeLocalMotion() {
        var detector = PresenceLightMotionDetector()
        let original = (0..<48).map { $0.isMultiple(of: 2) ? 0.2 : 0.4 }
        detector.reset(at: 0)
        _ = detector.accept(luminance: original, exposure: 0, at: 0)
        _ = detector.accept(luminance: original, exposure: 0, at: 3.1)
        let brighter = original.map { $0 * 2 }
        for frame in 4...30 {
            XCTAssertFalse(detector.accept(luminance: brighter, exposure: 1, at: Double(frame)))
        }
    }

    func testMotionBetweenSparseFramesIsConfirmedAgainstHeldReference() {
        var detector = calibrated()
        let moved = (0..<48).map { $0.isMultiple(of: 2) ? 0.425 : 0.575 }
        XCTAssertFalse(detector.accept(luminance: moved, exposure: nil, at: 4))
        XCTAssertTrue(detector.accept(luminance: moved, exposure: nil, at: 5))
        for frame in 6...120 {
            XCTAssertFalse(detector.accept(luminance: moved, exposure: nil, at: Double(frame)))
        }
    }

    func testSensitivityChangesWeakMotionThreshold() {
        var sensitive = calibrated()
        var insensitive = calibrated()
        sensitive.sensitivity = 1
        insensitive.sensitivity = 0
        let smallChange = (0..<48).map { $0.isMultiple(of: 2) ? 0.455 : 0.545 }
        XCTAssertFalse(sensitive.accept(luminance: smallChange, exposure: nil, at: 4))
        XCTAssertTrue(sensitive.accept(luminance: smallChange, exposure: nil, at: 5))
        XCTAssertFalse(insensitive.accept(luminance: smallChange, exposure: nil, at: 4))
        XCTAssertFalse(insensitive.accept(luminance: smallChange, exposure: nil, at: 5))
    }

    func testIlluminationScoreRetainsExposureCompensation() throws {
        let original = try XCTUnwrap(PresenceIlluminationEstimator.normalizedLevel(mean: 0.25, exposure: 0))
        let compensated = try XCTUnwrap(PresenceIlluminationEstimator.normalizedLevel(mean: 0.5, exposure: 1))
        XCTAssertEqual(original, compensated, accuracy: 0.0001)
        let dark = try XCTUnwrap(PresenceIlluminationEstimator.normalizedLevel(mean: 0.5, exposure: 4))
        let bright = try XCTUnwrap(PresenceIlluminationEstimator.normalizedLevel(mean: 0.5, exposure: -4))
        XCTAssertLessThan(dark, 0.2)
        XCTAssertGreaterThan(bright, 0.8)
    }

    func testIlluminationScoreIsBoundedSmoothedAndRejectsInvalidSamples() throws {
        XCTAssertEqual(PresenceIlluminationEstimator.normalizedLevel(mean: 0, exposure: 10), 0)
        XCTAssertEqual(PresenceIlluminationEstimator.normalizedLevel(mean: 1, exposure: -10), 1)
        XCTAssertNil(PresenceIlluminationEstimator.normalizedLevel(mean: .nan, exposure: 0))
        var estimator = PresenceIlluminationEstimator()
        let initial = try XCTUnwrap(estimator.update(mean: 0.5, exposure: 4))
        let changed = try XCTUnwrap(estimator.update(mean: 0.5, exposure: -4))
        XCTAssertGreaterThan(changed, initial)
        XCTAssertLessThan(changed - initial, 0.2)
    }

    private func flat(_ value: Double) -> [Double] { Array(repeating: value, count: 48) }

    private func calibrated(exposure: Double? = nil) -> PresenceLightMotionDetector {
        var detector = PresenceLightMotionDetector()
        detector.reset(at: 0)
        _ = detector.accept(luminance: flat(0.5), exposure: exposure, at: 0)
        _ = detector.accept(luminance: flat(0.5), exposure: exposure, at: 3.1)
        return detector
    }
}
