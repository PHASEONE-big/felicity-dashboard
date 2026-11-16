import CoreFoundation
import Foundation

protocol WeatherProviding: Sendable {
    func search(query: String) async throws -> [WeatherLocation]
    func forecast(location: WeatherLocation) async throws -> WeatherForecast
}

enum WeatherServiceError: Error, LocalizedError {
    case invalidLocation
    case invalidResponse
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidLocation: return "Choose a valid weather location."
        case .invalidResponse: return "The weather service returned incomplete data."
        case .unavailable: return "The weather service is temporarily unavailable."
        }
    }
}

struct WeatherService: WeatherProviding {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func search(query: String) async throws -> [WeatherLocation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let data = try await fetch(Self.searchURL(query: query))
        return try Self.decodeLocations(data)
    }

    func forecast(location: WeatherLocation) async throws -> WeatherForecast {
        let data = try await fetch(Self.forecastURL(for: location))
        return try Self.decodeForecast(data)
    }

    private func fetch(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WeatherServiceError.unavailable
        }
        guard data.count <= 2_000_000 else { throw WeatherServiceError.invalidResponse }
        return data
    }

    static func searchURL(query: String) -> URL {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "count", value: "5"), .init(name: "language", value: "en"),
            .init(name: "format", value: "json")
        ]
        // Form-style query parsers otherwise interpret a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func forecastURL(for location: WeatherLocation) throws -> URL {
        guard location.latitude.isFinite, (-90...90).contains(location.latitude),
              location.longitude.isFinite, (-180...180).contains(location.longitude) else {
            throw WeatherServiceError.invalidLocation
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(location.latitude)),
            .init(name: "longitude", value: String(location.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,weather_code,cloud_cover,wind_speed_10m"),
            .init(name: "hourly", value: "temperature_2m,apparent_temperature,weather_code,precipitation_probability,cloud_cover,wind_speed_10m,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "forecast_days", value: "7"), .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"), .init(name: "temperature_unit", value: "celsius"),
            .init(name: "wind_speed_unit", value: "kmh"), .init(name: "precipitation_unit", value: "mm")
        ]
        return components.url!
    }

    static func decodeLocations(_ data: Data) throws -> [WeatherLocation] {
        let object = try jsonObject(data)
        guard object["error"] as? Bool != true else { throw WeatherServiceError.unavailable }
        guard let results = object["results"] as? [[String: Any]] else { return [] }
        return Array(results.compactMap { row -> WeatherLocation? in
            guard let identifier = integer(row["id"]), let name = row["name"] as? String, !name.isEmpty,
                  let latitude = number(row["latitude"]), (-90...90).contains(latitude),
                  let longitude = number(row["longitude"]), (-180...180).contains(longitude) else { return nil }
            return WeatherLocation(id: String(identifier), name: name,
                                   country: row["country"] as? String ?? row["country_code"] as? String ?? "",
                                   latitude: latitude, longitude: longitude, timezone: row["timezone"] as? String)
        }.prefix(5))
    }

    static func decodeForecast(_ data: Data, fetchedAt: Date = .now) throws -> WeatherForecast {
        let object = try jsonObject(data)
        guard object["error"] as? Bool != true,
              let timezoneID = object["timezone"] as? String, let timezone = TimeZone(identifier: timezoneID),
              let current = object["current"] as? [String: Any],
              let timestamp = number(current["time"]), let temperature = number(current["temperature_2m"]),
              let code = integer(current["weather_code"]), let isDay = integer(current["is_day"]),
              (0...1).contains(isDay) else { throw WeatherServiceError.invalidResponse }

        let conditions = WeatherCurrent(date: Date(timeIntervalSince1970: timestamp), temperature: temperature,
            apparentTemperature: number(current["apparent_temperature"]), code: code, isDay: isDay == 1,
            windSpeed: number(current["wind_speed_10m"]), cloudCover: percentage(current["cloud_cover"]),
            humidity: percentage(current["relative_humidity_2m"]), precipitation: number(current["precipitation"]),
            rain: number(current["rain"]))

        let hours = object["hourly"] as? [String: Any] ?? [:]
        let hourly = array(hours, "time").indices.compactMap { index -> WeatherHour? in
            guard let time = number(value(hours, "time", index)), let temp = number(value(hours, "temperature_2m", index)),
                  let code = integer(value(hours, "weather_code", index)) else { return nil }
            return WeatherHour(date: Date(timeIntervalSince1970: time), temperature: temp, code: code,
                precipitationProbability: percentage(value(hours, "precipitation_probability", index)),
                windSpeed: number(value(hours, "wind_speed_10m", index)),
                apparentTemperature: number(value(hours, "apparent_temperature", index)),
                cloudCover: percentage(value(hours, "cloud_cover", index)),
                isDay: dayFlag(value(hours, "is_day", index)))
        }

        let days = object["daily"] as? [String: Any] ?? [:]
        let offset = number(object["utc_offset_seconds"])
        let daily = array(days, "time").indices.compactMap { index -> WeatherDay? in
            guard let time = number(value(days, "time", index)), let code = integer(value(days, "weather_code", index)),
                  let minimum = number(value(days, "temperature_2m_min", index)),
                  let maximum = number(value(days, "temperature_2m_max", index)), minimum <= maximum else { return nil }
            return WeatherDay(date: dailyDate(time, offset: offset, timezone: timezone), code: code,
                minimumTemperature: minimum, maximumTemperature: maximum,
                precipitationProbability: percentage(value(days, "precipitation_probability_max", index)))
        }
        return WeatherForecast(timezoneID: timezoneID, current: conditions,
                               hourly: hourly, daily: daily, fetchedAt: fetchedAt)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WeatherServiceError.invalidResponse
        }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    private static func percentage(_ value: Any?) -> Double? {
        guard let value = number(value), (0...100).contains(value) else { return nil }
        return value
    }

    private static func dayFlag(_ value: Any?) -> Bool? {
        guard let value = integer(value), (0...1).contains(value) else { return nil }
        return value == 1
    }

    private static func array(_ object: [String: Any], _ key: String) -> [Any] { object[key] as? [Any] ?? [] }
    private static func value(_ object: [String: Any], _ key: String, _ index: Int) -> Any? {
        let values = array(object, key)
        return values.indices.contains(index) ? values[index] : nil
    }

    private static func dailyDate(_ timestamp: Double, offset: Double?, timezone: TimeZone) -> Date {
        let date = Date(timeIntervalSince1970: timestamp)
        guard let offset else { return date }
        // API daily boundaries use its request-time offset even across DST.
        // Recover that civil date, then use the zone's actual midnight for UI.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day], from: date.addingTimeInterval(offset))
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timezone
        return local.date(from: components) ?? date
    }
}
