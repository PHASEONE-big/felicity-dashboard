import Foundation
import SwiftUI

struct CameraDescriptor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let host: String
    let sourceToken: String
    let mainProfile: String
    let subProfile: String
    let mainURI: String
    let subURI: String
    let mainRecording: String?
    let subRecording: String?
    let mainWidth: Int
    let mainHeight: Int
    let subWidth: Int
    let subHeight: Int
    let rotationDegrees: Int
    let isDoorbell: Bool
    let isCorridor: Bool

    var displayAspect: Double {
        let encoded = mainWidth > 0 && mainHeight > 0 ? Double(mainWidth) / Double(mainHeight) : 16 / 9
        if rotationDegrees == 90 || rotationDegrees == 270 { return 1 / encoded }
        return isCorridor ? 9 / 16 : encoded
    }

    func streamURI(for quality: StreamQuality) -> String {
        if quality == .lq, !subURI.isEmpty { return subURI }
        return mainURI
    }

    func encodedSize(for quality: StreamQuality) -> (width: Int, height: Int) {
        if quality == .lq, subWidth > 0, subHeight > 0 { return (subWidth, subHeight) }
        return (max(16, mainWidth), max(16, mainHeight))
    }

    func recordingToken(for quality: StreamQuality) -> String? {
        if quality == .lq, let subRecording, !subRecording.isEmpty { return subRecording }
        return mainRecording.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct RecorderConfiguration: Sendable {
    let host: String
    let username: String
    let password: String
}

@MainActor
final class CameraPreferences: ObservableObject {
    @Published var recorderHost: String
    @Published var recorderUsername: String
    @Published var recorderPassword: String
    @Published var threeEyeURL: String
    @Published var threeEyeUsername: String
    @Published var threeEyePassword: String
    @Published private(set) var saveError = ""

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring
    private let service = "io.github.homedashboard.ios"

    init(defaults: UserDefaults = .standard, credentials: any CredentialStoring = KeychainStore()) {
        self.defaults = defaults
        self.credentials = credentials
        recorderHost = defaults.string(forKey: "recorder.host") ?? "192.168.13.234:8080"
        recorderUsername = defaults.string(forKey: "recorder.username") ?? ""
        threeEyeURL = defaults.string(forKey: "threeeye.url") ?? "http://192.168.13.148:8765"
        threeEyeUsername = defaults.string(forKey: "threeeye.username") ?? ""
        recorderPassword = (try? credentials.read(service: service, account: "recorder.password")) ?? ""
        threeEyePassword = (try? credentials.read(service: service, account: "threeeye.password")) ?? ""
    }

    var recorderConfiguration: RecorderConfiguration {
        RecorderConfiguration(
            host: recorderHost.trimmingCharacters(in: .whitespacesAndNewlines),
            username: recorderUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: recorderPassword
        )
    }

    var threeEyeConfiguration: ThreeEyeConfiguration? {
        guard let baseURL = URL(string: threeEyeURL), baseURL.scheme != nil else { return nil }
        return ThreeEyeConfiguration(
            baseURL: baseURL,
            username: threeEyeUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: threeEyePassword
        )
    }

    func save() {
        recorderHost = recorderHost.trimmingCharacters(in: .whitespacesAndNewlines)
        recorderUsername = recorderUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        threeEyeURL = threeEyeURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        threeEyeUsername = threeEyeUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(recorderHost, forKey: "recorder.host")
        defaults.set(recorderUsername, forKey: "recorder.username")
        defaults.set(threeEyeURL, forKey: "threeeye.url")
        defaults.set(threeEyeUsername, forKey: "threeeye.username")
        do {
            try credentials.write(recorderPassword, service: service, account: "recorder.password")
            try credentials.write(threeEyePassword, service: service, account: "threeeye.password")
            saveError = ""
        } catch {
            saveError = error.localizedDescription
        }
    }
}

@MainActor
final class CameraRepository: ObservableObject {
    @Published private(set) var cameras: [CameraDescriptor] = []
    @Published private(set) var isDiscovering = false
    @Published private(set) var error = ""
    @Published private(set) var selectedID: String

    private let defaults: UserDefaults
    private let discovery: OnvifCameraDiscovery
    private let catalogKey = "camera.catalog.v1"

    init(defaults: UserDefaults = .standard, discovery: OnvifCameraDiscovery = .init()) {
        self.defaults = defaults
        self.discovery = discovery
        selectedID = defaults.string(forKey: "camera.selected") ?? ""
        if let data = defaults.data(forKey: catalogKey), let cached = try? JSONDecoder().decode([CameraDescriptor].self, from: data) {
            cameras = cached
        }
    }

    var selected: CameraDescriptor? {
        cameras.first(where: { $0.id == selectedID }) ?? cameras.first(where: \.isDoorbell) ?? cameras.first
    }

    func select(_ camera: CameraDescriptor) {
        selectedID = camera.id
        defaults.set(camera.id, forKey: "camera.selected")
    }

    func discover(using configuration: RecorderConfiguration) async {
        guard !configuration.host.isEmpty, !configuration.username.isEmpty else {
            error = "Recorder host and ONVIF user are required"
            return
        }
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let discovered = try await discovery.discover(configuration: configuration)
            guard !discovered.isEmpty else { throw CameraDiscoveryError.noProfiles }
            cameras = discovered
            if selected == nil { select(discovered.first(where: \.isDoorbell) ?? discovered[0]) }
            defaults.set(try JSONEncoder().encode(discovered), forKey: catalogKey)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func preferredQuality(for camera: CameraDescriptor, compactDisplay: Bool) -> StreamQuality {
        if let stored = defaults.string(forKey: "camera.quality.\(camera.id)"), let quality = StreamQuality(rawValue: stored) {
            return quality
        }
        return compactDisplay ? .lq : .hq
    }

    func setPreferredQuality(_ quality: StreamQuality, for camera: CameraDescriptor) {
        defaults.set(quality.rawValue, forKey: "camera.quality.\(camera.id)")
    }
}

enum CameraDiscoveryError: LocalizedError {
    case invalidHost
    case invalidResponse
    case noMediaService
    case noProfiles
    case soap(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid recorder host"
        case .invalidResponse: return "Invalid ONVIF response"
        case .noMediaService: return "Recorder did not expose the ONVIF media service"
        case .noProfiles: return "Recorder returned no camera profiles"
        case let .soap(message): return "ONVIF: \(message)"
        }
    }
}
