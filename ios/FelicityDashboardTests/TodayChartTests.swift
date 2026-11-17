import XCTest
@testable import FelicityDashboard

final class TodayChartTests: XCTestCase {
    func testMatchingBucketsAddPVStringsWithoutChangingOverview() {
        let today = chart([[300, 90], [500, 110]], metric: .today)
        let solar = chart([[300, 200, 100], [500, 350, 150]], metric: .solar)
        let merged = today.addingSolarStrings(from: solar)

        XCTAssertEqual(merged.channels, 4)
        XCTAssertEqual(merged.samples, [[300, 90, 200, 100], [500, 110, 350, 150]])
        XCTAssertEqual(merged.start, today.start)
        XCTAssertEqual(merged.end, today.end)
        XCTAssertEqual(merged.metric, .today)
        XCTAssertEqual(merged.date(at: 1, metric: .today), solar.date(at: 1, metric: .solar))
    }

    func testDifferentDaysCannotMergeEvenWithMatchingBucketCounts() {
        let today = chart([[300, 90], [500, 110]], metric: .today)
        var solar = chart([[300, 200, 100], [500, 350, 150]], metric: .solar)
        solar.start = solar.start?.addingTimeInterval(86_400)
        solar.end = solar.end?.addingTimeInterval(86_400)
        XCTAssertEqual(today.addingSolarStrings(from: solar), today)
    }

    func testDifferentResolutionWindowOrMissingTimingLeavesStringsUnavailable() {
        let today = chart([[300, 90], [500, 110]], metric: .today)
        var solar = chart([[300, 200, 100]], metric: .solar)
        XCTAssertEqual(today.addingSolarStrings(from: solar), today)
        solar.samples.append([500, 350, 150])
        solar.end = solar.end?.addingTimeInterval(60)
        XCTAssertEqual(today.addingSolarStrings(from: solar), today)
        solar.end = today.end
        solar.start = nil
        XCTAssertEqual(today.addingSolarStrings(from: solar), today)
    }

    func testGapsAndShortRowsDoNotInventPowerInOtherChannels() {
        let today = chart([[300, 90], nil, [500, 110], nil], metric: .today)
        let solar = chart([nil, [400, 250, 150], [500, 350], nil], metric: .solar)
        let merged = today.addingSolarStrings(from: solar)

        XCTAssertEqual(merged.segments(channel: 0).map { $0.map(\.id) }, [[0], [2]])
        XCTAssertEqual(merged.segments(channel: 1).map { $0.map(\.value) }, [[90], [110]])
        XCTAssertEqual(merged.segments(channel: 2).map { $0.map(\.id) }, [[1, 2]])
        XCTAssertEqual(merged.segments(channel: 2).flatMap { $0.map(\.value) }, [250, 350])
        XCTAssertEqual(merged.segments(channel: 3).map { $0.map(\.id) }, [[1]])
        XCTAssertNil(merged.samples[3])
    }

    func testZeroAndSignedReadingsStayRealWhileNonfiniteValuesRemainMissing() {
        let today = chart([[0, -20], [-5, 50]], metric: .today)
        let solar = chart([[0, 0, 0], [-5, -5, .infinity]], metric: .solar)
        let merged = today.addingSolarStrings(from: solar)

        XCTAssertEqual(merged.segments(channel: 2).flatMap { $0.map(\.value) }, [0, -5])
        XCTAssertEqual(merged.segments(channel: 3).flatMap { $0.map(\.value) }, [0])
        XCTAssertEqual(merged.segments(channel: 1).flatMap { $0.map(\.value) }, [-20, 50])
        XCTAssertLessThan(merged.domain(channels: [2]).lowerBound, -5)
    }

    func testUndeclaredSolarChannelCannotBecomePV2Data() {
        let today = chart([[300, 90]], metric: .today)
        var solar = chart([[300, 200, 100]], metric: .solar)
        solar.channels = 2
        let merged = today.addingSolarStrings(from: solar)
        XCTAssertEqual(merged.segments(channel: 2).first?.first?.value, 200)
        XCTAssertTrue(merged.segments(channel: 3).isEmpty)
    }

    func testIdenticalMergedGapsCompareEqualWithoutHidingActualChanges() {
        let today = chart([[300], nil], metric: .today)
        let solar = chart([[300, 200], [400, 250, 150]], metric: .solar)
        let first = today.addingSolarStrings(from: solar)
        XCTAssertEqual(first, today.addingSolarStrings(from: solar))
        var changed = solar
        changed.samples[0] = [300, 201]
        XCTAssertNotEqual(first, today.addingSolarStrings(from: changed))
    }

    func testTodayAPIMergesBothExistingEndpoints() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let api = FelicityAPI(session: session)
        let result = try await api.chart(baseURL: URL(string: "http://success.invalid")!, metric: .today)
        XCTAssertEqual(result.samples, [[300, 90, 200, 100], [500, 110, 350, 150]])
        XCTAssertEqual(result.channels, 4)
    }

    func testSolarHTTPFailureStillReturnsTodayOverview() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let api = FelicityAPI(session: session)
        let result = try await api.chart(baseURL: URL(string: "http://solar-failure.invalid")!, metric: .today)
        XCTAssertEqual(result.samples, [[300, 90], [500, 110]])
        XCTAssertEqual(result.channels, 2)
        XCTAssertTrue(result.segments(channel: 2).isEmpty)
        XCTAssertTrue(result.segments(channel: 3).isEmpty)
    }

    func testTodayHTTPFailureCannotBeReplacedBySolarData() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let api = FelicityAPI(session: session)
        do {
            _ = try await api.chart(baseURL: URL(string: "http://today-failure.invalid")!, metric: .today)
            XCTFail("The required Today overview failed")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Felicity HTTP 503")
        }
    }

    private func chart(_ samples: [[Double]?], metric: DashboardMetric) -> DashboardChart {
        DashboardChart(samples: samples, channels: metric == .today ? 2 : 3,
                       start: Date(timeIntervalSince1970: 1_800_000_000),
                       end: Date(timeIntervalSince1970: 1_800_086_400), metric: metric)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TodayChartURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TodayChartURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let metric = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "metric" }?.value
        let solar = metric == "pv"
        let failure = (solar && url.host == "solar-failure.invalid") || (!solar && url.host == "today-failure.invalid")
        let response = HTTPURLResponse(url: url, statusCode: failure ? 503 : 200, httpVersion: nil, headerFields: nil)!
        let payload: [String: Any] = [
            "metric": solar ? "pv" : "today", "channels": solar ? 3 : 2,
            "start": "2026-11-16T00:00:00+01:00", "end": "2026-11-17T00:00:00+01:00",
            "samples": solar ? [[300, 200, 100], [500, 350, 150]] : [[300, 90], [500, 110]]
        ]
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
