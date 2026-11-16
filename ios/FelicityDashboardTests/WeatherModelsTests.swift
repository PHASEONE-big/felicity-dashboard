import XCTest
@testable import FelicityDashboard

final class WeatherModelsTests: XCTestCase {
    func testForecastURLRequestsSevenDaysInExplicitUnitsAndUnixTime() throws {
        let url = try WeatherService.forecastURL(for: location)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api.open-meteo.com")
        XCTAssertEqual(query["forecast_days"], "7")
        XCTAssertEqual(query["timezone"], "auto")
        XCTAssertEqual(query["timeformat"], "unixtime")
        XCTAssertEqual(query["temperature_unit"], "celsius")
        XCTAssertEqual(query["wind_speed_unit"], "kmh")
        XCTAssertEqual(query["latitude"], "40.4168")
        XCTAssertEqual(query["longitude"], "-3.7038")
        XCTAssertTrue(try XCTUnwrap(query["current"]).contains("is_day"))
        XCTAssertTrue(try XCTUnwrap(query["hourly"]).contains("is_day"))
        XCTAssertTrue(try XCTUnwrap(query["daily"]).contains("precipitation_probability_max"))
        XCTAssertNil(query["apikey"])
    }

    func testSearchURLPreservesUnicodeAndReservedCharactersAsOneQuery() throws {
        let name = "  L'Haÿ-les-Roses & Paris+France  "
        let url = WeatherService.searchURL(query: name)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(components.host, "geocoding-api.open-meteo.com")
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "L'Haÿ-les-Roses & Paris+France")
        XCTAssertEqual(items.first { $0.name == "count" }?.value, "5")
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testForecastURLRejectsInvalidCoordinates() {
        let invalid = WeatherLocation(id: "invalid", name: "Invalid", country: "", latitude: .nan, longitude: 0)
        XCTAssertThrowsError(try WeatherService.forecastURL(for: invalid))
        XCTAssertThrowsError(try WeatherService.forecastURL(for:
            WeatherLocation(id: "invalid", name: "Invalid", country: "", latitude: 91, longitude: 0)))
    }

