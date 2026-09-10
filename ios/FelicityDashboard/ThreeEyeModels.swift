import Foundation

struct ThreeEyeConfiguration: Sendable, Hashable {
    let baseURL: URL
    let username: String
    let password: String
}

enum ThreeEyeEventClass: String, CaseIterable, Hashable, Sendable {
    case person
    case vehicle
    case animal
    case face

    var title: String {
        switch self {
        case .person: return "PERSON"
        case .vehicle: return "VEHICLE"
        case .animal: return "ANIMAL"
        case .face: return "FACE"
        }
    }

    var systemImage: String {
        switch self {
        case .person: return "person.fill"
        case .vehicle: return "car.fill"
        case .animal: return "pawprint.fill"
        case .face: return "faceid"
        }
    }
}

struct ThreeEyeEvent: Identifiable, Hashable, Sendable {
    let id: String
    let trackID: Int64
    let eventClass: ThreeEyeEventClass
    let capturedAt: Date?
    let capturedAtRaw: String
    let firstSeenRaw: String
    let lastSeenRaw: String
    let camera: String
    let confidence: Double
    let thumbnailURL: URL?
    let imageURL: URL?
}

actor ThreeEyeAPI {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func events(
        configuration: ThreeEyeConfiguration,
        camera: String?,
        classes: Set<ThreeEyeEventClass>,
        limit: Int = 54
    ) async throws -> [ThreeEyeEvent] {
        var components = URLComponents(url: configuration.baseURL.appending(path: "api/objects"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(200, limit))))]
        if let camera, !camera.isEmpty { query.append(URLQueryItem(name: "cameras", value: camera)) }
        for kind in ThreeEyeEventClass.allCases where classes.contains(kind) {
            query.append(URLQueryItem(name: "classes", value: kind.rawValue))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw ThreeEyeError.invalidAddress }
        let data = try await request(url: url, configuration: configuration)
        return try Self.parseEvents(data, baseURL: configuration.baseURL)
    }

    static func parseEvents(_ data: Data, baseURL: URL) throws -> [ThreeEyeEvent] {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let objects = root["objects"] as? [[String: Any]]
        else { throw ThreeEyeError.invalidPayload }

        return objects.compactMap { object in
            guard
                let rawClass = string(object["object_class"]),
                let eventClass = ThreeEyeEventClass(rawValue: rawClass.lowercased())
            else { return nil }
            let captured = firstNonEmpty(object, keys: ["captured_at_utc", "group_last_seen_utc"])
            let trackID = int64(object["track_id"])
            let thumbnail = absoluteURL(string(object["thumbnail_url"]), relativeTo: baseURL)
            let image = absoluteURL(string(object["image_url"]), relativeTo: baseURL)
            let identity = trackID != 0 ? String(trackID) : [captured, string(object["camera_name"]) ?? "", rawClass].joined(separator: "|")
            return ThreeEyeEvent(
                id: identity,
                trackID: trackID,
                eventClass: eventClass,
                capturedAt: Self.date(from: captured),
                capturedAtRaw: captured,
                firstSeenRaw: firstNonEmpty(object, keys: ["first_seen_utc", "group_first_seen_utc", "captured_at_utc"]),
                lastSeenRaw: firstNonEmpty(object, keys: ["last_seen_utc", "group_last_seen_utc", "captured_at_utc"]),
                camera: string(object["camera_name"]) ?? "—",
                confidence: double(object["confidence"]),
                thumbnailURL: thumbnail,
                imageURL: image
            )
        }
        .sorted { ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
    }

    func imageData(url: URL, configuration: ThreeEyeConfiguration) async throws -> Data {
        try await request(url: url, configuration: configuration)
    }

    private func request(url: URL, configuration: ThreeEyeConfiguration) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if !configuration.username.isEmpty {
            let token = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ThreeEyeError.invalidPayload }
        guard http.statusCode == 200 else { throw ThreeEyeError.http(http.statusCode) }
        return data
    }

    private static func absoluteURL(_ value: String?, relativeTo baseURL: URL) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private static func firstNonEmpty(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        return ""
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        return Int64(string(value) ?? "") ?? 0
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        return Double(string(value) ?? "") ?? 0
    }

    private static func date(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

actor ThreeEyeImageStore {
    static let shared = ThreeEyeImageStore()
    private let api = ThreeEyeAPI()
    private var cache: [URL: Data] = [:]

    func data(for url: URL, configuration: ThreeEyeConfiguration) async throws -> Data {
        if let cached = cache[url] { return cached }
        let data = try await api.imageData(url: url, configuration: configuration)
        cache[url] = data
        return data
    }
}

enum ThreeEyeError: LocalizedError {
    case invalidAddress
    case invalidPayload
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Invalid 3ye address"
        case .invalidPayload: return "Invalid 3ye response"
        case let .http(code) where code == 401: return "3ye username or password is incorrect"
        case let .http(code): return "3ye HTTP \(code)"
        }
    }
}
