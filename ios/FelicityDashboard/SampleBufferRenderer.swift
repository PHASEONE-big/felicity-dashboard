import AVFoundation
import CoreImage
import SwiftUI
import VideoToolbox

private final class PreviewDecodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CVPixelBuffer?

    func replace(with pixelBuffer: CVPixelBuffer) {
        lock.lock()
        stored = pixelBuffer
        lock.unlock()
    }

    func value() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

struct RenderGenerationGate {
    private(set) var current: UInt64 = 0

    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    func accepts(_ generation: UInt64) -> Bool { generation == current }
}

@MainActor
final class SampleBufferRenderer: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var isReady = false
    @Published private(set) var error = ""

    private var streamFormat: VideoStreamFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var discoveredParameterSets: [Int: Data] = [:]
    private var generations = RenderGenerationGate()
    private var flushingGeneration: UInt64?
    private var readyGeneration: UInt64?
    private var pendingUnits: [VideoAccessUnit] = []
    private var displayedPixelAddressBeforeSeek: UnsafeMutableRawPointer?
    private var readinessTask: Task<Void, Never>?
    // iOS 16 cannot expose AVSampleBufferDisplayLayer's displayed pixel buffer.
    // Retain only the latest random-access unit for a camera-wall poster. Keeping
    // an entire GOP here makes the live render path retain and release megabytes
    // of compressed video on the main actor and causes visible playback stalls.
    private var previewKeyframe: VideoAccessUnit?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func configure(_ format: VideoStreamFormat) {
        flush()
        streamFormat = format
        previewKeyframe = nil
        discoveredParameterSets.removeAll()
        for value in format.parameterSets { registerParameterSet(value, isHEVC: format.isHEVC) }
        rebuildFormatDescriptionIfPossible()
    }

    func enqueue(_ unit: VideoAccessUnit) {
        _ = enqueue(unit, generation: generations.current)
    }

    @discardableResult
    func enqueue(_ unit: VideoAccessUnit, generation: UInt64) -> Bool {
        guard generations.accepts(generation) else { return false }
        if flushingGeneration == generation {
            // A seek flush is asynchronous. Retain only this generation's short
            // lead-in so no access unit from the previous position can cross it.
            pendingUnits.append(unit)
            if pendingUnits.count > 90 { pendingUnits.removeFirst(pendingUnits.count - 90) }
            return true
        }
        enqueueNow(unit, generation: generation)
        return true
    }

    private func enqueueNow(_ unit: VideoAccessUnit, generation: UInt64) {
        guard generations.accepts(generation) else { return }
        guard let streamFormat else { return }
        if unit.isKeyframe { previewKeyframe = unit }
        let ranges = Self.annexBNALRanges(unit.annexB)
        registerParameterSets(in: unit.annexB, ranges: ranges, isHEVC: streamFormat.isHEVC)
        if formatDescription == nil { rebuildFormatDescriptionIfPossible() }
        guard let formatDescription,
              let sample = Self.sampleBuffer(annexB: unit.annexB, ranges: ranges, format: formatDescription, keyframe: unit.isKeyframe) else { return }
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            }
            guard renderer.isReadyForMoreMediaData else { return }
            renderer.enqueue(sample)
        } else {
            if layer.status == .failed { layer.flush() }
            guard layer.isReadyForMoreMediaData else { return }
            layer.enqueue(sample)
        }
        monitorReadiness(for: generation)
    }

    func flush() {
        readinessTask?.cancel()
        readinessTask = nil
        displayedPixelAddressBeforeSeek = displayedPixelAddress()
        let generation = generations.advance()
        pendingUnits.removeAll(keepingCapacity: true)
        flushingGeneration = generation
        readyGeneration = nil
        formatDescription = nil
        isReady = false
        error = ""
        flushLayer(removingDisplayedImage: false, generation: generation)
    }

    @discardableResult
    func beginSeek() -> UInt64 {
        readinessTask?.cancel()
        readinessTask = nil
        displayedPixelAddressBeforeSeek = displayedPixelAddress()
        let generation = generations.advance()
        pendingUnits.removeAll(keepingCapacity: true)
        flushingGeneration = generation
        readyGeneration = nil
        // Keep the one already displayed frame stable until the new keyframe is
        // decoded. In particular, do not reveal the old event poster on every seek.
        error = ""
        flushLayer(removingDisplayedImage: false, generation: generation)
        return generation
    }

    func isReady(for generation: UInt64) -> Bool {
        generations.accepts(generation) && readyGeneration == generation
    }

    func removeDisplayedImage() {
        readinessTask?.cancel()
        readinessTask = nil
        displayedPixelAddressBeforeSeek = nil
        let generation = generations.advance()
        pendingUnits.removeAll(keepingCapacity: true)
        flushingGeneration = generation
        readyGeneration = nil
        isReady = false
        flushLayer(removingDisplayedImage: true, generation: generation)
    }

    func snapshotJPEG(quality: CGFloat = 0.84) async -> Data? {
        if #available(iOS 17.4, *), let pixelBuffer = layer.sampleBufferRenderer.displayedPixelBuffer() {
            return await Task.detached(priority: .utility) {
                Self.encodeJPEG(pixelBuffer: pixelBuffer, quality: quality)
            }.value
        }
        guard let streamFormat, let previewKeyframe else { return nil }
        let parameterSets = discoveredParameterSets
        return await Task.detached(priority: .utility) {
            Self.decodePreviewJPEG(
                format: streamFormat,
                parameterSets: parameterSets,
                units: [previewKeyframe],
                quality: quality
            )
        }.value
    }

    private func registerParameterSet(_ value: Data, isHEVC: Bool) {
        guard let first = value.first else { return }
        let type = isHEVC ? Int((first >> 1) & 0x3f) : Int(first & 0x1f)
        if isHEVC, [32, 33, 34].contains(type) { discoveredParameterSets[type] = value }
        if !isHEVC, [7, 8].contains(type) { discoveredParameterSets[type] = value }
    }

    private func registerParameterSets(in data: Data, ranges: [Range<Data.Index>], isHEVC: Bool) {
        for range in ranges {
            guard range.lowerBound < range.upperBound else { continue }
            let first = data[range.lowerBound]
            let type = isHEVC ? Int((first >> 1) & 0x3f) : Int(first & 0x1f)
            guard isHEVC ? (32...34).contains(type) : (type == 7 || type == 8) else { continue }
            discoveredParameterSets[type] = data.subdata(in: range)
        }
    }

    private func flushLayer(removingDisplayedImage: Bool, generation: UInt64) {
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: removingDisplayedImage) { [weak self] in
                Task { @MainActor in self?.finishFlush(generation: generation) }
            }
        } else {
            if removingDisplayedImage { layer.flushAndRemoveImage() }
            else { layer.flush() }
            finishFlush(generation: generation)
        }
    }

    private func finishFlush(generation: UInt64) {
        guard generations.accepts(generation), flushingGeneration == generation else { return }
        flushingGeneration = nil
        let queued = pendingUnits
        pendingUnits.removeAll(keepingCapacity: true)
        for unit in queued { enqueueNow(unit, generation: generation) }
    }

    private func monitorReadiness(for generation: UInt64) {
        guard readyGeneration != generation, readinessTask == nil else { return }
        readinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, self.generations.accepts(generation) else { return }
                let ready: Bool
                if #available(iOS 17.4, *) {
                    let address = self.displayedPixelAddress()
                    ready = self.layer.isReadyForDisplay && address != nil && address != self.displayedPixelAddressBeforeSeek
                } else if #available(iOS 17.0, *) {
                    // `.unknown` is the normal state before the decoder has
                    // presented anything. Treating it as ready hid the saved
                    // poster and advanced the archive cursor before a real
                    // frame reached older devices.
                    ready = self.layer.sampleBufferRenderer.status == .rendering
                } else {
                    ready = self.layer.status == .rendering
                }
                if ready {
                    self.readyGeneration = generation
                    self.isReady = true
                    self.readinessTask = nil
                    return
                }
            }
            self.readinessTask = nil
        }
    }

    private func displayedPixelAddress() -> UnsafeMutableRawPointer? {
        guard #available(iOS 17.4, *), let pixel = layer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        return Unmanaged.passUnretained(pixel).toOpaque()
    }

    private func rebuildFormatDescriptionIfPossible() {
        guard let streamFormat else { return }
        let wanted = streamFormat.isHEVC ? [32, 33, 34] : [7, 8]
        let sets = wanted.compactMap { discoveredParameterSets[$0] }
        guard sets.count == wanted.count else { return }
        let storage = sets.map { $0 as NSData }
        var pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = storage.map(\.length)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeMutableBufferPointer { pointerBuffer in
            sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                if streamFormat.isHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        if status == noErr { formatDescription = description }
        else { error = "Video format \(status)" }
    }

    nonisolated private static func sampleBuffer(
        annexB: Data,
        ranges: [Range<Data.Index>],
        format: CMVideoFormatDescription,
        keyframe: Bool
    ) -> CMSampleBuffer? {
        var payload = Data()
        payload.reserveCapacity(ranges.reduce(0) { $0 + $1.count + 4 })
        for range in ranges {
            var length = UInt32(range.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: annexB[range])
        }
        guard !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [[CFString: Any]], var first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
            first[kCMSampleAttachmentKey_NotSync] = !keyframe
            if let mutable = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(mutable) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(mutable, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(keyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    nonisolated private static func decodePreviewJPEG(
        format: VideoStreamFormat,
        parameterSets: [Int: Data],
        units: [VideoAccessUnit],
        quality: CGFloat
    ) -> Data? {
        let wanted = format.isHEVC ? [32, 33, 34] : [7, 8]
        let sets = wanted.compactMap { parameterSets[$0] }
        guard sets.count == wanted.count,
              let description = makeFormatDescription(isHEVC: format.isHEVC, parameterSets: sets) else { return nil }

        let box = PreviewDecodeBox()
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        let callback: VTDecompressionOutputCallback = { outputRefCon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let outputRefCon, let imageBuffer else { return }
            Unmanaged<PreviewDecodeBox>.fromOpaque(outputRefCon).takeUnretainedValue().replace(with: imageBuffer)
        }
        var session: VTDecompressionSession?
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: refcon
        )
        let imageAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        ) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        for unit in units {
            let ranges = annexBNALRanges(unit.annexB)
            guard let sample = sampleBuffer(annexB: unit.annexB, ranges: ranges, format: description, keyframe: unit.isKeyframe) else { continue }
            var flags = VTDecodeInfoFlags()
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: &flags
            )
            if status != noErr { break }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard let pixelBuffer = box.value() else { return nil }
        return encodeJPEG(pixelBuffer: pixelBuffer, quality: quality)
    }

    nonisolated private static func encodeJPEG(pixelBuffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let maximumDimension = max(image.extent.width, image.extent.height)
        if maximumDimension > 720 {
            let scale = 720 / maximumDimension
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
        guard let rendered = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: rendered).jpegData(compressionQuality: quality)
    }

    nonisolated private static func makeFormatDescription(
        isHEVC: Bool,
        parameterSets: [Data]
    ) -> CMVideoFormatDescription? {
        let storage = parameterSets.map { $0 as NSData }
        var pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes = storage.map(\.length)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeMutableBufferPointer { pointerBuffer in
            sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                if isHEVC {
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return status == noErr ? description : nil
    }

    nonisolated static func annexBNALUnits(_ data: Data) -> [Data] {
        annexBNALRanges(data).map { data.subdata(in: $0) }
    }

    nonisolated private static func annexBNALRanges(_ data: Data) -> [Range<Data.Index>] {
        var starts: [(offset: Data.Index, prefix: Int)] = []
        var index = data.startIndex
        while index + 3 < data.endIndex {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else if index + 4 <= data.endIndex, data[index] == 0, data[index + 1] == 0, data[index + 2] == 0, data[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else { index += 1 }
        }
        guard !starts.isEmpty else { return data.isEmpty ? [] : [data.startIndex..<data.endIndex] }
        return starts.enumerated().compactMap { item in
            let begin = item.element.offset + item.element.prefix
            let end = item.offset + 1 < starts.count ? starts[item.offset + 1].offset : data.endIndex
            return begin < end ? begin..<end : nil
        }
    }
}

struct ZoomableVideoView: UIViewRepresentable {
    let renderer: SampleBufferRenderer
    let aspect: Double
    let rotationDegrees: Int

    func makeUIView(context: Context) -> ZoomableVideoHost {
        ZoomableVideoHost(layer: renderer.layer)
    }

    func updateUIView(_ view: ZoomableVideoHost, context: Context) {
        view.update(aspect: aspect, rotationDegrees: rotationDegrees)
    }
}

final class ZoomableVideoHost: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let content = UIView()
    private let displayLayer: AVSampleBufferDisplayLayer
    private var aspect = 16 / 9.0
    private var rotationDegrees = 0

    init(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        super.init(frame: .zero)
        backgroundColor = .black
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        addSubview(scrollView)
        scrollView.addSubview(content)
        content.layer.addSublayer(displayLayer)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetZoom))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { nil }

    func update(aspect: Double, rotationDegrees: Int) {
        guard self.aspect != aspect || self.rotationDegrees != rotationDegrees else { return }
        self.aspect = max(0.1, aspect)
        self.rotationDegrees = rotationDegrees
        resetZoom()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let viewAspect = bounds.width / max(1, bounds.height)
        let size: CGSize
        if aspect > viewAspect { size = CGSize(width: bounds.width, height: bounds.width / aspect) }
        else { size = CGSize(width: bounds.height * aspect, height: bounds.height) }
        content.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        let radians = CGFloat(rotationDegrees) * .pi / 180
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
        if rotationDegrees == 90 || rotationDegrees == 270 {
            displayLayer.bounds = CGRect(x: 0, y: 0, width: size.height, height: size.width)
        } else {
            displayLayer.bounds = CGRect(origin: .zero, size: size)
        }
        displayLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        centerContent()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func resetZoom() {
        scrollView.setZoomScale(1, animated: true)
        centerContent()
    }

    private func centerContent() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
