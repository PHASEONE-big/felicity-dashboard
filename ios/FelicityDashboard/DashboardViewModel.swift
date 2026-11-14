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
    @Published var serverText: String

    private let api: any DashboardProviding
    private let defaults: UserDefaults

    init(api: any DashboardProviding = FelicityAPI(), defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
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

    func refreshChart(_ metric: DashboardMetric) async {
        guard let baseURL = URL(string: serverText), baseURL.scheme != nil else {
            chartError = APIError.invalidServer.localizedDescription
            return
        }
        chartMetric = metric
        if chart.samples.isEmpty { isLoadingChart = true }
        do {
            chart = try await api.chart(baseURL: baseURL, metric: metric)
            chartError = ""
        } catch {
            chartError = error.localizedDescription
        }
        isLoadingChart = false
    }

    func clearChart() {
        chart = .init()
        chartMetric = nil
        chartError = ""
        isLoadingChart = false
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
