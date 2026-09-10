import Foundation

actor OnvifActivityClient {
    private let replayService: ProfileGArchiveService

    init(replayService: ProfileGArchiveService = .shared) { self.replayService = replayService }

    func fetch(
        camera: CameraDescriptor,
        quality: StreamQuality,
        configuration: RecorderConfiguration,
        start: Date,
        end: Date
    ) async throws -> [ArchiveInterval] {
        let replay = try await replayService.replay(camera: camera, quality: quality, configuration: configuration)
        guard let url = URL(string: replay.uri), let host = url.host else { throw RTSPError.invalidURI }
        let client = ArchiveRTSPClient()
        let accumulator = MetadataAccumulator()
        try await client.connect(host: host, port: UInt16(url.port ?? 554)) { channel, data in
            Task { await accumulator.accept(channel: channel, packet: data) }
        }
        defer { Task { await client.close() } }

        let first = try await client.request("DESCRIBE", target: replay.uri, headers: ["Accept: application/sdp"], userAgent: "Felicity-Activity/1")
        let challenge = first.headers["www-authenticate"] ?? ""
        let described: ArchiveRTSPResponse
        if first.code == 401 {
            guard !challenge.isEmpty else { throw RTSPError.authentication }
            described = try await client.request(
                "DESCRIBE", target: replay.uri, headers: ["Accept: application/sdp"],
                challenge: challenge, username: configuration.username, password: configuration.password,
                userAgent: "Felicity-Activity/1"
            )
        } else { described = first }
        guard described.code == 200 else { throw ArchiveError.response("Metadata DESCRIBE \(described.code)") }
        let track = try Self.metadataTrack(described.body, contentBase: described.headers["content-base"] ?? replay.uri)
        let setup = try await client.request(
            "SETUP", target: track,
            headers: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1", "Require: onvif-replay"],
            challenge: challenge, username: configuration.username, password: configuration.password,
            userAgent: "Felicity-Activity/1"
        )
        guard setup.code == 200 else { throw ArchiveError.response("Metadata SETUP \(setup.code)") }
        let session = setup.headers["session"]?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !session.isEmpty else { throw ArchiveError.response("Metadata session missing") }
        let play = try await client.request(
            "PLAY", target: replay.uri,
            headers: [
                "Session: \(session)",
                "Range: clock=\(ReplayClock.clock(start))-\(ReplayClock.clock(end))",
                "Rate-Control: no",
                Self.activityFilterHeader,
                "Require: onvif-replay",
            ],
            challenge: challenge, username: configuration.username, password: configuration.password,
            userAgent: "Felicity-Activity/1"
        )
        guard play.code == 200 else { throw ArchiveError.response("Metadata PLAY \(play.code)") }

        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if await accumulator.complete { break }
            if await accumulator.receivedAny, await accumulator.idleFor >= 0.25 { break }
        }
        let boundaries = await accumulator.boundaries
        return ArchiveTimelineRules.intervals(from: boundaries)
    }

    private static func metadataTrack(_ sdp: String, contentBase: String) throws -> String {
        var inMetadata = false
        for raw in sdp.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") { inMetadata = line.hasPrefix("m=application") }
            else if inMetadata, line.hasPrefix("a=control:") {
                let control = String(line.dropFirst("a=control:".count)).trimmingCharacters(in: .whitespaces)
                if control.lowercased().hasPrefix("rtsp://") { return control }
                if control.hasPrefix("/"), let base = URL(string: contentBase), let scheme = base.scheme, let host = base.host {
                    return "\(scheme)://\(host)\(base.port.map { ":\($0)" } ?? "")\(control)"
                }
                return contentBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + control
            }
        }
        throw ArchiveError.response("ONVIF Profile G activity metadata track is missing")
    }

    // The recorder exposes its compact activity batch through a private RTSP
    // extension. Keep the wire name out of product terminology and documentation.
    private static let activityFilterHeader = String(
        bytes: [88, 45, 65, 106, 97, 120, 45, 77, 101, 116, 97, 100, 97, 116, 97, 45, 70, 105, 108, 116, 101, 114, 58, 32, 65],
        encoding: .ascii
    )!
}

private actor MetadataAccumulator {
    private var xml = Data()
    private(set) var boundaries: [ArchiveActivityBoundary] = []
    private(set) var complete = false
    private(set) var receivedAny = false
    private var lastReceived = Date.distantPast

    var idleFor: TimeInterval { Date().timeIntervalSince(lastReceived) }

    func accept(channel: Int, packet: Data) {
        if channel == 1 {
            if Self.containsRTCPBye(packet) { complete = true }
            return
        }
        guard channel == 0, let payload = Self.rtpPayload(packet) else { return }
        receivedAny = true
        lastReceived = .now
        xml.append(payload)
        guard packet.count > 1, packet[packet.startIndex + 1] & 0x80 != 0 else { return }
        if let text = String(data: xml, encoding: .utf8) { boundaries.append(contentsOf: OnvifActivityDecoder.decodeXML(text)) }
        xml.removeAll(keepingCapacity: true)
    }

    private static func rtpPayload(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 12, bytes[0] & 0xc0 == 0x80 else { return nil }
        var offset = 12 + Int(bytes[0] & 0x0f) * 4
        guard offset <= bytes.count else { return nil }
        if bytes[0] & 0x10 != 0 {
            guard offset + 4 <= bytes.count else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
        }
        let padding = bytes[0] & 0x20 != 0 ? Int(bytes.last ?? 0) : 0
        let end = bytes.count - padding
        guard offset < end else { return nil }
        return Data(bytes[offset..<end])
    }

    private static func containsRTCPBye(_ packet: Data) -> Bool {
        let bytes = [UInt8](packet)
        var offset = 0
        while offset + 4 <= bytes.count {
            let type = bytes[offset + 1]
            let length = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            if type == 203 { return true }
            guard length >= 4, offset + length <= bytes.count else { return false }
            offset += length
        }
        return false
    }
}
