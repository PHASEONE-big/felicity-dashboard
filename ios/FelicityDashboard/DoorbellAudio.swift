import AVFoundation
import Combine
import Darwin
import Foundation
import UIKit

/// Microphone capture is created only by an explicit startTalking call. Both
/// directions begin muted/off and are stopped on interruption or backgrounding.
@MainActor
final class DoorbellAudio: ObservableObject {
    @Published private(set) var microphoneEnabled = false
    @Published private(set) var listeningEnabled = false
    @Published private(set) var status = "Audio off"
    @Published private(set) var connecting = false

    private var talkGeneration = 0
    private var listenGeneration = 0
    private var talkConnection: DoorbellAudioConnection?
    private var listenConnection: DoorbellAudioConnection?
    private var capture: DoorbellMicrophonePump?
    private var playback: DoorbellAudioPlayback?
    private var talkSafety: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var savedSession: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    init() {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.stop() }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        capture?.stop(); playback?.stop(); talkSafety?.cancel()
        let talk = talkConnection, listen = listenConnection
        Task { await talk?.close(); await listen?.close() }
    }

    func startTalking(camera: CameraDescriptor, configuration: RecorderConfiguration) async {
        guard !Task.isCancelled, camera.isDoorbell, !microphoneEnabled, !connecting else { return }
        talkGeneration += 1
        let generation = talkGeneration
        connecting = true
        status = "Requesting microphone…"
        let allowed: Bool
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: allowed = true
        case .denied: allowed = false
        case .undetermined:
            allowed = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: allowed = false
        }
        guard generation == talkGeneration, !Task.isCancelled else { connecting = false; return }
        guard allowed else { connecting = false; status = "Allow microphone access in iPad Settings"; return }
        let connection = DoorbellAudioConnection()
        talkConnection = connection
        do {
            status = "Connecting microphone…"
            let udp = try await connection.openTalk(uri: camera.streamURI(for: .lq), configuration: configuration)
            try Task.checkCancellation()
            guard generation == talkGeneration else { await connection.close(); return }
            try configureAudioSession(recording: true)
            let nextCapture = try DoorbellMicrophonePump(socket: udp) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.talkGeneration == generation else { return }
                    self.stopTalking(); self.status = "Microphone connection lost"
                }
            }
            capture = nextCapture
            try nextCapture.start()
            microphoneEnabled = true; connecting = false; status = "Microphone on"
            connection.startKeepAlive { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.talkGeneration == generation else { return }
                    self.stopTalking(); self.status = "Microphone connection lost"
                }
            }
            talkSafety = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.talkGeneration == generation else { return }
                self.stopTalking(); self.status = "Microphone stopped after 30 seconds"
            }
        } catch {
            guard generation == talkGeneration else { await connection.close(); return }
            stopTalking()
            status = error is CancellationError ? "Audio off" : "Microphone unavailable: \(error.localizedDescription)"
        }
    }

    func stopTalking() {
        talkGeneration += 1
        talkSafety?.cancel(); talkSafety = nil
        capture?.stop(); capture = nil
        let old = talkConnection; talkConnection = nil
        Task { await old?.close() }
        microphoneEnabled = false; connecting = false
        if listeningEnabled { try? configureAudioSession(recording: false); status = "Speaker on" }
        else { restoreAudioSession(); status = "Audio off" }
    }

    func setListening(_ enabled: Bool, camera: CameraDescriptor, configuration: RecorderConfiguration) async {
        guard enabled else { stopListening(); return }
        guard !Task.isCancelled, camera.isDoorbell, !listeningEnabled, listenConnection == nil else { return }
        listenGeneration += 1
        let generation = listenGeneration
        let connection = DoorbellAudioConnection()
        listenConnection = connection
        do {
            try configureAudioSession(recording: microphoneEnabled)
            let output = try DoorbellAudioPlayback()
            playback = output
            try await connection.openListen(uri: camera.streamURI(for: .lq), configuration: configuration) { packet in
                output.enqueue(packet)
            }
            try Task.checkCancellation()
            guard generation == listenGeneration else { await connection.close(); return }
            listeningEnabled = true; status = microphoneEnabled ? "Microphone and speaker on" : "Speaker on"
            connection.startKeepAlive { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.listenGeneration == generation else { return }
                    self.stopListening(); self.status = "Speaker connection lost"
                }
            }
        } catch {
            guard generation == listenGeneration else { await connection.close(); return }
            stopListening()
            status = error is CancellationError ? "Audio off" : "Speaker unavailable: \(error.localizedDescription)"
        }
    }

    func stop() {
        stopListening()
        stopTalking()
    }

    private func stopListening() {
        listenGeneration += 1
        playback?.stop(); playback = nil
        let old = listenConnection; listenConnection = nil
        Task { await old?.close() }
        listeningEnabled = false
        if microphoneEnabled { status = "Microphone on" }
        else if !connecting { restoreAudioSession(); status = "Audio off" }
    }

    private func configureAudioSession(recording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if savedSession == nil { savedSession = (session.category, session.mode, session.categoryOptions) }
        if recording {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.02)
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
    }

    private func restoreAudioSession() {
        guard let saved = savedSession else { return }
        savedSession = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(saved.0, mode: saved.1, options: saved.2)
    }
}

