import Foundation
import SwiftUI
import UIKit

struct DoorbellCallSession: Identifiable {
    let id = UUID()
    let camera: CameraDescriptor
    let receivedAt: Date
    var captureCaller = true
}

private struct DoorbellStoredPreview: Codable {
    let camera: CameraDescriptor
    let receivedAt: Date
    let jpeg: Data
}

private actor DoorbellPreviewStore {
    private let url: URL
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = root.appendingPathComponent("FelicityDoorbell", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = folder.appendingPathComponent("last-ring.json")
    }
    func load() -> DoorbellStoredPreview? {
        guard let data = try? Data(contentsOf: url), let preview = try? JSONDecoder().decode(DoorbellStoredPreview.self, from: data),
              Date().timeIntervalSince(preview.receivedAt) < 1800 else { return nil }
        return preview
    }
    func save(_ preview: DoorbellStoredPreview) {
        guard let data = try? JSONEncoder().encode(preview) else { return }
        try? data.write(to: url, options: .atomic)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class DoorbellController: ObservableObject {
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "doorbell.enabled"); if !enabled { close() } }
    }
    @Published private(set) var session: DoorbellCallSession?
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var thumbnailDate: Date?
    @Published private(set) var thumbnailCamera: CameraDescriptor?
    @Published private(set) var status = "Waiting for recorder settings" {
        didSet { defaults.set(status, forKey: "doorbell.lastStatus") }
    }
    @Published private(set) var secondsRemaining = 60
    let audio = DoorbellAudio()

    private let defaults: UserDefaults
    private let events = OnvifDoorbellEvents()
    private let previews = DoorbellPreviewStore()
    private var policy = DoorbellCallPolicy()
    private var timer: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var microphoneTask: Task<Void, Never>?
    private var imageRevision = 0
    private var active = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "doorbell.enabled") as? Bool ?? true
    }

    var isPresenting: Bool { session != nil }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func restorePreview() async {
        let revision = imageRevision
        guard let preview = await previews.load(), revision == imageRevision,
              let image = CameraPreviewStore.thumbnail(from: preview.jpeg) else { return }
        thumbnail = image
        thumbnailDate = preview.receivedAt
        thumbnailCamera = preview.camera
        scheduleExpiry()
    }

    func monitor(configuration: RecorderConfiguration, cameras: @escaping @MainActor () -> [CameraDescriptor]) async {
        guard enabled, !configuration.username.isEmpty, !configuration.host.isEmpty else {
            status = enabled ? "Set up the ONVIF recorder to receive rings" : "Doorbell alerts are off"
            return
        }
        await events.run(configuration: configuration, onStatus: { [weak self] value in
            self?.status = value
        }, onRing: { [weak self] source in
            self?.receiveRing(sourceToken: source, cameras: cameras())
        })
    }

    func setActive(_ value: Bool) {
        active = value
        if !value { close() }
    }

    func receiveRing(sourceToken: String, cameras: [CameraDescriptor]) {
        guard active, enabled, let camera = Self.camera(for: sourceToken, in: cameras), policy.ring(at: now) else { return }
        audio.stop()
        microphoneTask?.cancel()
        clearThumbnail()
        session = DoorbellCallSession(camera: camera, receivedAt: .now)
        startTimer()
    }

    static func camera(for sourceToken: String, in cameras: [CameraDescriptor]) -> CameraDescriptor? {
        let source = sourceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty, let exact = cameras.first(where: { $0.sourceToken == source && $0.isDoorbell }) { return exact }
        // A ring notification with a missing/unknown source must never open an
        // unrelated camera. The explicitly identified doorbell is the fallback.
        return cameras.first(where: \.isDoorbell)
    }

    func reopen() {
        guard active, let camera = thumbnailCamera else { return }
        audio.stop()
        microphoneTask?.cancel()
        policy.close()
        // A thumbnail tap is a manual preview, not a new ring or a new snapshot.
        policy.openPreview(at: now)
        session = DoorbellCallSession(camera: camera, receivedAt: thumbnailDate ?? .now, captureCaller: false)
        startTimer()
    }

    func preview(camera: CameraDescriptor) {
        guard active else { return }
        audio.stop()
        microphoneTask?.cancel()
        policy.openPreview(at: now)
        session = DoorbellCallSession(camera: camera, receivedAt: .now, captureCaller: false)
        startTimer()
    }

    func toggleMicrophone(configuration: RecorderConfiguration) {
        guard let session else { return }
        if policy.microphoneActive {
            microphoneTask?.cancel()
            audio.stopTalking()
            policy.endTalking(at: now)
            return
        }
        // Start the same 30-second safety deadline as Android, including setup
        // and permission time. No event can switch the microphone on by itself.
        policy.beginTalking(at: now)
        let id = session.id
        microphoneTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.session?.id == id else { return }
            await self.audio.startTalking(camera: session.camera, configuration: configuration)
            guard !Task.isCancelled, self.session?.id == id else { return }
            if !self.audio.microphoneEnabled { self.policy.endTalking(at: self.now) }
            else if !self.audio.listeningEnabled {
                await self.audio.setListening(true, camera: session.camera, configuration: configuration)
            }
        }
    }

    func microphoneStopped() {
        if policy.microphoneActive { policy.endTalking(at: now) }
    }

    func saveSnapshot(_ jpeg: Data, sessionID: UUID) async {
        guard let current = session, current.id == sessionID, current.captureCaller else { return }
        let revision = imageRevision
        // Reuse the bounded, orientation-correct camera preview pipeline.
        guard let image = await CameraPreviewStore.shared.saveAndReturn(jpeg, for: current.camera),
              revision == imageRevision, let compact = image.jpegData(compressionQuality: 0.85) else { return }
        thumbnail = image
        thumbnailDate = current.receivedAt
        thumbnailCamera = current.camera
        await previews.save(.init(camera: current.camera, receivedAt: current.receivedAt, jpeg: compact))
        scheduleExpiry()
    }

    func close() {
        microphoneTask?.cancel(); microphoneTask = nil
        audio.stop()
        policy.close()
        session = nil
        timer?.cancel(); timer = nil
    }

    func clearThumbnail() {
        imageRevision += 1
        thumbnail = nil; thumbnailDate = nil; thumbnailCamera = nil
        expiry?.cancel(); expiry = nil
        Task { await previews.remove() }
    }

    private func startTimer() {
        timer?.cancel()
        secondsRemaining = 60
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session != nil else { return }
                if self.policy.update(at: self.now) { self.close(); return }
                self.secondsRemaining = max(0, Int(ceil((self.policy.deadline ?? self.now) - self.now)))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let date = thumbnailDate else { return }
        let revision = imageRevision
        let delay = max(0, 1800 - Date().timeIntervalSince(date))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, revision == self.imageRevision else { return }
            self.clearThumbnail()
        }
    }
}
