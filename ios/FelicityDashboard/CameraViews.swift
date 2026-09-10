import CryptoKit
import ImageIO
import SwiftUI
import UIKit

actor CameraPreviewStore {
    static let shared = CameraPreviewStore()
    private let directory: URL

    init(fileManager: FileManager = .default, root: URL? = nil) {
        let root = root ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        directory = root.appending(path: "FelicityCameraPreviews", directoryHint: .isDirectory)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    func data(for camera: CameraDescriptor) -> Data? { try? Data(contentsOf: url(for: camera.id)) }

    func image(for camera: CameraDescriptor) -> UIImage? {
        guard let data = data(for: camera), let image = Self.thumbnail(from: data) else { return nil }
        // Migrate previews written by older builds so the next wall open does
        // not decode the original 4K frame again.
        if data.count > 420_000, let compact = image.jpegData(compressionQuality: 0.82) {
            try? compact.write(to: url(for: camera.id), options: .atomic)
        }
        return image
    }

    func images(for cameras: [CameraDescriptor]) -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        result.reserveCapacity(cameras.count)
        for camera in cameras {
            guard let image = image(for: camera) else { continue }
            result[camera.id] = image
        }
        return result
    }

    func save(_ jpeg: Data, for camera: CameraDescriptor) {
        guard let source = Self.thumbnail(from: jpeg),
              let oriented = Self.rotated(source, degrees: camera.rotationDegrees),
              let output = oriented.jpegData(compressionQuality: 0.82) else { return }
        try? output.write(to: url(for: camera.id), options: .atomic)
    }

    private func url(for id: String) -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).jpg")
    }

    private static func rotated(_ image: UIImage, degrees: Int) -> UIImage? {
        guard degrees != 0, let cgImage = image.cgImage else { return image }
        let swap = degrees == 90 || degrees == 270
        let size = swap ? CGSize(width: cgImage.height, height: cgImage.width) : CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: CGFloat(degrees) * .pi / 180)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(cgImage, in: CGRect(x: -CGFloat(cgImage.width) / 2, y: -CGFloat(cgImage.height) / 2, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        }
    }

    nonisolated static func thumbnail(from data: Data, maxPixelSize: Int = 720) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct CameraWallView: View {
    @ObservedObject var repository: CameraRepository
    let backLabel: String
    let onSelect: (CameraDescriptor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var previews: [String: UIImage] = [:]

    var body: some View {
        GeometryReader { proxy in
            let columns = max(2, min(4, Int(proxy.size.width / 300)))
            VStack(spacing: 0) {
                CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        Text("SELECT CAMERA")
                            .font(.title2.bold())
                            .foregroundStyle(.cyan)
                    }
                    .padding(12)
                    .background(Color(red: 14 / 255, green: 48 / 255, blue: 43 / 255))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                        ForEach(repository.cameras) { camera in
                            Button {
                                repository.select(camera)
                                onSelect(camera)
                                dismiss()
                            } label: {
                                CameraCard(
                                    camera: camera,
                                    selected: repository.selectedID == camera.id,
                                    preview: previews[camera.id]
                                )
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                    }
                    .padding(14)
                }
            }
            .background(Color(red: 7 / 255, green: 17 / 255, blue: 15 / 255).ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task(id: repository.cameras.map(\.id)) {
            previews = await CameraPreviewStore.shared.images(for: repository.cameras)
        }
    }
}

private struct CameraCard: View {
    let camera: CameraDescriptor
    let selected: Bool
    let preview: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            CameraThumbnail(image: preview)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(.black)
            HStack {
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(camera.subURI.isEmpty ? "HQ" : "LQ · HQ")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
        .foregroundStyle(selected ? .cyan : .white)
        .background(Color(red: 13 / 255, green: 39 / 255, blue: 35 / 255), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? .cyan : .cyan.opacity(0.22), lineWidth: selected ? 2 : 1))
    }
}

private struct CameraThumbnail: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title)
                    Text("NO PREVIEW")
                        .font(.caption.bold())
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class LiveCameraViewModel: ObservableObject {
    @Published private(set) var state: MediaSessionState = .idle
    @Published private(set) var statistics = LiveStreamStatistics(kbps: 0, fps: 0)
    @Published private(set) var format: VideoStreamFormat?
    @Published private(set) var quality: StreamQuality
    let renderer = SampleBufferRenderer()

    @Published private(set) var camera: CameraDescriptor
    private let repository: CameraRepository
    private let preferences: CameraPreferences
    private let session = LiveRTSPSession()
    private var running = false

    init(camera: CameraDescriptor, repository: CameraRepository, preferences: CameraPreferences) {
        self.camera = camera
        self.repository = repository
        self.preferences = preferences
        quality = repository.preferredQuality(for: camera, compactDisplay: UIScreen.main.bounds.width < 700)
    }

    var stateLabel: String {
        switch state {
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING…"
        case .paused: return "PAUSED"
        case .playing: return "LIVE"
        case .failed: return "STREAM ERROR"
        }
    }

    var errorMessage: String? {
        guard case let .failed(message) = state else { return nil }
        return message
    }

    func start() async {
        guard !running else { return }
        let uri = camera.streamURI(for: quality)
        guard !uri.isEmpty else {
            state = .failed(message: "Refresh the recorder camera catalogue")
            return
        }
        running = true
        let size = camera.encodedSize(for: quality)
        await session.start(
            uri: uri,
            username: preferences.recorderUsername,
            password: preferences.recorderPassword,
            fallbackSize: size,
            onFormat: { [weak self] value in
                self?.format = value
                self?.renderer.configure(value)
            },
            onFrame: { [weak self] unit in
                self?.renderer.enqueue(unit)
            },
            onStatistics: { [weak self] value in
                self?.statistics = value
            },
            onState: { [weak self] value in
                self?.state = value
            }
        )
    }

    func stop(savePreview: Bool = true) async {
        guard running else { return }
        running = false
        await session.stop()
        state = .idle
        if savePreview { savePreviewInBackground(for: camera) }
    }

    func toggleQuality() async {
        if let jpeg = await renderer.snapshotJPEG() { await CameraPreviewStore.shared.save(jpeg, for: camera) }
        await session.stop()
        running = false
        quality = quality == .lq ? .hq : .lq
        repository.setPreferredQuality(quality, for: camera)
        statistics = .init(kbps: 0, fps: 0)
        await start()
    }

    func switchCamera(to camera: CameraDescriptor, saveCurrentPreview: Bool = true) async {
        guard camera.id != self.camera.id else { return }
        if saveCurrentPreview, let jpeg = await renderer.snapshotJPEG() { await CameraPreviewStore.shared.save(jpeg, for: self.camera) }
        await session.stop()
        running = false
        renderer.flush()
        self.camera = camera
        repository.select(camera)
        quality = repository.preferredQuality(for: camera, compactDisplay: UIScreen.main.bounds.width < 700)
        statistics = .init(kbps: 0, fps: 0)
        format = nil
        await start()
    }

    private func savePreviewInBackground(for camera: CameraDescriptor) {
        Task { [renderer] in
            guard let jpeg = await renderer.snapshotJPEG() else { return }
            await CameraPreviewStore.shared.save(jpeg, for: camera)
        }
    }
}

