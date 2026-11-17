import Combine
import XCTest
@testable import FelicityDashboard

final class WeatherViewModelTests: XCTestCase {
    @MainActor
    func testNoDefaultCityOrForecastRequestBeforeSelection() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        await model.restore()
        await model.refresh()
        XCTAssertNil(model.selectedLocation)
        XCTAssertNil(model.forecast)
        let count = await service.forecastCount
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testLocationAndForecastPersistForOfflineRestore() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let first = context.model(service)
        first.selectLocation(cityA)
        await completeRefresh(first, service: service, index: 0, temperature: 17)
        let restored = context.model(service)
        await restored.restore()

        XCTAssertEqual(restored.selectedLocation, cityA)
        XCTAssertEqual(restored.forecast?.current.temperature, 17)
        XCTAssertEqual(restored.updatedAt, context.clock.date)
        XCTAssertFalse(restored.isStale)
        await restored.refresh()
        let count = await service.forecastCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testCacheFromDifferentCityCannotAppearUnderNewLocation() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        await completeRefresh(model, service: service, index: 0, temperature: 17)
        model.selectLocation(cityB)
        XCTAssertNil(model.forecast)
        let restored = context.model(service)
        await restored.restore()
        XCTAssertEqual(restored.selectedLocation, cityB)
        XCTAssertNil(restored.forecast)
        XCTAssertNil(restored.updatedAt)
    }

    @MainActor
    func testLateOldCityResponseCannotOverwriteNewCity() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        let old = Task { await model.refresh() }
        await service.waitForForecast(0)
        model.selectLocation(cityB)
        await completeRefresh(model, service: service, index: 1, temperature: 12)
        await service.finishForecast(0, result: .success(forecast(99)))
        await old.value
        XCTAssertEqual(model.selectedLocation, cityB)
        XCTAssertEqual(model.forecast?.current.temperature, 12)
        XCTAssertEqual(model.error, "")
        XCTAssertFalse(model.isLoading)
        let restored = context.model(service)
        await restored.restore()
        XCTAssertEqual(restored.forecast?.current.temperature, 12)
    }

    @MainActor
    func testConcurrentRefreshesDeduplicateAndSuccessfulCacheLastsThirtyMinutes() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        let first = Task { await model.refresh() }
        await service.waitForForecast(0)
        await model.refresh(force: true)
        let activeCount = await service.forecastCount
        XCTAssertEqual(activeCount, 1)
        await service.finishForecast(0, result: .success(forecast(17)))
        await first.value
        context.clock.date.addTimeInterval(1_799)
        await model.refresh()
        let freshCount = await service.forecastCount
        XCTAssertEqual(freshCount, 1)
        context.clock.date.addTimeInterval(1)
        await completeRefresh(model, service: service, index: 1, temperature: 18)
        XCTAssertEqual(model.forecast?.current.temperature, 18)
    }

    @MainActor
    func testFailedRefreshPreservesForecastAndBacksOffForFiveMinutes() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        await completeRefresh(model, service: service, index: 0, temperature: 17)
        context.clock.date.addTimeInterval(1_800)
        let failed = Task { await model.refresh() }
        await service.waitForForecast(1)
        await service.finishForecast(1, result: .failure(URLError(.notConnectedToInternet)))
        await failed.value
        XCTAssertEqual(model.forecast?.current.temperature, 17)
        XCTAssertTrue(model.isStale)
        XCTAssertFalse(model.error.isEmpty)
        context.clock.date.addTimeInterval(299)
        await model.refresh()
        let backedOffCount = await service.forecastCount
        XCTAssertEqual(backedOffCount, 2)
        context.clock.date.addTimeInterval(1)
        await completeRefresh(model, service: service, index: 2, temperature: 18)
        XCTAssertEqual(model.error, "")
        XCTAssertFalse(model.isStale)
    }

    @MainActor
    func testManualRefreshBypassesFailureBackoff() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        let failed = Task { await model.refresh() }
        await service.waitForForecast(0)
        await service.finishForecast(0, result: .failure(URLError(.timedOut)))
        await failed.value
        await completeRefresh(model, service: service, index: 1, temperature: 19, force: true)
        XCTAssertEqual(model.forecast?.current.temperature, 19)
        XCTAssertEqual(model.error, "")
    }

    @MainActor
    func testCancelledForegroundPollingDoesNotPublishLateDataOrError() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        let request = Task { await model.run() }
        await service.waitForForecast(0)
        request.cancel()
        await service.finishForecast(0, result: .success(forecast(99)))
        await request.value
        XCTAssertNil(model.forecast)
        XCTAssertNil(model.updatedAt)
        XCTAssertEqual(model.error, "")
        XCTAssertFalse(model.isLoading)
        await completeRefresh(model, service: service, index: 1, temperature: 17)
        XCTAssertEqual(model.forecast?.current.temperature, 17)
    }

    @MainActor
    func testRestartedForegroundRequestSurvivesOldLoopCancellationCleanup() async throws {
        let context = try makeContext()
        let restarted = expectation(description: "New foreground starts its own request")
        let service = ControlledWeatherService { index in
            if index == 1 { restarted.fulfill() }
        }
        let model = context.model(service)
        model.selectLocation(cityA)
        let oldRun = Task { await model.run() }
        await service.waitForForecast(0)
        oldRun.cancel()
        // The fake deliberately holds the canceled response until a new loop
        // has started, reproducing slow network cancellation deterministically.
        let newRun = Task { await model.run() }
        await fulfillment(of: [restarted], timeout: 2)
        let count = await service.forecastCount
        guard count == 2 else {
            newRun.cancel()
            await service.finishForecast(0, result: .success(forecast(99)))
            await oldRun.value
            await newRun.value
            XCTFail("Canceled request blocked the new foreground refresh")
            return
        }
        await service.finishForecast(0, result: .success(forecast(99)))
        await oldRun.value
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.forecast)

        let published = expectation(description: "New foreground publishes its forecast")
        let subscription = model.$forecast.compactMap { $0 }.first().sink { _ in published.fulfill() }
        defer { subscription.cancel() }
        await service.finishForecast(1, result: .success(forecast(17)))
        await fulfillment(of: [published], timeout: 2)
        newRun.cancel()
        await newRun.value
        XCTAssertEqual(model.forecast?.current.temperature, 17)
        XCTAssertEqual(model.error, "")
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testOlderSearchCannotReplaceNewerResults() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        let old = Task { await model.search("Rome") }
        await service.waitForSearch(0)
        let current = Task { await model.search("Berlin") }
        await service.waitForSearch(1)
        await service.finishSearch(1, result: .success([cityB]))
        await current.value
        await service.finishSearch(0, result: .success([cityA]))
        await old.value
        XCTAssertEqual(model.searchResults, [cityB])
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.searchError, "")
    }

    @MainActor
    func testShortQueryClearsResultsAndInvalidatesPendingSearch() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        let old = Task { await model.search("Rome") }
        await service.waitForSearch(0)
        await model.search(" a ")
        await service.finishSearch(0, result: .success([cityA]))
        await old.value
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertFalse(model.isSearching)
        let count = await service.searchCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSearchCancellationDoesNotBecomeAnError() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        let request = Task { await model.search("Rome") }
        await service.waitForSearch(0)
        request.cancel()
        await service.finishSearch(0, result: .failure(URLError(.cancelled)))
        await request.value
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertEqual(model.searchError, "")
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testCacheBecomesStaleAfterAnHourAndExpiresAfterSixHours() async throws {
        let context = try makeContext()
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        await completeRefresh(model, service: service, index: 0, temperature: 17)
        context.clock.date.addTimeInterval(3_601)
        let stale = context.model(service)
        await stale.restore()
        XCTAssertEqual(stale.forecast?.current.temperature, 17)
        XCTAssertTrue(stale.isStale)
        context.clock.date.addTimeInterval(6 * 3_600)
        let expired = context.model(service)
        await expired.restore()
        XCTAssertNil(expired.forecast)
    }

    @MainActor
    func testCityMidnightInvalidatesThirtyMinuteCache() async throws {
        let context = try makeContext()
        // 23:55 in UTC+1; the selected forecast's timezone governs rollover.
        context.clock.date = ISO8601DateFormatter().date(from: "2026-11-16T22:55:00Z")!
        let service = ControlledWeatherService()
        let model = context.model(service)
        model.selectLocation(cityA)
        await completeRefresh(model, service: service, index: 0, temperature: 17)
        context.clock.date.addTimeInterval(10 * 60)
        XCTAssertTrue(model.isStale)
        await completeRefresh(model, service: service, index: 1, temperature: 18)
        XCTAssertEqual(model.updatedAt, context.clock.date)
        XCTAssertFalse(model.isStale)
    }

    @MainActor
    private func completeRefresh(_ model: WeatherViewModel, service: ControlledWeatherService,
                                 index: Int, temperature: Double, force: Bool = false) async {
        let task = Task { await model.refresh(force: force) }
        await service.waitForForecast(index)
        await service.finishForecast(index, result: .success(forecast(temperature)))
        await task.value
    }

    private var cityA: WeatherLocation { .init(id: "rome", name: "Rome", country: "Italy", latitude: 41.9, longitude: 12.5, timezone: "Europe/Rome") }
    private var cityB: WeatherLocation { .init(id: "berlin", name: "Berlin", country: "Germany", latitude: 52.5, longitude: 13.4, timezone: "Europe/Berlin") }

    private func forecast(_ temperature: Double) -> WeatherForecast {
        .init(timezoneID: "Europe/Rome", current: .init(date: Date(timeIntervalSince1970: 1_800_000_000), temperature: temperature, code: 0, isDay: true), hourly: [], daily: [])
    }

    @MainActor
    private func makeContext() throws -> WeatherTestContext {
        let suite = "WeatherViewModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return .init(defaults: defaults, directory: directory)
    }
}

