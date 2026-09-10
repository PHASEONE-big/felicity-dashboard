import CryptoKit
import Foundation
import Network

struct VideoStreamFormat: Sendable {
    let isHEVC: Bool
    let parameterSets: [Data]
    let width: Int
    let height: Int

    var codecName: String { isHEVC ? "H265" : "H264" }
}

struct LiveStreamStatistics: Sendable {
    let kbps: Double
    let fps: Double
}

actor LiveRTSPSession {
    typealias FormatHandler = @Sendable (VideoStreamFormat) -> Void
    typealias FrameHandler = @Sendable (VideoAccessUnit) -> Void
    typealias StatisticsHandler = @Sendable (LiveStreamStatistics) -> Void
    typealias StateHandler = @Sendable (MediaSessionState) -> Void

    private var task: Task<Void, Never>?
    private var transport: RTSPTCPTransport?

    func start(
        uri: String,
        username: String,
        password: String,
        fallbackSize: (width: Int, height: Int),
        onFormat: @escaping FormatHandler,
        onFrame: @escaping FrameHandler,
        onStatistics: @escaping StatisticsHandler,
        onState: @escaping StateHandler
    ) {
        stop()
        task = Task {
            do {
                onState(.connecting)
                try await run(
                    uri: uri,
                    username: username,
                    password: password,
                    fallbackSize: fallbackSize,
                    onFormat: onFormat,
                    onFrame: onFrame,
                    onStatistics: onStatistics,
                    onState: onState
                )
            } catch is CancellationError {
                onState(.idle)
            } catch {
                onState(.failed(message: error.localizedDescription))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        transport?.cancel()
        transport = nil
    }

    private func run(
        uri: String,
        username: String,
        password: String,
        fallbackSize: (width: Int, height: Int),
        onFormat: @escaping FormatHandler,
        onFrame: @escaping FrameHandler,
        onStatistics: @escaping StatisticsHandler,
        onState: @escaping StateHandler
    ) async throws {
        guard let url = URL(string: uri), let host = url.host else { throw RTSPError.invalidURI }
        let port = UInt16(url.port ?? 554)
        let connection = try RTSPTCPTransport(host: host, port: port)
        transport = connection
        try await connection.start()
        var sequence = 0
        var challenge = ""
        var session = ""

        func request(_ method: String, _ target: String, headers: [String] = [], authenticated: Bool) async throws -> RTSPResponse {
            sequence += 1
            var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(sequence)", "User-Agent: Felicity-iOS/0.1"]
            if authenticated, !challenge.isEmpty {
                lines.append("Authorization: \(RTSPDigest.authorization(challenge: challenge, method: method, uri: target, username: username, password: password))")
            }
            lines.append(contentsOf: headers)
            lines.append("")
            lines.append("")
            try await connection.send(Data(lines.joined(separator: "\r\n").utf8))
            while !Task.isCancelled {
                switch try await connection.nextMessage() {
                case let .response(response) where response.cseq == sequence:
                    return response
                case .response:
                    continue
                case .interleaved:
                    continue
                }
            }
            throw CancellationError()
        }

        let first = try await request("DESCRIBE", uri, headers: ["Accept: application/sdp"], authenticated: false)
        challenge = first.headers["www-authenticate"] ?? ""
        let described: RTSPResponse
        if first.code == 401 {
            guard !challenge.isEmpty else { throw RTSPError.authentication }
            described = try await request("DESCRIBE", uri, headers: ["Accept: application/sdp"], authenticated: true)
        } else {
            described = first
        }
        guard described.code == 200 else { throw RTSPError.response("DESCRIBE \(described.code)") }
        let description = try SDPDescription.parse(
            described.body,
            contentBase: described.headers["content-base"] ?? uri,
            fallbackSize: fallbackSize
        )
        onFormat(description.format)
        let depacketizer = RTPDepacketizer(isHEVC: description.format.isHEVC, output: onFrame)

        let setup = try await request(
            "SETUP",
            description.trackURI,
            headers: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"],
            authenticated: true
        )
        guard setup.code == 200 else { throw RTSPError.response("SETUP \(setup.code)") }
        session = setup.headers["session"]?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !session.isEmpty else { throw RTSPError.response("Missing RTSP session") }
        let played = try await request("PLAY", uri, headers: ["Session: \(session)"], authenticated: true)
        guard played.code == 200 else { throw RTSPError.response("PLAY \(played.code)") }
        onState(.playing(frameTime: .now))

        var bytes = 0
        var frames = 0
        var lastBytes = 0
        var lastFrames = 0
        var smoothedFPS: Double?
        var smoothedKbps: Double?
        var measuredAt = ContinuousClock.now
        var keepAliveAt = ContinuousClock.now
        while !Task.isCancelled {
            let message = try await connection.nextMessage()
            guard case let .interleaved(channel, packet) = message, channel == 0 else { continue }
            bytes += packet.count
            let marker = packet.count > 1 && packet[packet.startIndex + 1] & 0x80 != 0
            depacketizer.accept(packet)
            if marker { frames += 1 }
            let elapsed = measuredAt.duration(to: .now)
            if elapsed >= .seconds(1) {
                let seconds = max(0.001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
                let newFPS = Double(frames - lastFrames) / seconds
                let newKbps = Double(bytes - lastBytes) * 8 / seconds / 1000
                smoothedFPS = smoothedFPS.map { $0 * 0.9 + newFPS * 0.1 } ?? newFPS
                smoothedKbps = smoothedKbps.map { $0 * 0.8 + newKbps * 0.2 } ?? newKbps
                onStatistics(.init(kbps: smoothedKbps ?? 0, fps: smoothedFPS ?? 0))
                lastBytes = bytes
                lastFrames = frames
                measuredAt = .now
            }
            if keepAliveAt.duration(to: .now) >= .seconds(20) {
                sequence += 1
                var lines = [
                    "OPTIONS \(uri) RTSP/1.0",
                    "CSeq: \(sequence)",
                    "User-Agent: Felicity-iOS/0.2",
                    "Session: \(session)",
                ]
                if !challenge.isEmpty {
                    lines.append("Authorization: \(RTSPDigest.authorization(challenge: challenge, method: "OPTIONS", uri: uri, username: username, password: password))")
                }
                lines.append("")
                lines.append("")
                try await connection.send(Data(lines.joined(separator: "\r\n").utf8))
                keepAliveAt = .now
            }
        }
        throw CancellationError()
    }
}

enum RTSPError: LocalizedError {
    case invalidURI
    case authentication
    case disconnected
    case response(String)
    case malformedSDP

    var errorDescription: String? {
        switch self {
        case .invalidURI: return "Invalid RTSP URI"
        case .authentication: return "RTSP authentication failed"
        case .disconnected: return "RTSP connection closed"
        case let .response(value): return value
        case .malformedSDP: return "Recorder returned an invalid video SDP"
        }
    }
}

private enum RTSPMessage {
    case response(RTSPResponse)
    case interleaved(channel: Int, data: Data)
}

private struct RTSPResponse {
    let code: Int
    let cseq: Int
    let headers: [String: String]
    let body: String
}

private final class RTSPTCPTransport: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RTSPError.invalidURI }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OneShotGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case let .failed(error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "felicity.rtsp", qos: .userInitiated))
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func nextMessage() async throws -> RTSPMessage {
        while true {
            if let message = parseMessage() { return message }
            let next = try await receive()
            guard !next.isEmpty else { throw RTSPError.disconnected }
            buffer.append(next)
        }
    }

    func cancel() { connection.cancel() }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if complete, data == nil { continuation.resume(throwing: RTSPError.disconnected) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func parseMessage() -> RTSPMessage? {
        guard !buffer.isEmpty else { return nil }
        if buffer[buffer.startIndex] == 0x24 {
            guard buffer.count >= 4 else { return nil }
            let start = buffer.startIndex
            let channel = Int(buffer[buffer.index(start, offsetBy: 1)])
            let length = Int(buffer[buffer.index(start, offsetBy: 2)]) << 8 | Int(buffer[buffer.index(start, offsetBy: 3)])
            guard buffer.count >= 4 + length else { return nil }
            let payloadStart = buffer.index(start, offsetBy: 4)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            buffer.removeSubrange(start..<payloadEnd)
            return .interleaved(channel: channel, data: payload)
        }
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = buffer.range(of: delimiter) else { return nil }
        let headerEnd = headerRange.upperBound
        let headerData = buffer[..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { return nil }
        let headers = Self.headers(headerText)
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: buffer.startIndex, to: buffer.endIndex) >= buffer.distance(from: buffer.startIndex, to: headerEnd) + contentLength else { return nil }
        let bodyEnd = buffer.index(headerEnd, offsetBy: contentLength)
        let body = String(data: buffer[headerEnd..<bodyEnd], encoding: .utf8) ?? ""
        let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let code = Int(firstLine.split(separator: " ").dropFirst().first ?? "0") ?? 0
        let cseq = Int(headers["cseq"] ?? "0") ?? 0
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return .response(.init(code: code, cseq: cseq, headers: headers, body: body))
    }

    private static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum RTSPDigest {
    static func authorization(challenge: String, method: String, uri: String, username: String, password: String) -> String {
        if challenge.lowercased().hasPrefix("basic") {
            return "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        }
        let realm = parameter(challenge, "realm")
        let nonce = parameter(challenge, "nonce")
        let opaque = parameter(challenge, "opaque")
        let qopList = parameter(challenge, "qop")
        let qop = qopList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.lowercased() == "auth" }) ?? ""
        let cnonce = String(md5(UUID().uuidString).prefix(16))
        let nc = "00000001"
        let ha1 = md5("\(username):\(realm):\(password)")
        let ha2 = md5("\(method):\(uri)")
        let response = qop.isEmpty ? md5("\(ha1):\(nonce):\(ha2)") : md5("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        var value = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(response)\""
        if !opaque.isEmpty { value += ", opaque=\"\(opaque)\"" }
        if !qop.isEmpty { value += ", qop=\(qop), nc=\(nc), cnonce=\"\(cnonce)\"" }
        return value
    }

    private static func parameter(_ input: String, _ name: String) -> String {
        let pattern = "(?:^|[;, ])\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|([^;, \\r\\n]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return "" }
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            if let range = Range(match.range(at: index), in: input) { return String(input[range]) }
        }
        return ""
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SDPDescription {
    let trackURI: String
    let format: VideoStreamFormat

    static func parse(_ text: String, contentBase: String, fallbackSize: (width: Int, height: Int)) throws -> Self {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        var videoLines: [Substring] = []
        var inVideo = false
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("m=") {
                if inVideo { break }
                inVideo = line.hasPrefix("m=video")
            }
            if inVideo { videoLines.append(line) }
        }
        guard !videoLines.isEmpty else { throw RTSPError.malformedSDP }
        let video = videoLines.joined(separator: "\n")
        let upper = video.uppercased()
        let isHEVC = upper.contains("H265") || upper.contains("HEVC")
        guard let control = capture(video, #"(?im)^a=control:([^\r\n]+)"#) else { throw RTSPError.malformedSDP }
        let trackURI: String
        if control.lowercased().hasPrefix("rtsp://") { trackURI = control }
        else if control.hasPrefix("/"), let base = URL(string: contentBase), let scheme = base.scheme, let host = base.host {
            trackURI = "\(scheme)://\(host)\(base.port.map { ":\($0)" } ?? "")\(control)"
        } else {
            trackURI = contentBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + control
        }
        var sets: [Data] = []
        if isHEVC {
            for name in ["sprop-vps", "sprop-sps", "sprop-pps"] {
                if let value = parameter(video, name), let data = Data(base64Encoded: value) { sets.append(data) }
            }
        } else if let value = parameter(video, "sprop-parameter-sets") {
            sets = value.split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
        }
        var width = fallbackSize.width
        var height = fallbackSize.height
        if let size = capture(video, #"(?im)^a=framesize:\d+\s+(\d+)[-x](\d+)"#, group: 1),
           let second = capture(video, #"(?im)^a=framesize:\d+\s+(\d+)[-x](\d+)"#, group: 2) {
            width = Int(size) ?? width
            height = Int(second) ?? height
        }
        return .init(trackURI: trackURI, format: .init(isHEVC: isHEVC, parameterSets: sets, width: width, height: height))
    }

    private static func parameter(_ input: String, _ name: String) -> String? {
        capture(input, "(?i)\(NSRegularExpression.escapedPattern(for: name))=([^;\\r\\n]+)")
    }

    private static func capture(_ input: String, _ pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)), group < match.numberOfRanges, let range = Range(match.range(at: group), in: input) else { return nil }
        return String(input[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
