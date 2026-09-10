import Foundation

actor OnvifCameraDiscovery {
    private static let deviceNamespace = "http://www.onvif.org/ver10/device/wsdl"
    private static let mediaNamespace = "http://www.onvif.org/ver10/media/wsdl"
    private static let recordingNamespace = "http://www.onvif.org/ver10/recording/wsdl"

    func discover(configuration: RecorderConfiguration) async throws -> [CameraDescriptor] {
        let base = try Self.baseURL(configuration.host)
        let device = base.appending(path: "onvif/device_service")
        let soap = OnvifSOAPSession(username: configuration.username, password: configuration.password)
        let services = try await soap.post(
            device,
            action: "\(Self.deviceNamespace)/GetServices",
            body: Self.envelope(
                endpoint: device.absoluteString,
                action: "\(Self.deviceNamespace)/GetServices",
                namespaces: "xmlns:tds=\"\(Self.deviceNamespace)\"",
                body: "<tds:GetServices><tds:IncludeCapability>true</tds:IncludeCapability></tds:GetServices>"
            )
        )
        var mediaEndpoint = Self.serviceEndpoint(services, namespaceFragment: "/media/wsdl")
        let recordingEndpoint = Self.serviceEndpoint(services, namespaceFragment: "/recording/wsdl")
        if mediaEndpoint == nil {
            let capabilities = try await soap.post(
                device,
                action: "\(Self.deviceNamespace)/GetCapabilities",
                body: Self.envelope(
                    endpoint: device.absoluteString,
                    action: "\(Self.deviceNamespace)/GetCapabilities",
                    namespaces: "xmlns:tds=\"\(Self.deviceNamespace)\"",
                    body: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>"
                )
            )
            mediaEndpoint = Self.mediaCapability(capabilities)
        }
        guard let endpointText = mediaEndpoint, let endpoint = URL(string: endpointText) else {
            throw CameraDiscoveryError.noMediaService
        }

        let profilesXML = try await soap.post(
            endpoint,
            action: "\(Self.mediaNamespace)/GetProfiles",
            body: Self.envelope(
                endpoint: endpoint.absoluteString,
                action: "\(Self.mediaNamespace)/GetProfiles",
                namespaces: "xmlns:trt=\"\(Self.mediaNamespace)\"",
                body: "<trt:GetProfiles/>"
            )
        )
        let profiles = Self.parseProfiles(profilesXML)
        guard !profiles.isEmpty else { throw CameraDiscoveryError.noProfiles }

        let recordings: [RecordingInfo]
        if let recordingEndpoint, let recordingURL = URL(string: recordingEndpoint) {
            let action = "\(Self.recordingNamespace)/GetRecordings"
            let xml = try? await soap.post(
                recordingURL,
                action: action,
                body: Self.envelope(
                    endpoint: recordingURL.absoluteString,
                    action: action,
                    namespaces: "xmlns:trc=\"\(Self.recordingNamespace)\"",
                    body: "<trc:GetRecordings/>"
                )
            )
            recordings = xml.map(Self.parseRecordings) ?? []
        } else {
            recordings = []
        }

        var uris: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        return (profile.token, try await Self.streamURI(for: profile.token, endpoint: endpoint, soap: soap))
                    } catch {
                        return (profile.token, Self.recorderFallbackURI(host: base.host ?? configuration.host, token: profile.token))
                    }
                }
            }
            for await (token, uri) in group { uris[token] = uri }
        }
        return Self.buildCameras(profiles: profiles, uris: uris, recordings: recordings, host: base.host ?? configuration.host)
    }

    private static func streamURI(for token: String, endpoint: URL, soap: OnvifSOAPSession) async throws -> String {
        let action = "\(mediaNamespace)/GetStreamUri"
        let body = "<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>\(escape(token))</trt:ProfileToken></trt:GetStreamUri>"
        let response = try await soap.post(
            endpoint,
            action: action,
            body: envelope(
                endpoint: endpoint.absoluteString,
                action: action,
                namespaces: "xmlns:trt=\"\(mediaNamespace)\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"",
                body: body
            )
        )
        guard let uri = element(response, "Uri"), !uri.isEmpty else { throw CameraDiscoveryError.invalidResponse }
        return uri
    }

    private static func baseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed.contains("://") ? trimmed : "http://\(trimmed)"), url.host != nil else {
            throw CameraDiscoveryError.invalidHost
        }
        return url
    }

    private struct MediaProfile: Sendable {
        let token: String
        let name: String
        let sourceToken: String
        let width: Int
        let height: Int
        let rotation: Int
    }

    private struct RecordingInfo: Sendable {
        let token: String
        let name: String
        let sourceToken: String

        var isSubstream: Bool {
            let value = "\(token) \(name) \(sourceToken)".lowercased()
            return value.contains("-sub-r") || value.contains("sub") || value.hasSuffix("_s") || value.contains("secondary")
        }
    }

    private static func parseProfiles(_ xml: String) -> [MediaProfile] {
        matches(xml, #"<(?:[\w.-]+:)?Profiles\b([^>]*)>(.*?)</(?:[\w.-]+:)?Profiles>"#).compactMap { groups in
            guard groups.count >= 3, let token = attribute(groups[1], "token"), !token.isEmpty else { return nil }
            let block = groups[2]
            let sourceBlock = element(block, "VideoSourceConfiguration") ?? ""
            let encoder = element(block, "VideoEncoderConfiguration") ?? ""
            let resolution = element(encoder, "Resolution") ?? ""
            let rotation = intValue(element(element(block, "Rotate") ?? "", "Degree"))
            return MediaProfile(
                token: token,
                name: element(block, "Name") ?? token,
                sourceToken: element(sourceBlock, "SourceToken") ?? token.replacingOccurrences(of: #"(?i)(?:-main|-sub)$"#, with: "", options: .regularExpression),
                width: intValue(element(resolution, "Width")),
                height: intValue(element(resolution, "Height")),
                rotation: normalizeRotation(rotation)
            )
        }
    }

    private static func parseRecordings(_ xml: String) -> [RecordingInfo] {
        matches(xml, #"<(?:[\w.-]+:)?RecordingItem\b[^>]*>(.*?)</(?:[\w.-]+:)?RecordingItem>"#).compactMap { groups in
            guard groups.count > 1 else { return nil }
            let block = groups[1]
            guard let token = element(block, "RecordingToken"), !token.isEmpty else { return nil }
            let configuration = element(block, "Configuration") ?? block
            return RecordingInfo(
                token: token,
                name: element(configuration, "Name") ?? "",
                sourceToken: element(configuration, "SourceId") ?? ""
            )
        }
    }

    private static func buildCameras(profiles: [MediaProfile], uris: [String: String], recordings: [RecordingInfo], host: String) -> [CameraDescriptor] {
        var order: [String] = []
        var grouped: [String: [MediaProfile]] = [:]
        for profile in profiles {
            let source = profile.sourceToken.isEmpty ? profile.token : profile.sourceToken
            if grouped[source] == nil { order.append(source) }
            grouped[source, default: []].append(profile)
        }
        return order.compactMap { source in
            guard let variants = grouped[source], let main = variants.max(by: { pixels($0) < pixels($1) }) else { return nil }
            let sub = variants.filter { $0.token != main.token }.min(by: { pixels($0) < pixels($1) })
            let name = cleanName(main.name, fallback: source)
            let normalName = normalized(name)
            let corridor = source.hasPrefix("JasU1Wn1xB-") || source.hasPrefix("RufpaSMY9J-") || source.hasPrefix("NyNMfSr7K1-") || normalName.contains("vertical")
            return CameraDescriptor(
                id: source,
                name: name,
                host: host,
                sourceToken: source,
                mainProfile: main.token,
                subProfile: sub?.token ?? "",
                mainURI: uris[main.token] ?? "",
                subURI: sub.flatMap { uris[$0.token] } ?? "",
                mainRecording: recordingToken(in: recordings, source: source, name: name, substream: false),
                subRecording: recordingToken(in: recordings, source: source, name: name, substream: true),
                mainWidth: main.width,
                mainHeight: main.height,
                subWidth: sub?.width ?? 0,
                subHeight: sub?.height ?? 0,
                rotationDegrees: main.rotation,
                isDoorbell: normalName.contains("doorbell") || normalName.contains("doorchime") || normalName.contains("звонок") || normalName.hasPrefix("db"),
                isCorridor: corridor
            )
        }
    }

    private static func recordingToken(in recordings: [RecordingInfo], source: String, name: String, substream: Bool) -> String? {
        let wantedSource = normalized(source)
        let wantedName = normalized(name)
        var fallback: RecordingInfo?
        for recording in recordings {
            let haystack = normalized("\(recording.token) \(recording.sourceToken) \(recording.name)")
            guard haystack.contains(wantedSource) || (!wantedName.isEmpty && haystack.contains(wantedName)) else { continue }
            if recording.isSubstream == substream { return recording.token }
            if fallback == nil { fallback = recording }
        }
        return fallback?.token
    }

    private static func serviceEndpoint(_ xml: String, namespaceFragment: String) -> String? {
        for groups in matches(xml, #"<(?:[\w.-]+:)?Service\b[^>]*>(.*?)</(?:[\w.-]+:)?Service>"#) where groups.count > 1 {
            let block = groups[1]
            if element(block, "Namespace")?.contains(namespaceFragment) == true { return element(block, "XAddr") }
        }
        return nil
    }

    private static func mediaCapability(_ xml: String) -> String? {
        for groups in matches(xml, #"<(?:[\w.-]+:)?Media\b([^>]*)>"#) where groups.count > 1 {
            if let value = attribute(groups[1], "XAddr"), !value.isEmpty { return value }
        }
        return nil
    }

    private static func envelope(endpoint: String, action: String, namespaces: String, body: String) -> String {
        "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:wsa=\"http://www.w3.org/2005/08/addressing\" \(namespaces)><s:Header><wsa:Action s:mustUnderstand=\"1\">\(action)</wsa:Action><wsa:MessageID>urn:uuid:\(UUID().uuidString)</wsa:MessageID><wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo><wsa:To s:mustUnderstand=\"1\">\(endpoint)</wsa:To></s:Header><s:Body>\(body)</s:Body></s:Envelope>"
    }

    private static func matches(_ input: String, _ pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        return expression.matches(in: input, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let value = match.range(at: index)
                guard value.location != NSNotFound, let range = Range(value, in: input) else { return "" }
                return String(input[range])
            }
        }
    }

    private static func element(_ xml: String, _ localName: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: localName)
        guard let result = matches(xml, "<(?:[\\w.-]+:)?\(escapedName)(?:\\s[^>]*)?>(.*?)</(?:[\\w.-]+:)?\(escapedName)>").first, result.count > 1 else { return nil }
        return decode(result[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func attribute(_ input: String, _ name: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let result = matches(input, "\\b\(escapedName)\\s*=\\s*(['\"])(.*?)\\1").first, result.count > 2 else { return nil }
        return decode(result[2])
    }

    private static func recorderFallbackURI(host: String, token: String) -> String {
        let path = token.replacingOccurrences(of: #"(?i)-main$"#, with: "_m", options: .regularExpression).replacingOccurrences(of: #"(?i)-sub$"#, with: "_s", options: .regularExpression)
        return "rtsp://\(host):8554/\(path)"
    }

    private static func cleanName(_ name: String, fallback: String) -> String {
        let value = name.replacingOccurrences(of: #"(?i)(?:[_ -](?:main|sub|secondary))$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func pixels(_ profile: MediaProfile) -> Int64 { Int64(max(0, profile.width)) * Int64(max(0, profile.height)) }
    private static func intValue(_ value: String?) -> Int { Int(value ?? "") ?? 0 }
    private static func normalizeRotation(_ value: Int) -> Int { let result = ((value % 360) + 360) % 360; return [90, 180, 270].contains(result) ? result : 0 }
    private static func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    private static func decode(_ value: String) -> String { value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">") }
}

final class OnvifSOAPSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String
    private let password: String
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func post(_ url: URL, action: String, body: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CameraDiscoveryError.invalidResponse }
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else { throw CameraDiscoveryError.soap("HTTP \(http.statusCode)") }
        if xml.range(of: #"<(?:[\w.-]+:)?Fault\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw CameraDiscoveryError.soap("SOAP fault")
        }
        return xml
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodDefault {
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .forSession))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