@MainActor
private final class WeatherTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private struct WeatherTestContext {
    let defaults: UserDefaults
    let directory: URL
    let clock = WeatherTestClock()

    func model(_ service: ControlledWeatherService) -> WeatherViewModel {
        WeatherViewModel(service: service, defaults: defaults, cacheDirectory: directory, now: { clock.date })
    }
}

private actor ControlledWeatherService: WeatherProviding {
    private(set) var forecastCount = 0
    private(set) var searchCount = 0
    private var forecasts: [Int: CheckedContinuation<WeatherForecast, Error>] = [:]
    private var searches: [Int: CheckedContinuation<[WeatherLocation], Error>] = [:]
    private var forecastWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var searchWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private let onForecast: @Sendable (Int) -> Void

    init(onForecast: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.onForecast = onForecast
    }

    func forecast(location: WeatherLocation) async throws -> WeatherForecast {
        let index = forecastCount
        forecastCount += 1
        return try await withCheckedThrowingContinuation {
            forecasts[index] = $0
            forecastWaiters.removeValue(forKey: index)?.resume()
            onForecast(index)
        }
    }

    func search(query: String) async throws -> [WeatherLocation] {
        let index = searchCount
        searchCount += 1
        return try await withCheckedThrowingContinuation {
            searches[index] = $0
            searchWaiters.removeValue(forKey: index)?.resume()
        }
    }

    func waitForForecast(_ index: Int) async {
        if forecasts[index] != nil { return }
        await withCheckedContinuation { forecastWaiters[index] = $0 }
    }

    func waitForSearch(_ index: Int) async {
        if searches[index] != nil { return }
        await withCheckedContinuation { searchWaiters[index] = $0 }
    }

    func finishForecast(_ index: Int, result: Result<WeatherForecast, Error>) {
        forecasts.removeValue(forKey: index)?.resume(with: result)
    }

    func finishSearch(_ index: Int, result: Result<[WeatherLocation], Error>) {
        searches.removeValue(forKey: index)?.resume(with: result)
    }
}
