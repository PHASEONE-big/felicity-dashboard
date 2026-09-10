import Foundation
import Network

struct ArchiveRTSPResponse: Sendable {
    let code: Int
    let cseq: Int
    let headers: [String: String]
    let body: String
}

enum ArchiveRTSPMessage: Sendable {
    case response(ArchiveRTSPResponse)
    case interleaved(channel: Int, data: Data)
}

final class ArchiveRTSPWire: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "felicity.archive.rtsp", qos: .userInitiated)
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<ArchiveRTSPMessage, Error>.Continuation?

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RTSPError.invalidURI }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
    }

    func start() async throws -> AsyncThrowingStream<ArchiveRTSPMessage, Error> {
        let stream = AsyncThrowingStream<ArchiveRTSPMessage, Error> { continuation in
            queue.async { self.continuation = continuation }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let gate = ArchiveOneShotGate()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim(), let self else { return }
                    ready.resume()
                    self.queue.async { self.receiveNext() }
                case let .failed(error):
                    guard gate.claim() else { return }
                    ready.resume(throwing: error)
                case .cancelled:
                    guard gate.claim() else { return }
                    ready.resume(throwing: CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return stream
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { sent.resume(throwing: error) }
                else { sent.resume() }
            })
        }
    }

    func cancel() {
        queue.async {
            self.continuation?.finish()
            self.continuation = nil
            self.connection.cancel()
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                if let data { self.buffer.append(data) }
                while let message = self.parseMessage() { self.continuation?.yield(message) }
                if let error { self.continuation?.finish(throwing: error); return }
                if complete { self.continuation?.finish(); return }
                self.receiveNext()
            }
        }
    }

    private func parseMessage() -> ArchiveRTSPMessage? {
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
        guard let headerText = String(data: buffer[..<headerEnd], encoding: .isoLatin1) else { return nil }
        let headers = Self.headers(headerText)
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= buffer.distance(from: buffer.startIndex, to: headerEnd) + contentLength else { return nil }
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

actor ArchiveRTSPClient {
    typealias InterleavedHandler = @Sendable (Int, Data) async -> Void

    private var wire: ArchiveRTSPWire?
    private var reader: Task<Void, Never>?
    private var sequence = 0
    private var pending: [Int: CheckedContinuation<ArchiveRTSPResponse, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var interleaved: InterleavedHandler?

    func connect(host: String, port: UInt16, interleaved: @escaping InterleavedHandler) async throws {
        close()
        let nextWire = try ArchiveRTSPWire(host: host, port: port)
        let stream = try await nextWire.start()
        wire = nextWire
        self.interleaved = interleaved
        reader = Task { [weak self] in
            do {
                for try await message in stream { await self?.accept(message) }
                await self?.failAll(RTSPError.disconnected)
            } catch {
                await self?.failAll(error)
            }
        }
    }

    func request(
        _ method: String,
        target: String,
        headers: [String] = [],
        challenge: String = "",
        username: String = "",
        password: String = "",
        userAgent: String = "Felicity-Archive/1",
        timeout: Duration = .seconds(4)
    ) async throws -> ArchiveRTSPResponse {
        guard let wire else { throw RTSPError.disconnected }
        sequence += 1
        let cseq = sequence
        var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: \(userAgent)"]
        if !challenge.isEmpty {
            lines.append("Authorization: \(RTSPDigest.authorization(challenge: challenge, method: method, uri: target, username: username, password: password))")
        }
        lines.append(contentsOf: headers)
        lines.append("")
        lines.append("")
        let data = Data(lines.joined(separator: "\r\n").utf8)
        return try await withCheckedThrowingContinuation { continuation in
            pending[cseq] = continuation
            timeouts[cseq] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.fail(cseq: cseq, error: RTSPError.response("\(method) timed out"))
            }
            Task {
                do { try await wire.send(data) }
                catch { self.fail(cseq: cseq, error: error) }
            }
        }
    }

    func close() {
        reader?.cancel()
        reader = nil
        wire?.cancel()
        wire = nil
        interleaved = nil
        failAll(CancellationError())
    }

    private func accept(_ message: ArchiveRTSPMessage) async {
        switch message {
        case let .response(response):
            timeouts.removeValue(forKey: response.cseq)?.cancel()
            pending.removeValue(forKey: response.cseq)?.resume(returning: response)
        case let .interleaved(channel, data):
            await interleaved?(channel, data)
        }
    }

    private func fail(cseq: Int, error: Error) {
        timeouts.removeValue(forKey: cseq)?.cancel()
        pending.removeValue(forKey: cseq)?.resume(throwing: error)
    }
    private func failAll(_ error: Error) {
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        let values = pending.values
        pending.removeAll()
        for continuation in values { continuation.resume(throwing: error) }
    }
}

private final class ArchiveOneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
}
