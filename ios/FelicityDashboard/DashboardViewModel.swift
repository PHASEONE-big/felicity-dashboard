import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot = DashboardSnapshot()
    @Published private(set) var status = ServerStatus()
    @Published private(set) var error = "Waiting for data"
    @Published private(set) var chart = DashboardChart()
    @Published private(set) var chartMetric: DashboardMetric?
    @Published private(set) var chartError = ""
    @Published private(set) var isLoadingChart = false
    @Published var serverText: String {
        didSet {
            guard Self.serverIdentity(oldValue) != Self.serverIdentity(serverText), let metric = chartMetric else { return }
            selectChart(metric)
        }
    }

    private let api: any DashboardProviding
    private let defaults: UserDefaults
    private let now: () -> Date
    private var chartCache: [ChartCacheKey: CachedChart] = [:]
    private var selectedChartKey: ChartCacheKey?
    private var chartRequestGeneration: UInt = 0

    init(api: any DashboardProviding = FelicityAPI(), defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.defaults = defaults
        self.now = now
        serverText = defaults.string(forKey: "felicity.server") ?? "http://homeassistant.local:8000"
    }

    var isLive: Bool {
        status.online && snapshot.updatedAt.map { Date().timeIntervalSince($0) < 12 } == true
    }

    func saveServer() {
        serverText = serverText.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        defaults.set(serverText, forKey: "felicity.server")
    }

    func run(lowPower: Bool = false) async {
        var iteration = 0
        while !Task.isCancelled {
            // The idle clock needs only household power, not charts, totals or
            // server telemetry. Fetch it infrequently to keep the radio idle.
            await refresh(
                includeSummary: !lowPower && iteration % 5 == 0,
                includeStatus: !lowPower && iteration % 3 == 0
            )
            guard !Task.isCancelled else { return }
            iteration += 1
            do { try await Task.sleep(for: .seconds(lowPower ? 30 : 2)) }
            catch { return }
        }
    }

    func chartRefreshInterval(for metric: DashboardMetric) -> TimeInterval {
        metric == .system ? 10 : 60
    }

    /// Restore the matching route immediately, including a stale chart while it
    /// refreshes. A different metric or server must never show the previous one.
    func selectChart(_ metric: DashboardMetric) {
        let key = ChartCacheKey(server: Self.serverIdentity(serverText), metric: metric)
        guard selectedChartKey != key else { return }
        chartRequestGeneration &+= 1
        selectedChartKey = key
        chartMetric = metric
        let restored = chartCache[key]?.chart ?? DashboardChart()
        if chart != restored { chart = restored }
        chartError = ""
        isLoadingChart = false
    }

    func refreshChart(_ metric: DashboardMetric, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        selectChart(metric)
        guard let baseURL = Self.chartBaseURL(serverText), let key = selectedChartKey else {
            chartError = APIError.invalidServer.localizedDescription
            isLoadingChart = false
            return
        }
        if !force, let cached = chartCache[key], now().timeIntervalSince(cached.fetchedAt) < chartRefreshInterval(for: metric) {
            return
        }
        chartRequestGeneration &+= 1
        let generation = chartRequestGeneration
        // Keep an existing chart steady during its background refresh.
        isLoadingChart = chart.samples.isEmpty
        defer {
            if chartRequestGeneration == generation, selectedChartKey == key {
                isLoadingChart = false
            }
        }
        do {
            let refreshed = try await api.chart(baseURL: baseURL, metric: metric)
            try Task.checkCancellation()
            guard isCurrentChartRequest(generation, key: key) else { return }
            chartCache[key] = CachedChart(chart: refreshed, fetchedAt: now())
            if chart != refreshed { chart = refreshed }
            chartError = ""
        } catch {
            guard isCurrentChartRequest(generation, key: key), !Task.isCancelled,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            chartError = error.localizedDescription
        }
    }

    func clearChart() {
        chartRequestGeneration &+= 1
        selectedChartKey = nil
        if chart != DashboardChart() { chart = .init() }
        chartMetric = nil
        chartError = ""
        isLoadingChart = false
    }

    private func isCurrentChartRequest(_ generation: UInt, key: ChartCacheKey) -> Bool {
        chartRequestGeneration == generation && selectedChartKey == key && key.server == Self.serverIdentity(serverText)
    }

    private static func chartBaseURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        return components.url
    }

    private static func serverIdentity(_ text: String) -> String {
        chartBaseURL(text)?.absoluteString ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChartCacheKey: Hashable {
        let server: String
        let metric: DashboardMetric
    }

    private struct CachedChart {
        let chart: DashboardChart
        let fetchedAt: Date
    }

    private func refresh(includeSummary: Bool, includeStatus: Bool) async {
        guard let baseURL = URL(string: serverText), baseURL.scheme != nil else {
            status.online = false
            error = APIError.invalidServer.localizedDescription
            return
        }
        do {
            let current = try await api.current(baseURL: baseURL, previous: snapshot)
            try Task.checkCancellation()
            snapshot = current
            if includeSummary {
                let summary = try await api.summary(baseURL: baseURL, previous: snapshot)
                try Task.checkCancellation()
                snapshot = summary
            }
            if includeStatus {
                let serverStatus = try await api.status(baseURL: baseURL)
                try Task.checkCancellation()
                status = serverStatus
            }
            else { status.online = true }
            error = ""
        } catch {
            // Switching between clock and dashboard cancels the previous poll;
            // cancellation is not a lost connection and must not overwrite it.
            guard !Task.isCancelled else { return }
            status.online = false
            self.error = error.localizedDescription
        }
    }
}
