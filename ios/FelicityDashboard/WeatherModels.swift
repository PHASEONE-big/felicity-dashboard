import Foundation

struct WeatherLocation: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let country: String
    let latitude: Double
    let longitude: Double
    var timezone: String? = nil
}

struct WeatherCurrent: Codable, Equatable, Sendable {
    let date: Date
    let temperature: Double
    var apparentTemperature: Double? = nil
    let code: Int
    let isDay: Bool
    var windSpeed: Double? = nil
    var cloudCover: Double? = nil
    var humidity: Double? = nil
    var precipitation: Double? = nil
    var rain: Double? = nil

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

struct WeatherHour: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    let temperature: Double
    let code: Int
    var precipitationProbability: Double? = nil
    var windSpeed: Double? = nil
    var apparentTemperature: Double? = nil
    var cloudCover: Double? = nil
    var isDay: Bool? = nil
    var id: Date { date }
}

struct WeatherDay: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    let code: Int
    let minimumTemperature: Double
    let maximumTemperature: Double
    var precipitationProbability: Double? = nil
    var id: Date { date }
}

struct WeatherForecast: Codable, Equatable, Sendable {
    let timezoneID: String
    let current: WeatherCurrent
    let hourly: [WeatherHour]
    let daily: [WeatherDay]
    var fetchedAt: Date = .now

    var timeZone: TimeZone { TimeZone(identifier: timezoneID) ?? TimeZone(secondsFromGMT: 0)! }

    /// Calendar boundaries, rather than a fixed 24-hour range, retain both
    /// repeated fall-back hours and omit the missing spring-forward hour.
    func todayHours(at now: Date) -> [WeatherHour] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        return hourly.filter { $0.date >= day.start && $0.date < day.end }
    }
}

struct WeatherCondition: Equatable, Sendable {
    let code: Int
    let isDay: Bool

    var symbolName: String {
        switch code {
        case 0, 1: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 65, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 97, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }

    var description: String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75, 77: return "Snow"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95, 97: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Weather unavailable"
        }
    }
}