    func testGeocodingSkipsInvalidRowsAndKeepsFiveValidResults() throws {
        var rows: [[String: Any]] = [
            ["id": 1, "name": "Broken", "latitude": NSNull(), "longitude": 0],
            ["id": 2, "name": "Outside Earth", "latitude": 91, "longitude": 0]
        ]
        rows += (10...16).map { ["id": $0, "name": "City \($0)", "country_code": "ES", "latitude": 40, "longitude": -3] }
        let result = try WeatherService.decodeLocations(data(["results": rows]))
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first?.id, "10")
        XCTAssertEqual(result.first?.country, "ES")
        XCTAssertNil(result.first?.timezone)
        XCTAssertEqual(try WeatherService.decodeLocations(data([:])), [])
    }

    func testCurrentUsesEpochTimeAndPreservesMissingOptionalValues() throws {
        let fetchedAt = Date(timeIntervalSince1970: 123)
        let result = try WeatherService.decodeForecast(data(baseResponse), fetchedAt: fetchedAt)
        XCTAssertEqual(result.current.date, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.current.temperature, 18.5)
        XCTAssertFalse(result.current.isDay)
        XCTAssertNil(result.current.apparentTemperature)
        XCTAssertNil(result.current.windSpeed)
        XCTAssertEqual(result.hourly, [])
        XCTAssertEqual(result.daily, [])
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testInvalidCurrentDoesNotProduceZeroWeather() throws {
        var response = baseResponse
        response["current"] = [:]
        XCTAssertThrowsError(try WeatherService.decodeForecast(data(response)))
        response["current"] = ["time": 1_800_000_000, "temperature_2m": true, "weather_code": 0, "is_day": 1]
        XCTAssertThrowsError(try WeatherService.decodeForecast(data(response)))
        response = baseResponse
        response["timezone"] = "Not/A_Time_Zone"
        XCTAssertThrowsError(try WeatherService.decodeForecast(data(response)))
    }

    func testHourlyNullAndShortArraysSkipRowsWithoutShiftingOptionalValues() throws {
        var response = baseResponse
        response["hourly"] = [
            "time": [1_800_000_000, 1_800_003_600, 1_800_007_200, 1_800_010_800, 1_800_014_400],
            "temperature_2m": [11, NSNull(), "invalid", 14, 15],
            "weather_code": [0, 1, 2, 3],
            "precipitation_probability": [NSNull(), 90, 80, 25],
            "wind_speed_10m": [7], "is_day": [0, 1, 1, 1]
        ] as [String: Any]
        let hours = try WeatherService.decodeForecast(data(response)).hourly
        XCTAssertEqual(hours.map(\.temperature), [11, 14])
        XCTAssertEqual(hours.map(\.date), [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_010_800)])
        XCTAssertNil(hours[0].precipitationProbability)
        XCTAssertEqual(hours[1].precipitationProbability, 25)
        XCTAssertEqual(hours[0].windSpeed, 7)
        XCTAssertNil(hours[1].windSpeed)
        XCTAssertEqual(hours.map(\.isDay), [false, true])
    }

    func testDailyRowsRequireBothTemperaturesAndNormalizeCivilDateAcrossDST() throws {
        var response = baseResponse
        let before = try date("2026-10-24T22:00:00Z")
        let after = try date("2026-10-25T22:00:00Z")
        response["utc_offset_seconds"] = 7200
        response["daily"] = [
            "time": [before.timeIntervalSince1970, after.timeIntervalSince1970, after.timeIntervalSince1970 + 86_400],
            "weather_code": [3, 0, 2], "temperature_2m_min": [8, 9, NSNull()],
            "temperature_2m_max": [18, 19, 20], "precipitation_probability_max": [12]
        ] as [String: Any]
        let days = try WeatherService.decodeForecast(data(response)).daily
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].date, before)
        XCTAssertEqual(days[1].date, try date("2026-10-25T23:00:00Z"))
        XCTAssertEqual(days[0].precipitationProbability, 12)
        XCTAssertNil(days[1].precipitationProbability)
    }

    func testTodayHoursUsesLocationDayIncludingTwentyThreeHourSpringDay() throws {
        let forecast = try fixture(start: "2026-03-28T22:00:00Z", count: 28)
        let today = forecast.todayHours(at: try date("2026-03-29T12:00:00Z"))
        XCTAssertEqual(today.count, 23)
        XCTAssertEqual(today.first?.date, try date("2026-03-28T23:00:00Z"))
        XCTAssertEqual(today.last?.date, try date("2026-03-29T21:00:00Z"))
    }

    func testTodayHoursRetainsBothRepeatedHoursOnTwentyFiveHourFallDay() throws {
        let forecast = try fixture(start: "2026-10-24T21:00:00Z", count: 28)
        let today = forecast.todayHours(at: try date("2026-10-25T12:00:00Z"))
        XCTAssertEqual(today.count, 25)
        XCTAssertEqual(today.first?.date, try date("2026-10-24T22:00:00Z"))
        XCTAssertEqual(today.last?.date, try date("2026-10-25T22:00:00Z"))
        XCTAssertEqual(Set(today.map(\.id)).count, 25)
    }

    func testSixHoursAheadSelectsNearestHourOnTheNextLocalDay() throws {
        let forecast = try fixture(start: "2026-11-16T22:00:00Z", count: 10)
        let now = try date("2026-11-16T22:40:00Z")
        let future = try XCTUnwrap(forecast.sixHoursAhead(from: now))
        XCTAssertEqual(future.date, try date("2026-11-17T05:00:00Z"))
        XCTAssertFalse(forecast.todayHours(at: now).contains(future))
    }

    func testSixHoursAheadUsesElapsedTimeAcrossBothDSTChanges() throws {
        for (start, expected) in [
            ("2026-03-28T23:00:00Z", "2026-03-29T05:00:00Z"),
            ("2026-10-24T22:00:00Z", "2026-10-25T04:00:00Z")
        ] {
            let forecast = try fixture(start: start, count: 10)
            let now = try date(start)
            let future = try XCTUnwrap(forecast.sixHoursAhead(from: now))
            XCTAssertEqual(future.date, try date(expected))
            XCTAssertEqual(future.date.timeIntervalSince(now), 6 * 3_600)
        }
    }

    func testSixHoursAheadRejectsAbsentDistantPastAndInvalidReadings() throws {
        let now = try date("2026-11-16T12:00:00Z")
        let current = WeatherCurrent(date: now, temperature: 12, code: 0, isDay: true)
        let missing = WeatherForecast(timezoneID: "Europe/Madrid", current: current, hourly: [], daily: [])
        XCTAssertNil(missing.sixHoursAhead(from: now))
        let unusable = WeatherForecast(timezoneID: "Europe/Madrid", current: current, hourly: [
            .init(date: now.addingTimeInterval(-3_600), temperature: 12, code: 0),
            .init(date: now.addingTimeInterval(7 * 3_600 + 1), temperature: 12, code: 0),
            .init(date: now.addingTimeInterval(6 * 3_600), temperature: .nan, code: 0)
        ], daily: [])
        XCTAssertNil(unusable.sixHoursAhead(from: now))
        let boundary = WeatherForecast(timezoneID: "Europe/Madrid", current: current, hourly: [
            .init(date: now.addingTimeInterval(5 * 3_600), temperature: 11, code: 0),
            .init(date: now.addingTimeInterval(7 * 3_600), temperature: 13, code: 0)
        ], daily: [])
        XCTAssertEqual(boundary.sixHoursAhead(from: now)?.temperature, 13)
    }

    func testConditionsDistinguishNightAndWeatherTypes() {
        XCTAssertEqual(WeatherCondition(code: 0, isDay: false).symbolName, "moon.stars.fill")
        XCTAssertEqual(WeatherCondition(code: 2, isDay: true).symbolName, "cloud.sun.fill")
        XCTAssertEqual(WeatherCondition(code: 45, isDay: true).symbolName, "cloud.fog.fill")
        XCTAssertEqual(WeatherCondition(code: 65, isDay: true).symbolName, "cloud.rain.fill")
        XCTAssertEqual(WeatherCondition(code: 73, isDay: true).symbolName, "cloud.snow.fill")
        XCTAssertEqual(WeatherCondition(code: 97, isDay: true).symbolName, "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherCondition(code: -1, isDay: true).description, "Weather unavailable")
    }

    func testForecastAndLocationRoundTripForOfflineCache() throws {
        let forecast = try WeatherService.decodeForecast(data(baseResponse), fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try JSONDecoder().decode(WeatherForecast.self, from: JSONEncoder().encode(forecast)), forecast)
        XCTAssertEqual(try JSONDecoder().decode(WeatherLocation.self, from: JSONEncoder().encode(location)), location)
    }

    private var location: WeatherLocation {
        WeatherLocation(id: "3117735", name: "Madrid", country: "Spain", latitude: 40.4168, longitude: -3.7038, timezone: "Europe/Madrid")
    }

    private var baseResponse: [String: Any] {
        ["timezone": "Europe/Madrid", "current": ["time": 1_800_000_000, "temperature_2m": 18.5, "weather_code": 2, "is_day": 0]]
    }

    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func date(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }

    private func fixture(start: String, count: Int) throws -> WeatherForecast {
        let start = try date(start)
        let hours = (0..<count).map { WeatherHour(date: start.addingTimeInterval(Double($0) * 3600), temperature: 12, code: 0) }
        return WeatherForecast(timezoneID: "Europe/Madrid",
            current: WeatherCurrent(date: start, temperature: 12, code: 0, isDay: true), hourly: hours, daily: [])
    }
}