struct LiveCameraView: View {
    @ObservedObject var repository: CameraRepository
    @ObservedObject var preferences: CameraPreferences
    @StateObject private var model: LiveCameraViewModel
    @State private var pickerPresented = false
    @State private var eventsPresented = false
    @State private var archivePresented = false
    @State private var pendingCamera: CameraDescriptor?
    @Environment(\.dismiss) private var dismiss

    init(camera: CameraDescriptor, repository: CameraRepository, preferences: CameraPreferences) {
        self.repository = repository
        self.preferences = preferences
        _model = StateObject(wrappedValue: LiveCameraViewModel(camera: camera, repository: repository, preferences: preferences))
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height > proxy.size.width || proxy.size.width < 900
            VStack(spacing: 0) {
                liveHeader(compact: compact)
                ZStack {
                    LiveVideoCanvas(renderer: model.renderer, camera: model.camera)
                    if let error = model.errorMessage {
                        Text(error)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.orange)
                            .padding(24)
                            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear {
            guard !pickerPresented, !eventsPresented, !archivePresented else { return }
            Task { await model.stop() }
        }
        .fullScreenCover(isPresented: $pickerPresented, onDismiss: {
            let selected = pendingCamera
            pendingCamera = nil
            Task {
                if let selected, selected.id != model.camera.id { await model.switchCamera(to: selected, saveCurrentPreview: false) }
                else { await model.start() }
            }
        }) {
            CameraWallView(repository: repository, backLabel: "LIVE") { camera in
                pendingCamera = camera
            }
        }
        .fullScreenCover(isPresented: $eventsPresented, onDismiss: {
            Task { await model.start() }
        }) {
            if let configuration = preferences.threeEyeConfiguration {
                EventsView(configuration: configuration, cameraName: model.camera.name, backLabel: "LIVE", repository: repository, preferences: preferences)
            }
        }
        .fullScreenCover(isPresented: $archivePresented, onDismiss: {
            Task { await model.start() }
        }) {
            ArchiveView(camera: model.camera, event: nil, backLabel: "LIVE", repository: repository, preferences: preferences)
        }
    }

    private func liveHeader(compact: Bool) -> some View {
        Group {
            if !compact {
            HStack(spacing: 10) {
                navigationButtons
                streamStatistics
                    .frame(maxWidth: .infinity)
                qualityAndPrivacy
                CameraBarButton(title: "ARCHIVE", systemImage: "clock.arrow.circlepath") { presentArchive() }
                Text(model.stateLabel)
                    .font(.caption.bold())
                    .foregroundStyle(model.errorMessage == nil ? .green : .orange)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.day().month().year().hour().minute().second())
                        .font(.caption.bold().monospacedDigit())
                }
            }
            } else {
            HStack(spacing: 8) {
                CameraBarButton(title: "ENERGY", systemImage: "chevron.left") { dismiss() }
                CameraBarButton(title: model.camera.name, systemImage: "video.fill") { presentCameraPicker() }
                CameraBarButton(title: "EVENTS", systemImage: "rectangle.stack.badge.person.crop") { presentEvents() }
                Spacer(minLength: 0)
                streamStatistics
                qualityAndPrivacy
                CameraBarButton(title: "ARCHIVE", systemImage: "clock.arrow.circlepath") { presentArchive() }
            }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
        .foregroundStyle(.white)
        .background(Color(red: 14 / 255, green: 48 / 255, blue: 43 / 255))
    }

    @ViewBuilder private var navigationButtons: some View {
        CameraBarButton(title: "ENERGY", systemImage: "chevron.left") { dismiss() }
        CameraBarButton(title: model.camera.name, systemImage: "video.fill") { presentCameraPicker() }
        CameraBarButton(title: "EVENTS", systemImage: "rectangle.stack.badge.person.crop") { presentEvents() }
    }

    private var streamStatistics: some View {
        VStack(spacing: 1) {
            Text("\(Int(model.statistics.kbps.rounded())) kbps · \(model.statistics.fps, specifier: "%.1f") FPS")
            Text("\(model.format?.width ?? model.camera.encodedSize(for: model.quality).width)×\(model.format?.height ?? model.camera.encodedSize(for: model.quality).height) · \(model.format?.codecName ?? "—")")
        }
        .font(.caption.bold().monospacedDigit())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var qualityAndPrivacy: some View {
        HStack(spacing: 8) {
            Button(model.quality.rawValue) { Task { await model.toggleQuality() } }
                .buttonStyle(HeaderButtonStyle())
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func presentCameraPicker() {
        Task { @MainActor in
            await model.stop()
            pickerPresented = true
        }
    }

    private func presentEvents() {
        Task { @MainActor in
            await model.stop()
            eventsPresented = true
        }
    }

    private func presentArchive() {
        Task { @MainActor in
            await model.stop()
            archivePresented = true
        }
    }
}

private struct LiveVideoCanvas: View {
    @ObservedObject var renderer: SampleBufferRenderer
    let camera: CameraDescriptor
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            Color.black
            ZoomableVideoView(renderer: renderer, aspect: camera.displayAspect, rotationDegrees: camera.rotationDegrees)
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
                    .opacity(renderer.isReady ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: renderer.isReady)
        .task(id: camera.id) {
            poster = nil
            poster = await CameraPreviewStore.shared.image(for: camera)
        }
    }
}

struct CameraBarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 88, minHeight: 42)
        }
        .buttonStyle(HeaderButtonStyle())
    }
}

struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(configuration.isPressed ? Color.cyan.opacity(0.34) : Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
