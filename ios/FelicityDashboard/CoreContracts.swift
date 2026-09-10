import Foundation

/// Platform-facing boundary. The future shared core owns models and state
/// machines; URLSession, VideoToolbox, Keychain and AVAudioEngine stay native.
protocol DashboardProviding: Sendable {
    func current(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot
    func summary(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot
    func status(baseURL: URL) async throws -> ServerStatus
    func chart(baseURL: URL, metric: DashboardMetric) async throws -> DashboardChart
}

protocol CredentialStoring: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

enum MediaSessionState: Equatable, Sendable {
    case idle
    case connecting
    case paused(frameTime: Date)
    case playing(frameTime: Date)
    case failed(message: String)
}

protocol MediaSessionControlling: AnyObject {
    var state: MediaSessionState { get }
    func open(cameraID: String, quality: StreamQuality) async throws
    func seek(to date: Date) async throws
    func pause() async
    func close() async
}

enum StreamQuality: String, CaseIterable, Sendable {
    case lq = "LQ"
    case hq = "HQ"
}