struct DoorbellAudioTrack: Equatable {
    let uri: String
    let payloadType: UInt8

    static func parse(_ sdp: String, base: String, backchannel: Bool) throws -> Self {
        let lines = sdp.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var sections: [[String]] = []
        for line in lines {
            if line.hasPrefix("m=") { sections.append([line]) }
            else if !sections.isEmpty { sections[sections.count - 1].append(line) }
        }
        for section in sections where section.first?.hasPrefix("m=audio") == true {
            let sendOnly = section.contains("a=sendonly")
            guard backchannel ? sendOnly : !sendOnly else { continue }
            let payloads = section[0].split(separator: " ").dropFirst(3).compactMap { UInt8($0) }
            let g722 = payloads.first { payload in
                payload == 9 || section.contains { $0.uppercased().hasPrefix("A=RTPMAP:\(payload) G722/8000") }
            }
            guard let payload = g722, let control = section.first(where: { $0.hasPrefix("a=control:") })?.dropFirst(10),
                  !control.isEmpty else { continue }
            return .init(uri: try resolve(String(control), base: base), payloadType: payload)
        }
        throw DoorbellAudioError.unsupportedTrack
    }

    private static func resolve(_ control: String, base: String) throws -> String {
        guard let baseURL = URL(string: base), baseURL.scheme == "rtsp", let host = baseURL.host else { throw RTSPError.invalidURI }
        if let absolute = URL(string: control), absolute.scheme != nil {
            guard absolute.scheme == "rtsp", absolute.host == host, (absolute.port ?? 554) == (baseURL.port ?? 554) else { throw RTSPError.invalidURI }
            return control
        }
        if control.hasPrefix("/") { return "rtsp://\(host)\(baseURL.port.map { ":\($0)" } ?? "")\(control)" }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + control
    }
}

enum DoorbellAudioError: LocalizedError {
    case unsupportedTrack, transport, microphone, socket
    var errorDescription: String? {
        switch self {
        case .unsupportedTrack: return "G.722 audio track unavailable"
        case .transport: return "Doorbell audio transport unavailable"
        case .microphone: return "Microphone format unavailable"
        case .socket: return "Audio network connection unavailable"
        }
    }
}

struct DoorbellRTPPacketizer {
    var sequence: UInt16 = .random(in: .min ... .max)
    var timestamp: UInt32 = .random(in: .min ... .max)
    var ssrc: UInt32 = .random(in: .min ... .max)
    var first = true
    mutating func packet(_ payload: Data, type: UInt8 = 9) -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x80; bytes[1] = (type & 0x7f) | (first ? 0x80 : 0)
        bytes[2] = UInt8(sequence >> 8); bytes[3] = UInt8(sequence & 255)
        for i in 0..<4 { bytes[4 + i] = UInt8((timestamp >> (24 - i * 8)) & 255); bytes[8 + i] = UInt8((ssrc >> (24 - i * 8)) & 255) }
        sequence &+= 1; timestamp &+= UInt32(payload.count); first = false
        var result = Data(bytes); result.append(payload); return result
    }
    static func payload(_ packet: Data, type: UInt8) -> Data? {
        let p = [UInt8](packet)
        guard p.count >= 12, p[0] & 0xc0 == 0x80, p[1] & 0x7f == type else { return nil }
        var offset = 12 + 4 * Int(p[0] & 15)
        guard offset <= p.count else { return nil }
        if p[0] & 0x10 != 0 {
            guard offset + 4 <= p.count else { return nil }
            offset += 4 + 4 * (Int(p[offset + 2]) << 8 | Int(p[offset + 3]))
        }
        var end = p.count
        if p[0] & 0x20 != 0 {
            let padding = Int(p[p.count - 1]); guard padding > 0, padding <= end - offset else { return nil }; end -= padding
        }
        guard offset < end else { return nil }
        return Data(p[offset..<end])
    }
}

private final class DoorbellAudioConnection: @unchecked Sendable {
    private let client = ArchiveRTSPClient()
    private let lock = NSLock()
    private var stopped = false
    private var watchdog: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var udp: DoorbellUDPSocket?
    private var session = "", base = "", challenge = ""
    private var configuration = RecorderConfiguration(host: "", username: "", password: "")

