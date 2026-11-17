import Combine
import XCTest
@testable import FelicityDashboard

final class ChartLoadingTests: XCTestCase {
    @MainActor
    func testLateMetricResponseCannotReplaceNewerRoute() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let old = Task { await model.refreshChart(.solar) }
        await api.waitForRequest(0)
        let current = Task { await model.refreshChart(.load) }
        await api.waitForRequest(1)
        await api.finish(1, with: .success(chart(200)))
        await current.value
        await api.finish(0, with: .success(chart(100)))
        await old.value

        XCTAssertEqual(model.chartMetric, .load)
        XCTAssertEqual(model.chart, chart(200))
        XCTAssertEqual(model.chartError, "")
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testClearingRoutePreventsLateResponseFromReopeningChart() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let request = Task { await model.refreshChart(.solar) }
        await api.waitForRequest(0)
        model.clearChart()
        await api.finish(0, with: .success(chart(100)))
        await request.value

        XCTAssertNil(model.chartMetric)
        XCTAssertTrue(model.chart.samples.isEmpty)
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testCancelledRequestDoesNotPublishDataOrAnError() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let request = Task { await model.refreshChart(.load) }
        await api.waitForRequest(0)
        request.cancel()
        // This fake deliberately ignores cancellation, like a late callback.
        await api.finish(0, with: .success(chart(100)))
        await request.value

        XCTAssertTrue(model.chart.samples.isEmpty)
        XCTAssertEqual(model.chartError, "")
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testURLSessionCancellationIsNotAChartError() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let request = Task { await model.refreshChart(.load) }
        await api.waitForRequest(0)
        await api.finish(0, with: .failure(URLError(.cancelled)))
        await request.value

        XCTAssertEqual(model.chartError, "")
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testWarmCacheRestoresImmediatelyAndAvoidsAnotherRequest() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let request = Task { await model.refreshChart(.solar) }
        await api.waitForRequest(0)
        await api.finish(0, with: .success(chart(100)))
        await request.value
        model.selectChart(.load)
        XCTAssertTrue(model.chart.samples.isEmpty)
        model.selectChart(.solar)

        XCTAssertEqual(model.chartMetric, .solar)
        XCTAssertEqual(model.chart, chart(100))
        XCTAssertFalse(model.isLoadingChart)
        await model.refreshChart(.solar)
        let count = await api.requestCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testFailedRefreshKeepsVisibleChart() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let first = Task { await model.refreshChart(.load) }
        await api.waitForRequest(0)
        await api.finish(0, with: .success(chart(100)))
        await first.value
        let refresh = Task { await model.refreshChart(.load, force: true) }
        await api.waitForRequest(1)
        XCTAssertFalse(model.isLoadingChart)
        await api.finish(1, with: .failure(URLError(.notConnectedToInternet)))
        await refresh.value

        XCTAssertEqual(model.chart, chart(100))
        XCTAssertFalse(model.chartError.isEmpty)
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testCacheIsPartitionedByServerAndLateOldServerResponseIsIgnored() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let first = Task { await model.refreshChart(.load) }
        await api.waitForRequest(0)
        await api.finish(0, with: .success(chart(100)))
        await first.value
        let oldRefresh = Task { await model.refreshChart(.load, force: true) }
        await api.waitForRequest(1)
        model.serverText = "http://second.local:8000"
        XCTAssertTrue(model.chart.samples.isEmpty)
        let second = Task { await model.refreshChart(.load) }
        await api.waitForRequest(2)
        await api.finish(2, with: .success(chart(200)))
        await second.value
        await api.finish(1, with: .success(chart(999)))
        await oldRefresh.value
        XCTAssertEqual(model.chart, chart(200))

        model.serverText = "http://first.local:8000/"
        XCTAssertEqual(model.chart, chart(100))
        model.serverText = "http://second.local:8000"
        XCTAssertEqual(model.chart, chart(200))
    }

    @MainActor
    func testInvalidServerFinishesLoadingAndCannotShowPreviousServerData() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        let request = Task { await model.refreshChart(.load) }
        await api.waitForRequest(0)
        XCTAssertTrue(model.isLoadingChart)
        model.serverText = "not a server"
        await model.refreshChart(.load)
        await api.finish(0, with: .success(chart(100)))
        await request.value

        XCTAssertEqual(model.chartMetric, .load)
        XCTAssertTrue(model.chart.samples.isEmpty)
        XCTAssertEqual(model.chartError, APIError.invalidServer.localizedDescription)
        XCTAssertFalse(model.isLoadingChart)
    }

    @MainActor
    func testIdenticalRefreshDoesNotRepublishChart() async throws {
        let api = ControlledChartAPI()
        let model = try makeModel(api: api)
        var publications = 0
        let subscription = model.$chart.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for index in 0..<2 {
            let request = Task { await model.refreshChart(.load, force: true) }
            await api.waitForRequest(index)
            await api.finish(index, with: .success(chart(100)))
            await request.value
        }
        XCTAssertEqual(publications, 1)
    }

    @MainActor
    func testEnergyCacheExpiresAfterSixtySecondsAndSystemAfterTen() async throws {
        for (metric, lifetime) in [(DashboardMetric.load, 60.0), (.system, 10.0)] {
            let api = ControlledChartAPI()
            let clock = TestClock()
            let model = try makeModel(api: api, now: { clock.date })
            let first = Task { await model.refreshChart(metric) }
            await api.waitForRequest(0)
            await api.finish(0, with: .success(chart(100)))
            await first.value
            clock.date.addTimeInterval(lifetime - 1)
            await model.refreshChart(metric)
            let beforeExpiry = await api.requestCount
            XCTAssertEqual(beforeExpiry, 1)
            clock.date.addTimeInterval(1)
            let expired = Task { await model.refreshChart(metric) }
            await api.waitForRequest(1)
            XCTAssertEqual(model.chart, chart(100))
            await api.finish(1, with: .success(chart(200)))
            await expired.value
            XCTAssertEqual(model.chart, chart(200))
        }
    }

    @MainActor
    private func makeModel(api: ControlledChartAPI, now: @escaping () -> Date = Date.init) throws -> DashboardViewModel {
        let suite = "ChartLoadingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("http://first.local:8000", forKey: "felicity.server")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return DashboardViewModel(api: api, defaults: defaults, now: now)
    }

    private func chart(_ value: Double) -> DashboardChart {
        DashboardChart(samples: [[value]], channels: 1)
    }
}

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor ControlledChartAPI: DashboardProviding {
    private(set) var requestCount = 0
    private var pending: [Int: CheckedContinuation<DashboardChart, Error>] = [:]
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

    func chart(baseURL: URL, metric: DashboardMetric) async throws -> DashboardChart {
        let index = requestCount
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            waiting.removeValue(forKey: index)?.resume()
        }
    }

    func waitForRequest(_ index: Int) async {
        if pending[index] != nil { return }
        await withCheckedContinuation { waiting[index] = $0 }
    }

    func finish(_ index: Int, with result: Result<DashboardChart, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func current(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot { previous }
    func summary(baseURL: URL, previous: DashboardSnapshot) async throws -> DashboardSnapshot { previous }
    func status(baseURL: URL) async throws -> ServerStatus { .init() }
}
