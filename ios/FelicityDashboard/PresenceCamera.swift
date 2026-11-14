import AVFoundation
import Foundation

enum PresenceCameraStatus: Equatable {
    case stopped
    case starting
    case running
    case permissionDenied
    case unavailable
    case failed

    var description: String {
        switch self {
        case .stopped: return "Front camera is off"
        case .starting: return "Starting front camera…"
        case .running: return "Low-power motion and light sensing"
        case .permissionDenied: return "Allow camera access in Settings to wake automatically"
        case .unavailable: return "Front camera is unavailable; tap the clock to wake"
        case .failed: return "Camera detection stopped; turn it off and on to retry"
        }
    }
}

/// A foreground-only presence signal. Frames stay in memory and are never recorded.
@MainActor
final class PresenceCamera {
    var statusChanged: ((PresenceCameraStatus) -> Void)?
    var activityDetected: (() -> Void)?
    /// Smoothed relative illumination: 0 is dark, 1 is bright daylight. Not lux.
    var lightLevelChanged: ((Double) -> Void)?
    var motionSensitivity: Double = 0.5 {
        didSet { worker?.setSensitivity(motionSensitivity) }
    }
    private(set) var status: PresenceCameraStatus = .stopped

    private var requested = false
    private var generation = 0
    private var worker: PresenceCameraWorker?

    init() {
        worker = PresenceCameraWorker { [weak self] generation, event in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested, self.generation == generation else { return }
                switch event {
                case .status(let value): self.setStatus(value)
                case .activity: self.activityDetected?()
                case .lightLevel(let value): self.lightLevelChanged?(value)
                }
            }
        }
    }

    deinit {
        worker?.stop()
    }

    func start() {
        guard !requested else { return }
        requested = true
        generation += 1
        let requestGeneration = generation
        setStatus(.starting)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAuthorized(generation: requestGeneration)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.requested, self.generation == requestGeneration else { return }
                    if granted { self.startAuthorized(generation: requestGeneration) }
                    else { self.setStatus(.permissionDenied) }
                }
            }
        case .denied, .restricted:
            setStatus(.permissionDenied)
        @unknown default:
            setStatus(.unavailable)
        }
    }

    func stop() {
        requested = false
        generation += 1
        worker?.stop()
        setStatus(.stopped)
    }

    /// Ignore the screen's own reflected light while its brightness settles.
    func recalibrate() {
        worker?.recalibrate()
    }

    private func startAuthorized(generation: Int) {
        guard requested, self.generation == generation else { return }
        worker?.start(generation: generation)
    }

    private func setStatus(_ value: PresenceCameraStatus) {
        guard status != value else { return }
        status = value
        statusChanged?(value)
    }
}

/// A relative camera-light estimate, not a calibrated lux meter. Exposure
/// compensation prevents auto-exposure from making a dark room look bright.
struct PresenceIlluminationEstimator {
    private(set) var level: Double?

    static func normalizedLevel(mean: Double, exposure: Double?) -> Double? {
        guard mean.isFinite, (0...1).contains(mean) else { return nil }
        guard let exposure, exposure.isFinite else { return mean }
        // Fixed-aperture camera proxy: image brightness / (ISO * seconds).
        // Spread a useful indoor-to-daylight range over twelve exposure stops.
        let stops = log2(max(0.01, mean)) - exposure
        return min(1, max(0, (stops + 7) / 12))
    }

    mutating func update(mean: Double, exposure: Double?) -> Double? {
        guard let raw = Self.normalizedLevel(mean: mean, exposure: exposure) else { return nil }
        let smoothed = level.map { $0 + 0.25 * (raw - $0) } ?? raw
        level = smoothed
        return smoothed
    }
}

/// Pure, tiny-grid signal processing. It recognizes changes, not people/faces.
struct PresenceLightMotionDetector {
    var sensitivity: Double = 0.5
    private var reference: [Double] = []
    private var referenceMean = 0.0
    private var baselineIllumination: Double?
    private var usesExposure = false
    private var suppressedUntil: TimeInterval = 0
    private var lastActivity: TimeInterval = -.infinity
    private var evidenceCount = 0

    mutating func reset(at time: TimeInterval) {
        reference = []
        baselineIllumination = nil
        suppressedUntil = time + 3
        lastActivity = -.infinity
        evidenceCount = 0
    }