    func openTalk(uri: String, configuration: RecorderConfiguration) async throws -> DoorbellUDPSocket {
        let track = try await describe(uri: uri, configuration: configuration, backchannel: true, packet: { _ in })
        let socket = try DoorbellUDPSocket()
        socket.payloadType = track.payloadType
        udp = socket
        let setup = try await request("SETUP", target: track.uri, headers: ["Transport: RTP/AVP;unicast;client_port=\(socket.localPort)-\(Int(socket.localPort) + 1)", "Require: www.onvif.org/ver20/backchannel"])
        guard setup.code == 200, let portText = capture(setup.headers["transport"] ?? "", #"(?i)server_port=(\d+)"#),
              let port = UInt16(portText), let host = URL(string: base)?.host else { throw DoorbellAudioError.transport }
        try socket.connect(host: host, port: port)
        session = setup.headers["session"]?.components(separatedBy: ";").first ?? ""
        guard !session.isEmpty else { throw DoorbellAudioError.transport }
        let played = try await request("PLAY", target: base, headers: ["Session: \(session)", "Range: npt=0.000-", "Require: www.onvif.org/ver20/backchannel"])
        guard played.code == 200 else { throw DoorbellAudioError.transport }
        watchdog?.cancel(); watchdog = nil
        return socket
    }

    func openListen(uri: String, configuration: RecorderConfiguration, packet: @escaping @Sendable (Data) -> Void) async throws {
        let gate = DoorbellAudioPayloadGate(packet: packet)
        let track = try await describe(uri: uri, configuration: configuration, backchannel: false, packet: { gate.accept($0) })
        gate.payloadType = track.payloadType
        let setup = try await request("SETUP", target: track.uri, headers: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])
        guard setup.code == 200 else { throw DoorbellAudioError.transport }
        session = setup.headers["session"]?.components(separatedBy: ";").first ?? ""
        guard !session.isEmpty else { throw DoorbellAudioError.transport }
        let played = try await request("PLAY", target: base, headers: ["Session: \(session)", "Range: npt=0.000-"])
        guard played.code == 200 else { throw DoorbellAudioError.transport }
        watchdog?.cancel(); watchdog = nil
    }

    private func describe(uri: String, configuration: RecorderConfiguration, backchannel: Bool,
                          packet: @escaping @Sendable (Data) -> Void) async throws -> DoorbellAudioTrack {
        guard var parts = URLComponents(string: uri), parts.scheme == "rtsp", let host = parts.host,
              let port = UInt16(exactly: parts.port ?? 554) else { throw RTSPError.invalidURI }
        parts.user = nil; parts.password = nil
        guard let normalized = parts.string else { throw RTSPError.invalidURI }
        base = normalized; self.configuration = configuration
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            await self?.close()
        }
        try await client.connect(host: host, port: port) { channel, bytes in if channel == 0 { packet(bytes) } }
        let headers = ["Accept: application/sdp"] + (backchannel ? ["Require: www.onvif.org/ver20/backchannel"] : [])
        let first = try await request("DESCRIBE", target: base, headers: headers)
        challenge = first.headers["www-authenticate"] ?? ""
        let described = first.code == 401 ? try await request("DESCRIBE", target: base, headers: headers) : first
        guard described.code == 200 else { throw RTSPError.authentication }
        let contentBase = described.headers["content-base"] ?? base
        // Control targets may vary by path, but never send credentials to a
        // different host advertised in an unexpected SDP response.
        guard URL(string: contentBase)?.host == host else { throw RTSPError.invalidURI }
        return try DoorbellAudioTrack.parse(described.body, base: contentBase, backchannel: backchannel)
    }

    func startKeepAlive(onError: @escaping @Sendable () -> Void) {
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, !self.isStopped else { return }
                do {
                    let response = try await self.request("GET_PARAMETER", target: self.base, headers: ["Session: \(self.session)"])
                    guard response.code == 200 else { throw DoorbellAudioError.transport }
                } catch {
                    if !self.isStopped { onError() }
                    await self.close(); return
                }
            }
        }
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func stopSocket() -> DoorbellUDPSocket? {
        lock.lock(); defer { lock.unlock() }
        stopped = true; let socket = udp; udp = nil; return socket
    }
    func close() async {
        stopSocket()?.close()
        watchdog?.cancel(); watchdog = nil; keepAlive?.cancel(); keepAlive = nil
        await client.close()
    }
    private func request(_ method: String, target: String, headers: [String]) async throws -> ArchiveRTSPResponse {
        guard !isStopped else { throw CancellationError() }
        return try await client.request(method, target: target, headers: headers, challenge: challenge,
                                        username: configuration.username, password: configuration.password,
                                        userAgent: "Felicity-iOS-Doorbell/1", timeout: .seconds(4))
    }
    private func capture(_ input: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let result = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(result.range(at: 1), in: input) else { return nil }; return String(input[range])
    }
}

