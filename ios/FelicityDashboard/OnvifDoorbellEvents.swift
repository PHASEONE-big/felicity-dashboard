import Foundation

struct DoorbellNotification: Equatable, Sendable {
    let topic: String
    let operation: String
    let active: Bool
    let valueKnown: Bool
    let sourceToken: String

    var isRing: Bool { topic.lowercased().contains("ringdetector") }

    static func parse(_ xml: String) throws -> [DoorbellNotification] {
        try notifications(in: DoorbellXML.parse(Data(xml.utf8)))
    }

    fileprivate static func notifications(in document: DoorbellXMLNode) -> [DoorbellNotification] {
        document.descendants("NotificationMessage").compactMap { notification in
            guard let topic = notification.descendants("Topic").first?.trimmedText, !topic.isEmpty else { return nil }
            let messages = notification.descendants("Message")
            guard let message = messages.first(where: { $0.namespace == "http://www.onvif.org/ver10/schema" }) ?? messages.last else { return nil }
            var token = ""
            for item in message.descendants("Source").flatMap({ $0.descendants("SimpleItem") }) {
                let name = (item.attribute("Name") ?? "").lowercased()
                if name.contains("videosourcetoken") || name == "sourcetoken" {
                    token = (item.attribute("Value") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            var active = false
            var known = false
            for item in message.descendants("Data").flatMap({ $0.descendants("SimpleItem") }) {
                let name = (item.attribute("Name") ?? "").lowercased()
                guard ["state", "ring", "button", "detect", "active"].contains(where: name.contains),
                      let raw = item.attribute("Value") else { continue }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "active", "on", "pressed", "ringing": active = true; known = true
                case "false", "0", "inactive", "off", "released", "idle": known = true
                default: break
                }
            }
            return .init(topic: topic, operation: message.attribute("PropertyOperation") ?? "",
                         active: active, valueKnown: known, sourceToken: token)
        }
    }
}

/// Android's rising-edge/lost-release rule, independently latched for each source.
/// The presentation controller applies its separate five-second UI debounce.
struct DoorbellRingFilter: Sendable {
    private struct State: Sendable {
        var active: Bool
        var acceptedAt: TimeInterval?
    }
    private var sources: [String: State] = [:]

    mutating func accept(_ notification: DoorbellNotification, at now: TimeInterval) -> Bool {
        guard notification.isRing, notification.valueKnown, now.isFinite else { return false }
        let key = notification.sourceToken
        let old = sources[key]
        let operation = notification.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if operation == "initialized" {
            // An active initial snapshot is not a fresh press. Start its stale
            // latch here rather than treating a zero timestamp as already stale.
            sources[key] = State(active: notification.active,
                                 acceptedAt: old?.acceptedAt ?? (notification.active ? now : nil))
            return false
        }
        guard operation.isEmpty || operation == "changed" else { return false }
        guard notification.active else {
            sources[key] = State(active: false, acceptedAt: old?.acceptedAt)
            return false
        }
        let rising = old == nil || old?.active == false || old?.acceptedAt.map { now - $0 >= 8 } == true
        sources[key] = State(active: true, acceptedAt: rising ? max(now, old?.acceptedAt ?? now) : old?.acceptedAt)
        return rising
    }
}

/// Foreground-only PullPoint listener. Cancelling the caller cancels its HTTP poll.
actor OnvifDoorbellEvents {
    private var generation = 0
    private static let createAction = "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest"
    private static let pullAction = "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest"
    private static let renewAction = "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/RenewRequest"
    private static let unsubscribeAction = "http://docs.oasis-open.org/wsn/bw-2/SubscriptionManager/UnsubscribeRequest"

    func run(
        configuration: RecorderConfiguration,
        onStatus: @escaping @MainActor (String) -> Void,
        onRing: @escaping @MainActor (String) -> Void
    ) async {
        generation += 1
        let currentGeneration = generation
        guard let base = Self.baseURL(configuration.host) else {
            await onStatus("Set the ONVIF recorder address to listen for the doorbell.")
            return
        }
        let service = base.appendingPathComponent("onvif/event_service")
        let transport = DoorbellSOAPTransport(configuration: configuration, origin: base)
        var filter = DoorbellRingFilter()
        await withTaskCancellationHandler {
            defer { transport.cancel() }
            while !Task.isCancelled && generation == currentGeneration {
                var subscription: DoorbellSubscription?
                do {
                    await onStatus("Connecting to doorbell…")
                    let created = try await transport.post(service, action: Self.createAction,
                        body: Self.envelope(service, action: Self.createAction,
                            body: "<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT10M</tev:InitialTerminationTime></tev:CreatePullPointSubscription>"))
                    subscription = try Self.subscription(created, origin: base)
                    guard let active = subscription else { throw DoorbellEventError.invalidResponse }
                    var renewAt = ProcessInfo.processInfo.systemUptime + Self.leaseSeconds(created) * 0.6
                    try Task.checkCancellation()
                    guard generation == currentGeneration else { break }
                    await onStatus("Listening for doorbell")
                    while !Task.isCancelled && generation == currentGeneration {
                        if ProcessInfo.processInfo.systemUptime >= renewAt {
                            do {
                                let renewed = try await transport.post(active.url, action: Self.renewAction,
                                    body: Self.envelope(active.url, action: Self.renewAction, headers: active.headers,
                                        body: "<wsnt:Renew><wsnt:TerminationTime>PT10M</wsnt:TerminationTime></wsnt:Renew>"))
                                renewAt = ProcessInfo.processInfo.systemUptime + Self.leaseSeconds(renewed) * 0.6
                            } catch {
                                try Task.checkCancellation()
                                // Some recorders only support recreating PullPoints.
                                break
                            }
                        }
                        let began = ProcessInfo.processInfo.systemUptime
                        let document = try await transport.post(active.url, action: Self.pullAction,
                            body: Self.envelope(active.url, action: Self.pullAction, headers: active.headers,
                                body: "<tev:PullMessages><tev:Timeout>PT20S</tev:Timeout><tev:MessageLimit>20</tev:MessageLimit></tev:PullMessages>"))
                        try Task.checkCancellation()
                        guard generation == currentGeneration else { break }
                        let notifications = DoorbellNotification.notifications(in: document)
                        for notification in notifications {
                            try Task.checkCancellation()
                            if filter.accept(notification, at: ProcessInfo.processInfo.systemUptime) {
                                await onRing(notification.sourceToken)
                            }
                        }
                        if notifications.isEmpty && ProcessInfo.processInfo.systemUptime - began < 1 {
                            try await Task.sleep(for: .seconds(1))
                        }
                    }
                } catch {
                    if !Task.isCancelled && generation == currentGeneration {
                        await onStatus((error as? DoorbellEventError)?.localizedDescription ?? "Doorbell connection interrupted; retrying…")
                    }
                    if let subscription { Self.unsubscribe(subscription, configuration: configuration, origin: base) }
                    if Task.isCancelled || generation != currentGeneration { break }
                    do { try await Task.sleep(for: .seconds(5)) } catch { break }
                    continue
                }
                if let subscription { Self.unsubscribe(subscription, configuration: configuration, origin: base) }
            }
        } onCancel: {
            transport.cancel()
        }
    }

    private static func baseURL(_ input: String) -> URL? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !input.isEmpty, let url = URL(string: input.contains("://") ? input : "http://\(input)"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func subscription(_ document: DoorbellXMLNode, origin: URL) throws -> DoorbellSubscription {
        guard let reference = document.descendants("SubscriptionReference").first,
              let address = reference.descendants("Address").first?.trimmedText,
              let url = URL(string: address, relativeTo: origin)?.absoluteURL,
              DoorbellSOAPTransport.sameOrigin(url, origin) else { throw DoorbellEventError.invalidResponse }
        let parameters = reference.descendants("ReferenceParameters").first?.children ?? []
        return DoorbellSubscription(url: url, headers: parameters.map { $0.serializedReference() }.joined())
    }

    private static func leaseSeconds(_ document: DoorbellXMLNode) -> TimeInterval {
        guard let endText = document.descendants("TerminationTime").first?.trimmedText else { return 60 }
        if let end = date(endText) {
            let current = document.descendants("CurrentTime").first.flatMap { date($0.trimmedText) } ?? Date()
            return min(3600, max(5, end.timeIntervalSince(current)))
        }
        // A relative expiry is allowed by WS-Notification; typical leases are PT60S/PT10M.
        if endText.hasPrefix("PT") {
            var number = ""
            var seconds = 0.0
            for character in endText.dropFirst(2) {
                if character.isNumber || character == "." { number.append(character); continue }
                guard let value = Double(number), value.isFinite else { return 60 }
                switch character { case "H": seconds += value * 3600; case "M": seconds += value * 60; case "S": seconds += value; default: return 60 }
                number = ""
            }
            if seconds > 0, number.isEmpty { return min(3600, max(5, seconds)) }
        }
        return 60
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func envelope(_ endpoint: URL, action: String, headers: String = "", body: String) -> String {
        """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:wsa="http://www.w3.org/2005/08/addressing" xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"><s:Header><wsa:Action s:mustUnderstand="1">\(action)</wsa:Action><wsa:MessageID>urn:uuid:\(UUID().uuidString)</wsa:MessageID><wsa:ReplyTo><wsa:Address>http://www.w3.org/2005/08/addressing/anonymous</wsa:Address></wsa:ReplyTo><wsa:To s:mustUnderstand="1">\(DoorbellXML.escape(endpoint.absoluteString))</wsa:To>\(headers)</s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    private static func unsubscribe(_ subscription: DoorbellSubscription, configuration: RecorderConfiguration, origin: URL) {
        // The parent's cancelled task cannot send this. A separate, bounded
        // request is best effort; the server lease also expires if iOS suspends us.
        Task.detached(priority: .utility) {
            let cleanup = DoorbellSOAPTransport(configuration: configuration, origin: origin)
            defer { cleanup.cancel() }
            _ = try? await cleanup.post(subscription.url, action: unsubscribeAction,
                body: envelope(subscription.url, action: unsubscribeAction, headers: subscription.headers, body: "<wsnt:Unsubscribe/>"), timeout: 3)
        }
    }
}

private struct DoorbellSubscription: Sendable {
    let url: URL
    let headers: String
}

private enum DoorbellEventError: LocalizedError {
    case invalidResponse, soapFault, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Doorbell recorder returned an invalid response; retrying…"
        case .soapFault: return "Doorbell subscription expired or was rejected; reconnecting…"
        case .http(let status): return "Doorbell recorder returned HTTP \(status); retrying…"
        }
    }
}

private final class DoorbellSOAPTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: RecorderConfiguration
    private let origin: URL
    private var session: URLSession!

    init(configuration: RecorderConfiguration, origin: URL) {
        self.configuration = configuration
        self.origin = origin
        super.init()
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 35
        session = URLSession(configuration: settings, delegate: self, delegateQueue: nil)
    }

    func cancel() { session.invalidateAndCancel() }

    func post(_ url: URL, action: String, body: String, timeout: TimeInterval = 30) async throws -> DoorbellXMLNode {
        try Task.checkCancellation()
        guard Self.sameOrigin(url, origin) else { throw DoorbellEventError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        // This recorder's empty Digest 401 has no Content-Length/chunk framing.
        // Closing supplies EOF so URLSession can finish the challenge promptly.
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw DoorbellEventError.invalidResponse }
        guard http.statusCode == 200 else { throw DoorbellEventError.http(http.statusCode) }
        let document = try DoorbellXML.parse(data)
        guard document.descendants("Fault").isEmpty else { throw DoorbellEventError.soapFault }
        return document
    }

    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased() && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? (url.scheme == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme == "https" ? 443 : 80))
            && url.user == nil && url.password == nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(), challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        if method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodDefault {
            completionHandler(.useCredential, URLCredential(user: configuration.username, password: configuration.password, persistence: .forSession))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.sameOrigin($0, origin) } == true ? request : nil)
    }
}

private final class DoorbellXMLNode {
    let name: String
    let qualifiedName: String
    let namespace: String
    let attributes: [String: String]
    let namespaces: [String: String]
    var text = ""
    var children: [DoorbellXMLNode] = []
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(name: String, qualifiedName: String, namespace: String, attributes: [String: String], namespaces: [String: String]) {
        self.name = name; self.qualifiedName = qualifiedName; self.namespace = namespace
        self.attributes = attributes; self.namespaces = namespaces
    }
    func attribute(_ name: String) -> String? {
        attributes.first { ($0.key.split(separator: ":").last.map(String.init) ?? $0.key).caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    func descendants(_ name: String) -> [DoorbellXMLNode] {
        (self.name == name ? [self] : []) + children.flatMap { $0.descendants(name) }
    }
    func serializedReference() -> String {
        let declarations = namespaces.filter { $0.key != "xml" && $0.key != "wsa" }.sorted { $0.key < $1.key }.map {
            " \($0.key.isEmpty ? "xmlns" : "xmlns:\($0.key)")=\"\(DoorbellXML.escape($0.value))\""
        }.joined()
        return serialized(extra: declarations + " wsa:IsReferenceParameter=\"true\"")
    }
    private func serialized(extra: String = "") -> String {
        let attrs = attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(DoorbellXML.escape($0.value))\"" }.joined()
        return "<\(qualifiedName)\(attrs)\(extra)>\(DoorbellXML.escape(text))\(children.map { $0.serialized() }.joined())</\(qualifiedName)>"
    }
}

private final class DoorbellXML: NSObject, XMLParserDelegate {
    private var stack: [DoorbellXMLNode] = []
    private var roots: [DoorbellXMLNode] = []
    private var mappings: [String: [String]] = [:]

    static func parse(_ data: Data) throws -> DoorbellXMLNode {
        guard !data.isEmpty, data.count <= 2_000_000 else { throw DoorbellEventError.invalidResponse }
        let delegate = DoorbellXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.roots.count == 1, let root = delegate.roots.first else { throw DoorbellEventError.invalidResponse }
        return root
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        mappings[prefix, default: []].append(namespaceURI)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { mappings[prefix]?.removeLast() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 64 else { parser.abortParsing(); return }
        let node = DoorbellXMLNode(name: elementName, qualifiedName: qName ?? elementName, namespace: namespaceURI ?? "",
                                  attributes: attributeDict, namespaces: mappings.compactMapValues(\.last))
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(data: CDATABlock, encoding: .utf8) ?? "" }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