    /// Luminance samples are spatial averages in 0...1;
    /// exposure is log2(ISO * seconds), sampled with the frame.
    mutating func accept(luminance: [Double], exposure: Double?, at time: TimeInterval) -> Bool {
        guard !luminance.isEmpty, time.isFinite,
              luminance.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        let mean = luminance.reduce(0, +) / Double(luminance.count)
        let validExposure = exposure.flatMap { $0.isFinite ? $0 : nil }
        let illumination = log2(max(0.01, mean)) - (validExposure ?? 0)
        guard time >= suppressedUntil, reference.count == luminance.count,
              let baselineIllumination, usesExposure == (validExposure != nil) else {
            setReference(luminance, mean: mean, illumination: illumination, usesExposure: validExposure != nil)
            return false
        }

        let boundedSensitivity = sensitivity.isFinite ? min(1, max(0, sensitivity)) : 0.5
        let thresholdScale = 1.35 - 0.7 * boundedSensitivity
        let exposureDarkness = validExposure.map { min(1, max(0, ($0 - 3) / 3)) } ?? 0
        let darkness = max(1 - min(1, mean / 0.2), exposureDarkness)
        let noiseAllowance = 0.03 * darkness
        // Cancel global gain/brightness adjustments before comparing texture.
        // Do not amplify nearly black sensor noise without a bound.
        let gain = mean > 0.02 ? min(2, max(0.5, referenceMean / mean)) : 1
        var localDifference = 0.0
        var changedCells = 0
        for index in luminance.indices {
            let difference = abs((luminance[index] - mean) * gain - (reference[index] - referenceMean))
            localDifference += difference
            if difference > 0.06 * thresholdScale + noiseAllowance { changedCells += 1 }
        }
        localDifference /= Double(luminance.count)
        let changedFraction = Double(changedCells) / Double(luminance.count)
        let lightChange = abs(illumination - baselineIllumination) > 0.9 + 0.35 * darkness
        let localMovement = localDifference > 0.035 * thresholdScale + noiseAllowance * 0.5 && changedFraction > 0.16
        let strongMovement = localDifference > 0.10 * thresholdScale + noiseAllowance && changedFraction > 0.30

        if lightChange || localMovement { evidenceCount += 1 }
        else {
            evidenceCount = 0
            // Follow slow daylight/AE drift. Hold this reference while a change
            // is being confirmed, so motion between two 1 fps samples is not lost.
            for index in reference.indices { reference[index] += 0.2 * (luminance[index] - reference[index]) }
            referenceMean += 0.2 * (mean - referenceMean)
            self.baselineIllumination = baselineIllumination + 0.15 * (illumination - baselineIllumination)
        }
        guard evidenceCount >= 2 || strongMovement else { return false }
        // A newly stationary scene must not keep resetting the idle timer.
        setReference(luminance, mean: mean, illumination: illumination, usesExposure: validExposure != nil)
        guard time - lastActivity >= 1.5 else { return false }
        lastActivity = time
        return true
    }

    private mutating func setReference(_ luminance: [Double], mean: Double, illumination: Double, usesExposure: Bool) {
        reference = luminance
        referenceMean = mean
        baselineIllumination = illumination
        self.usesExposure = usesExposure
        evidenceCount = 0
    }
}

private enum PresenceCameraEvent {
    case status(PresenceCameraStatus)
    case activity
    case lightLevel(Double)
}

