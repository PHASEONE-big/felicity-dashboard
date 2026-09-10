import Foundation

struct ProfileGReplayDescriptor: Sendable {
    let uri: String
    let recordingToken: String
}

actor ProfileGArchiveService {
    static let shared = ProfileGArchiveService()

    private static let deviceNamespace = "http://www.onvif.org/ver10/device/wsdl"
    private static let recordingNamespace = "http://www.onvif.org/ver10/recording/wsdl"
    private static let replayNamespace = "http://www.onvif.org/ver10/replay/wsdl"
    private var replayCache: [String: ProfileGReplayDescriptor] = [:]

    func replay(camera: CameraDescriptor, quality: StreamQuality, configuration: RecorderConfiguration) async throws -> ProfileGReplayDescriptor {
        let cacheKey = "\(configuration.host)|\(camera.id)|\(quality.rawValue)"
        if let cached = replayCache[cacheKey] { return cached }
        let services = try await loadServices(configuration)
        let token: String
        if let direct = camera.recordingToken(for: quality) {
            token = direct
        } else {
            let recordings = try await loadRecordings(endpoint: services.recording, configuration: configuration)
            guard let matched = Self.matchRecording(recordings, camera: camera, quality: quality) else { throw ArchiveError.noRecording }
            token = matched.token
        }
        let soap = OnvifSOAPSession(username: configuration.username, password: configuration.password)
        let action = "\(Self.replayNamespace)/GetReplayUri"
        let body = "<trp:GetReplayUri><trp:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trp:StreamSetup><trp:RecordingToken>\(Self.escape(token))</trp:RecordingToken></trp:GetReplayUri>"
        let xml = try await soap.post(
            services.replay,
            action: action,
            body: Self.envelope(
                endpoint: services.replay.absoluteString,
                action: action,
                namespaces: "xmlns:trp=\"\(Self.replayNamespace)\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"",
                body: body
            )
        )
        guard let uri = Self.element(xml, "Uri"), !uri.isEmpty else { throw ArchiveError.noReplayURI }
        let value = ProfileGReplayDescriptor(uri: uri, recordingToken: token)
        replayCache[cacheKey] = value
        return value
    }

    private struct Services {
        let recording: URL
        let replay: URL
    }

    private struct Recording {
        let token: String
        let name: String
        let source: String
        var isSubstream: Bool {
            let value = "\(token) \(name) \(source)".lowercased()
            return value.contains("-sub-r") || value.contains("sub") || value.hasSuffix("_s") || value.contains("secondary")
        }
    }

    private func loadServices(_ configuration: RecorderConfiguration) async throws -> Services {
        let base = try Self.baseURL(configuration.host)
        let device = base.appending(path: "onvif/device_service")
        let soap = OnvifSOAPSession(username: configuration.username, password: configuration.password)
        let action = "\(Self.deviceNamespace)/GetServices"
        let xml = try await soap.post(
            device,
            action: action,
            body: Self.envelope(
                endpoint: device.absoluteString,
                action: action,
                namespaces: "xmlns:tds=\"\(Self.deviceNamespace)\"",
                body: "<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>"
            )
        )
        guard let recording = Self.serviceEndpoint(xml, fragment: "/recording/wsdl").flatMap(URL.init(string:)),
              let replay = Self.serviceEndpoint(xml, fragment: "/replay/wsdl").flatMap(URL.init(string:)) else {
            throw ArchiveError.response("Recorder did not expose Profile G")
        }
        return .init(recording: recording, replay: replay)
    }

    private func loadRecordings(endpoint: URL, configuration: RecorderConfiguration) async throws -> [Recording] {
        let soap = OnvifSOAPSession(username: configuration.username, password: configuration.password)
        let action = "\(Self.recordingNamespace)/GetRecordings"
        let xml = try await soap.post(
            endpoint,
            action: action,
            body: Self.envelope(
                endpoint: endpoint.absoluteString,
                action: action,
                namespaces: "xmlns:trc=\"\(Self.recordingNamespace)\"",
                body: "<trc:GetRecordings/>"
            )
        )
        return Self.matches(xml, #"<(?:[\w.-]+:)?RecordingItem\b[^>]*>(.*?)</(?:[\w.-]+:)?RecordingItem>"#).compactMap { groups in
            guard groups.count > 1 else { return nil }
            let block = groups[1]
            guard let token = Self.element(block, "RecordingToken"), !token.isEmpty else { return nil }
            let configuration = Self.element(block, "Configuration") ?? block
            return Recording(token: token, name: Self.element(configuration, "Name") ?? "", source: Self.element(configuration, "SourceId") ?? "")
        }
    }

    private static func matchRecording(_ recordings: [Recording], camera: CameraDescriptor, quality: StreamQuality) -> Recording? {
        let wanted = [normalized(camera.id), normalized(camera.sourceToken), normalized(camera.name)].filter { !$0.isEmpty }
        var fallback: Recording?
        for recording in recordings {
            let haystack = normalized("\(recording.token) \(recording.name) \(recording.source)")
            guard wanted.contains(where: haystack.contains) else { continue }
            if recording.isSubstream == (quality == .lq) { return recording }
            if fallback == nil { fallback = recording }
        }
        return fallback
    }

    private static func baseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"), url.host != nil else { throw CameraDiscoveryError.invalidHost }
        return url
    }

    private static func serviceEndpoint(_ xml: String, fragment: String) -> String? {
        for groups in matches(xml, #"<(?:[\w.-]+:)?Service\b[^>]*>(.*?)</(?:[\w.-]+:)?Service>"#) where groups.count > 1 {
            let block = groups[1]
            if element(block, "Namespace")?.contains(fragment) == true { return element(block, "XAddr") }
        }
        return nil
    }

    private static func envelope(endpoint: String, action: String, namespaces: String, body: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:wsa=\"http://www.w3.org/2005/08/addressing\" \(namespaces)><s:Header><wsa:Action s:mustUnderstand=\"1\">\(action)</wsa:Action><wsa:MessageID>urn:uuid:\(UUID().uuidString)</wsa:MessageID><wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo><wsa:To s:mustUnderstand=\"1\">\(endpoint)</wsa:To></s:Header><s:Body>\(body)</s:Body></s:Envelope>"
    }

    private static func matches(_ input: String, _ pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return expression.matches(in: input, range: NSRange(input.startIndex..., in: input)).map { match in
            (0..<match.numberOfRanges).map { index in
                guard match.range(at: index).location != NSNotFound, let range = Range(match.range(at: index), in: input) else { return "" }
                return String(input[range])
            }
        }
    }

    private static func element(_ xml: String, _ name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let groups = matches(xml, "<(?:[\\w.-]+:)?\(escaped)(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?\(escaped)>").first, groups.count > 1 else { return nil }
        return groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func normalized(_ value: String) -> String { value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined() }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
}
