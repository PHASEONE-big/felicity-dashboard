import Darwin
import Foundation

actor FelicityAPI: DashboardProviding {
    private let session: URLSession
    private var resolvedIPv4: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func current(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot {
        try DashboardSnapshot.applyingCurrent(await data(baseURL: baseURL, path: "/api/device/current"), to: previous)
    }

    func summary(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot {
        try DashboardSnapshot.applyingSummary(await data(baseURL: baseURL, path: "/api/device/summary"), to: previous)
    }

    func status(baseURL: URL) async throws -> ServerStatus {
        let payload = try JSONSerialization.jsonObject(with: await data(baseURL: baseURL, path: "/api/status")) as? [String: Any]
        return ServerStatus(
            online: payload?["online"] as? Bool ?? true,
            version: payload?["app_version"] as? String ?? "—"
        )
    }

    func chart(baseURL: URL, metric: DashboardMetric) async throws -> DashboardChart {
        try DashboardChart.decode(await data(baseURL: baseURL, path: "/api/device/chart?metric=\(metric.rawValue)"))
    }

    private func data(baseURL: URL, path: String) async throws -> Data {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let originalURL: URL
        if let question = normalized.firstIndex(of: "?") {
            let route = String(normalized[..<question])
            var components = URLComponents(url: baseURL.appending(path: route), resolvingAgainstBaseURL: false)
            components?.percentEncodedQuery = String(normalized[normalized.index(after: question)...])
            guard let value = components?.url else { throw APIError.invalidServer }
            originalURL = value
        } else {
            originalURL = baseURL.appending(path: normalized)
        }
        let candidates = ipv4PreferredCandidates(for: originalURL)
        var lastError: Error?
        for candidate in candidates {
            do {
                return try await data(url: candidate.url, hostHeader: candidate.hostHeader)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError.invalidResponse(nil)
    }

    private func data(url: URL, hostHeader: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        if let hostHeader { request.setValue(hostHeader, forHTTPHeaderField: "Host") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.invalidResponse((response as? HTTPURLResponse)?.statusCode)
        }
        return data
    }

    private func ipv4PreferredCandidates(for url: URL) -> [(url: URL, hostHeader: String?)] {
        guard let host = url.host, host.lowercased().hasSuffix(".local"), let address = ipv4Address(for: host) else {
            return [(url, nil)]
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = address
        guard let ipv4URL = components?.url else { return [(url, nil)] }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        return [(ipv4URL, hostHeader), (url, nil)]
    }

    private func ipv4Address(for host: String) -> String? {
        if let cached = resolvedIPv4[host] { return cached }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let item = cursor {
            if item.pointee.ai_family == AF_INET, let socketAddress = item.pointee.ai_addr {
                var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let value = String(cString: buffer)
                    resolvedIPv4[host] = value
                    return value
                }
            }
            cursor = item.pointee.ai_next
        }
        return nil
    }
}

enum APIError: LocalizedError {
    case invalidServer
    case invalidResponse(Int?)

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Invalid Felicity server address"
        case let .invalidResponse(code): return code.map { "Felicity HTTP \($0)" } ?? "Invalid Felicity response"
        }
    }
}