/// Capture and inexpensive sampling live on one serial queue. No image inference.
private final class PresenceCameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "io.felicity.presence.capture", qos: .utility)
    private let emit: (Int, PresenceCameraEvent) -> Void
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var requested = false
    private var generation = 0
    private var detector = PresenceLightMotionDetector()
    private var illumination = PresenceIlluminationEstimator()
    private var lastFrame: TimeInterval = -.infinity
    private var lastPublishedLightLevel: Double?
    private var suppressedUntil: TimeInterval = 0
    private var recoveryAttempts = 0

    init(emit: @escaping (Int, PresenceCameraEvent) -> Void) {
        self.emit = emit
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
    }

    func start(generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.tearDown()
            self.requested = true
            self.generation = generation
            self.recoveryAttempts = 0
            self.illumination = PresenceIlluminationEstimator()
            self.configureAndStart()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.requested = false
            self?.tearDown()
        }
    }

    func recalibrate() {
        queue.async { [weak self] in self?.resetDetector() }
    }

    func setSensitivity(_ value: Double) {
        queue.async { [weak self] in self?.detector.sensitivity = value }
    }

    private func configureAndStart() {
        guard requested else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            emit(generation, .status(.unavailable))
            return
        }
        let capture = AVCaptureSession()
        let video = AVCaptureVideoDataOutput()
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            capture.beginConfiguration()
            if capture.canSetSessionPreset(.low) { capture.sessionPreset = .low }
            else if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
            guard capture.canAddInput(input), capture.canAddOutput(video) else {
                capture.commitConfiguration()
                emit(generation, .status(.unavailable))
                return
            }
            capture.addInput(input)
            video.alwaysDiscardsLateVideoFrames = true
            let fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let format = [fullRange, videoRange, kCVPixelFormatType_32BGRA]
                .first { video.availableVideoPixelFormatTypes.contains($0) } ?? kCVPixelFormatType_32BGRA
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            video.setSampleBufferDelegate(self, queue: queue)
            capture.addOutput(video)
            capture.commitConfiguration()

            try camera.lockForConfiguration()
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            // Request ~1 fps, or the lowest rate this exact format supports.
            // Using its boundary duration avoids unsupported-rate exceptions.
            if let range = camera.activeFormat.videoSupportedFrameRateRanges
                .filter({ $0.minFrameRate.isFinite && $0.minFrameRate > 0 })
                .min(by: { $0.minFrameRate < $1.minFrameRate }) {
                let duration: CMTime
                if range.minFrameRate >= 1 { duration = range.maxFrameDuration }
                else if range.maxFrameRate < 1 { duration = range.minFrameDuration }
                else { duration = CMTime(value: 1, timescale: 1) }
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration
            }
            camera.unlockForConfiguration()

            session = capture
            device = camera
            output = video
            observe(capture)
            resetDetector()
            capture.startRunning()
            emit(generation, .status(capture.isRunning ? .running : (capture.isInterrupted ? .unavailable : .failed)))
        } catch {
            video.setSampleBufferDelegate(nil, queue: nil)
            tearDown()
            emit(generation, .status(.failed))
        }
    }

    private func observe(_ capture: AVCaptureSession) {
        let names: [Notification.Name] = [
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.interruptionEndedNotification,
            AVCaptureSession.runtimeErrorNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] note in
                self?.queue.async { [weak self] in self?.handle(note) }
            }
        }
    }

    private func handle(_ notification: Notification) {
        guard requested, let observed = notification.object as? AVCaptureSession, observed === session else { return }
        if notification.name == AVCaptureSession.wasInterruptedNotification {
            emit(generation, .status(.unavailable))
        } else if notification.name == AVCaptureSession.interruptionEndedNotification {
            resetDetector()
            if !observed.isRunning { observed.startRunning() }
            emit(generation, .status(observed.isRunning ? .running : .unavailable))
        } else {
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            if error?.code == AVError.Code.mediaServicesWereReset.rawValue, recoveryAttempts < 2 {
                recoveryAttempts += 1
                tearDown()
                emit(generation, .status(.starting))
                configureAndStart()
            } else {
                tearDown()
                emit(generation, .status(.failed))
            }
        }
    }

    private func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        output = nil
        device = nil
        session = nil
    }

    private func resetDetector() {
        let now = ProcessInfo.processInfo.systemUptime
        detector.reset(at: now)
        suppressedUntil = now + 3
        lastFrame = -.infinity
        lastPublishedLightLevel = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard requested, output === self.output else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.9, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        let samples = luminanceSamples(pixelBuffer)
        guard !samples.isEmpty else { return }
        let exposure = device.flatMap { camera -> Double? in
            let seconds = CMTimeGetSeconds(camera.exposureDuration)
            let product = Double(camera.iso) * seconds
            return product.isFinite && product > 0 ? log2(product) : nil
        }
        let changed = detector.accept(luminance: samples, exposure: exposure, at: now)
        let mean = samples.reduce(0, +) / Double(samples.count)
        let level = illumination.update(mean: mean, exposure: exposure)
        guard now >= suppressedUntil else { return }
        if let level, lastPublishedLightLevel.map({ abs(level - $0) >= 0.015 }) ?? true {
            lastPublishedLightLevel = level
            // Deliver illumination first so a movement wake uses the latest level.
            emit(generation, .lightLevel(level))
        }
        if changed { emit(generation, .activity) }
    }

    private func luminanceSamples(_ pixelBuffer: CVPixelBuffer) -> [Double] {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let videoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              let address = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        var result: [Double] = []
        result.reserveCapacity(48)
        // Only 48 cells and 768 byte samples per analyzed frame. Averaging
        // sixteen spread samples per cell rejects isolated low-light noise.
        for row in 0..<6 {
            for column in 0..<8 {
                var sum = 0.0
                for vertical in 0..<4 {
                    for horizontal in 0..<4 {
                        let x = min(width - 1, (2 * (column * 4 + horizontal) + 1) * width / 64)
                        let y = min(height - 1, (2 * (row * 4 + vertical) + 1) * height / 48)
                        if planar {
                            let value = Double(bytes[y * rowBytes + x])
                            sum += videoRange ? min(1, max(0, (value - 16) / 219)) : value / 255
                        }
                        else {
                            let offset = y * rowBytes + x * 4
                            sum += (0.0722 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.2126 * Double(bytes[offset + 2])) / 255
                        }
                    }
                }
                result.append(sum / 16)
            }
        }
        return result
    }
}
