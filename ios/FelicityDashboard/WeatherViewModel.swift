import Combine
import Foundation

@MainActor
final class WeatherViewModel: ObservableObject {
    @Published private(set) var selectedLocation: WeatherLocation?
    @Published private(set) var forecast: WeatherForecast?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var error = ""
    @Published private(set) var searchResults: [WeatherLocation] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError = ""

    private let service: any WeatherProviding
    private let defaults: UserDefaults
    private let cache: WeatherForecastCache
    private let now: () -> Date
    private let locationKey = "weather.location.v1"
    private var selectionGeneration: UInt = 0
    private var runGeneration: UInt = 0
    private var requestGeneration: UInt = 0
    private var searchGeneration: UInt = 0
    private var forecastTask: Task<WeatherForecast, Error>?
    private var searchTask: Task<[WeatherLocation], Error>?
    private var lastFailureAt: Date?
    private var restoredLocation: WeatherLocation?

    init(service: any WeatherProviding = WeatherService(), defaults: UserDefaults = .standard,
         cacheDirectory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.defaults = defaults
        self.now = now
        let directory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FelicityWeather", directoryHint: .isDirectory)
        cache = WeatherForecastCache(directory: directory)
        if let data = defaults.data(forKey: locationKey) {
            selectedLocation = try? JSONDecoder().decode(WeatherLocation.self, from: data)
        }
    }

    var isStale: Bool {
        guard forecast != nil, let updatedAt else { return false }
        return !error.isEmpty || now().timeIntervalSince(updatedAt) > 60 * 60 || !isSameForecastDay(updatedAt)
    }

    func selectLocation(_ location: WeatherLocation) {
        guard selectedLocation != location else { return }
        selectionGeneration &+= 1
        requestGeneration &+= 1
        forecastTask?.cancel()
        forecastTask = nil
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        selectedLocation = location
        forecast = nil
        updatedAt = nil
        error = ""
        isLoading = false
        lastFailureAt = nil
        restoredLocation = nil
        if let data = try? JSONEncoder().encode(location) { defaults.set(data, forKey: locationKey) }
    }

    func restore() async {
        guard !Task.isCancelled, let location = selectedLocation, restoredLocation != location else { return }
        let generation = selectionGeneration
        let entry = await cache.load()
        guard !Task.isCancelled, selectionGeneration == generation, selectedLocation == location else { return }
        restoredLocation = location
        guard forecast == nil, let entry, entry.location == location,
              isUsable(entry.fetchedAt) else { return }
        forecast = entry.forecast
        updatedAt = entry.fetchedAt
    }

    func refresh(force: Bool = false) async {
        guard !Task.isCancelled, let location = selectedLocation else { return }
        // A header, weather page and manual refresh may ask at the same time.
        // The existing request owns publication; followers do not start another.
        guard forecastTask == nil else { return }
        if let updatedAt, !isUsable(updatedAt) {
            forecast = nil
            self.updatedAt = nil
        }
        if !force {
            if let lastFailureAt, now().timeIntervalSince(lastFailureAt) < 5 * 60 { return }
            if let updatedAt, now().timeIntervalSince(updatedAt) < 30 * 60, isSameForecastDay(updatedAt) { return }
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        let service = service
        let request = Task { try await service.forecast(location: location) }
        forecastTask = request
        isLoading = true
        defer {
            if requestGeneration == generation {
                forecastTask = nil
                isLoading = false
            }
        }
        do {
            var received = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            guard requestGeneration == generation, selectedLocation == location else { return }
            let fetchedAt = now()
            received.fetchedAt = fetchedAt
            if forecast != received { forecast = received }
            updatedAt = fetchedAt
            lastFailureAt = nil
            error = ""
            await cache.save(.init(location: location, forecast: received, fetchedAt: fetchedAt))
        } catch {
            guard requestGeneration == generation, selectedLocation == location,
                  !Self.isCancellation(error), !Task.isCancelled else { return }
            lastFailureAt = now()
            self.error = error.localizedDescription
        }
    }

    func search(_ query: String) async {
        guard !Task.isCancelled else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = nil
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = ""
        searchResults = []
        guard query.count >= 2 else {
            isSearching = false
            return
        }
        let service = service
        let request = Task { try await service.search(query: query) }
        searchTask = request
        isSearching = true
        defer {
            if searchGeneration == generation {
                searchTask = nil
                isSearching = false
            }
        }
        do {
            let results = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            try Task.checkCancellation()
            guard searchGeneration == generation else { return }
            searchResults = results
        } catch {
            guard searchGeneration == generation, !Self.isCancellation(error), !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    func run() async {
        guard !Task.isCancelled else { return }
        runGeneration &+= 1
        let generation = runGeneration
        if forecastTask?.isCancelled == true {
            // A previous foreground loop may still await a slow cancellation.
            // Its refresh defer must not clear the replacement request.
            requestGeneration &+= 1
            forecastTask = nil
            isLoading = false
        }
        defer {
            if Task.isCancelled, runGeneration == generation {
                // Root owns this foreground loop. Also stop requests launched
                // by manual buttons while the loop itself was sleeping.
                requestGeneration &+= 1
                forecastTask?.cancel()
                forecastTask = nil
                isLoading = false
                searchGeneration &+= 1
                searchTask?.cancel()
                searchTask = nil
                isSearching = false
            }
        }
        await restore()
        while !Task.isCancelled, runGeneration == generation {
            await refresh()
            guard !Task.isCancelled, runGeneration == generation else { return }
            do { try await Task.sleep(for: .seconds(30 * 60)) }
            catch { return }
        }
    }

    private func isUsable(_ date: Date) -> Bool {
        let age = now().timeIntervalSince(date)
        return age >= -60 && age <= 6 * 60 * 60
    }

    private func isSameForecastDay(_ fetchedAt: Date) -> Bool {
        guard let forecast else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        return calendar.isDate(fetchedAt, inSameDayAs: now())
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

private actor WeatherForecastCache {
    struct Entry: Codable, Sendable {
        let location: WeatherLocation
        let forecast: WeatherForecast
        let fetchedAt: Date
    }

    private let directory: URL
    private let maximumBytes = 512 * 1_024
    private var file: URL { directory.appending(path: "forecast-v1.json") }

    init(directory: URL) { self.directory = directory }

    func load() -> Entry? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes, let data = try? Data(contentsOf: file), data.count <= maximumBytes else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    func save(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry), data.count <= maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch { /* Cache failure must not hide a valid network forecast. */ }
    }
}