private final class DoorbellAudioPayloadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var type: UInt8 = 9
    var payloadType: UInt8 { get { lock.lock(); defer { lock.unlock() }; return type } set { lock.lock(); type = newValue; lock.unlock() } }
    private let packet: @Sendable (Data) -> Void
    init(packet: @escaping @Sendable (Data) -> Void) { self.packet = packet }
    func accept(_ data: Data) { if let payload = DoorbellRTPPacketizer.payload(data, type: payloadType) { packet(payload) } }
}

private final class DoorbellUDPSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    let localPort: UInt16
    var payloadType: UInt8 = 9
    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw DoorbellAudioError.socket }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(descriptor); throw DoorbellAudioError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard found == 0, address.sin_port.bigEndian < UInt16.max else { Darwin.close(descriptor); throw DoorbellAudioError.socket }
        fd = descriptor; localPort = UInt16(bigEndian: address.sin_port)
    }
    deinit { close() }
    func connect(host: String, port: UInt16) throws {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else { throw DoorbellAudioError.socket }
        defer { freeaddrinfo(result) }
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, Darwin.connect(fd, result.pointee.ai_addr, result.pointee.ai_addrlen) == 0 else { throw DoorbellAudioError.socket }
    }
    func send(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { throw CancellationError() }
        let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count else { throw DoorbellAudioError.socket }
    }
    func close() { lock.lock(); let old = fd; fd = -1; lock.unlock(); if old >= 0 { Darwin.close(old) } }
}

private final class DoorbellMicrophonePump: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "felicity.doorbell.mic", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true, tapped = false
    private let socket: DoorbellUDPSocket
    private let onError: @Sendable () -> Void
    private let encoder = DoorbellG722Encoder()
    private var packetizer = DoorbellRTPPacketizer()
    private var pcm = [Int16](repeating: 0, count: 320), filled = 0
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(socket: DoorbellUDPSocket, onError: @escaping @Sendable () -> Void) throws { self.socket = socket; self.onError = onError }
    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = AVAudioConverter(from: format, to: target) else { throw DoorbellAudioError.microphone }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, self.isActive, let copied = self.copy(buffer) else { return }
            self.queue.async { self.convert(copied) }
        }
        tapped = true
        engine.prepare(); try engine.start()
    }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func stop() {
        lock.lock(); active = false; lock.unlock()
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        socket.close()
    }
    private func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        output.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList), dst = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let from = src[i].mData, let to = dst[i].mData else { return nil }
            memcpy(to, from, Int(src[i].mDataByteSize)); dst[i].mDataByteSize = src[i].mDataByteSize
        }
        return output
    }
    private func convert(_ input: AVAudioPCMBuffer) {
        guard isActive, let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var provided = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true; status.pointee = .haveData; return input
        }
        guard error == nil, let samples = output.floatChannelData?[0] else { if isActive { onError() }; return }
        for i in 0..<Int(output.frameLength) {
            guard isActive else { return }
            let sample = samples[i].isFinite ? samples[i] : 0
            pcm[filled] = Int16(min(32767, max(-32768, Int((min(1, max(-1, sample)) * 32767).rounded())))); filled += 1
            if filled == 320 {
                do { try socket.send(packetizer.packet(encoder.encode(pcm), type: socket.payloadType)) }
                catch { if isActive { onError() }; return }
                filled = 0
            }
        }
    }
}

private final class DoorbellAudioPlayback: @unchecked Sendable {
    private let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "felicity.doorbell.speaker", qos: .userInitiated)
    private let lock = NSLock()
    private let decoder = DoorbellG722Decoder()
    private var active = true, pendingBuffers = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    init() throws {
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare(); try engine.start(); player.play()
    }
    func stop() { lock.lock(); active = false; lock.unlock(); player.stop(); engine.stop() }
    func enqueue(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let pcm = self.decoder.decode(payload)
            self.lock.lock()
            guard self.active, self.pendingBuffers < 12 else { self.lock.unlock(); return }
            self.pendingBuffers += 1; self.lock.unlock()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(pcm.count)), let target = buffer.floatChannelData?[0] else {
                self.finishedBuffer(); return
            }
            buffer.frameLength = AVAudioFrameCount(pcm.count)
            for (i, sample) in pcm.enumerated() { target[i] = Float(sample) / 32768 }
            self.player.scheduleBuffer(buffer) { [weak self] in self?.finishedBuffer() }
        }
    }
    private func finishedBuffer() { lock.lock(); pendingBuffers = max(0, pendingBuffers - 1); lock.unlock() }
}
