import Foundation

struct ServerStatus: Equatable, Sendable {
    var online = false
    var version = "—"
}

enum DashboardMetric: String, CaseIterable, Identifiable, Sendable {
    case solar = "pv"
    case load
    case battery
    case grid
    case system
    case today

    var id: String { rawValue }
    var title: String {
        switch self {
        case .solar: return "SOLAR"
        case .load: return "HOME LOAD"
        case .battery: return "BATTERY"
        case .grid: return "GRID"
        case .system: return "SYSTEM"
        case .today: return "TODAY"
        }
    }
    var unit: String {
        switch self {
        case .solar, .load, .today: return "POWER · W"
        case .battery: return "SOC % / POWER W"
        case .grid: return "VOLTAGE V / POWER W"
        case .system: return "SYSTEM · % / °C"
        }
    }

    var chartPanels: [EnergyChartPanel] {
        switch self {
        case .solar:
            return [.init(id: "solar-power", title: "Solar power", unit: "W", series: [
                .init(id: 0, name: "Total"), .init(id: 1, name: "PV1"), .init(id: 2, name: "PV2")
            ])]
        case .load:
            return [.init(id: "load-power", title: "Home load", unit: "W", series: [
                .init(id: 0, name: "Total"), .init(id: 1, name: "L1"), .init(id: 2, name: "L2"), .init(id: 3, name: "L3")
            ])]
        case .battery:
            return [
                .init(id: "battery-soc", title: "State of charge", unit: "%", series: [.init(id: 0, name: "Battery")]),
                .init(id: "battery-power", title: "Battery power", unit: "W", series: [.init(id: 1, name: "Battery")])
            ]
        case .grid:
            return [
                .init(id: "grid-voltage", title: "Grid voltage", unit: "V", series: [
                    .init(id: 0, name: "L1"), .init(id: 1, name: "L2"), .init(id: 2, name: "L3")
                ]),
                .init(id: "grid-power", title: "Grid power", unit: "W", series: [.init(id: 3, name: "Grid")])
            ]
        case .system:
            return [
                .init(id: "system-usage", title: "Resource usage", unit: "%", series: [
                    .init(id: 0, name: "CPU"), .init(id: 1, name: "RAM"), .init(id: 3, name: "Disk")
                ]),
                .init(id: "system-temperature", title: "CPU temperature", unit: "°C", series: [.init(id: 2, name: "Temperature")])
            ]
        case .today:
            return [.init(id: "today-power", title: "Today's power", unit: "W", series: [
                .init(id: 0, name: "Solar"), .init(id: 1, name: "Load")
            ])]
        }
    }
}

struct EnergyChartSeries: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
}

struct EnergyChartPanel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let unit: String
    let series: [EnergyChartSeries]
}

struct EnergyChartPoint: Identifiable, Equatable, Sendable {
    let id: Int
    let value: Double
    var x: Double { Double(id) }
}

struct DashboardChart: Equatable, Sendable {
    var samples: [[Double]?] = []
    var channels = 0
    var start: Date?
    var end: Date?
    var intervalMinutes: Double?
    var intervalSeconds: Double?
    var metric: DashboardMetric?

    static func decode(_ data: Data) throws -> Self {
        let response = try JSONDecoder().decode(ChartResponse.self, from: data)
        return .init(samples: response.samples, channels: max(0, response.channels),
                     start: parseDate(response.start), end: parseDate(response.end),
                     intervalMinutes: positiveInterval(response.intervalMinutes),
                     intervalSeconds: positiveInterval(response.intervalSeconds),
                     metric: response.metric.flatMap(DashboardMetric.init(rawValue:)))
    }

    /// Keep original bucket indices and gaps; never join across missing readings.
    func segments(channel: Int) -> [[EnergyChartPoint]] {
        guard channel >= 0, channel < channels else { return [] }
        var result: [[EnergyChartPoint]] = []
        var segment: [EnergyChartPoint] = []
        for (index, row) in samples.enumerated() {
            if let row, channel < row.count, row[channel].isFinite {
                segment.append(.init(id: index, value: row[channel]))
            } else if !segment.isEmpty {
                result.append(segment)
                segment = []
            }
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }

    /// Scale only visible channels. Preserve sign and keep a useful finite range
    /// for empty/flat data, without letting another unit dominate this panel.
    func domain(channels selected: [Int], includeZero: Bool = true) -> ClosedRange<Double> {
        let selected = Set(selected.filter { $0 >= 0 && $0 < channels })
        var lower = Double.infinity
        var upper = -Double.infinity
        for row in samples.compactMap({ $0 }) {
            for channel in selected where channel < row.count && row[channel].isFinite {
                lower = min(lower, row[channel])
                upper = max(upper, row[channel])
            }
        }
        guard lower.isFinite, upper.isFinite else { return 0...1 }
        if includeZero {
            lower = min(lower, 0)
            upper = max(upper, 0)
        }
        if lower == upper {
            if includeZero { return 0...1 } // All observed values are zero.
            let padding = max(1, abs(lower) * 0.05)
            let paddedLower = lower - padding
            let paddedUpper = upper + padding
            return (paddedLower.isFinite ? paddedLower : lower)...(paddedUpper.isFinite ? paddedUpper : upper)
        }
        // Compute the span in halves to avoid overflow for extreme finite values.
        let padding = (upper * 0.5 - lower * 0.5) * 0.1
        let paddedLower = includeZero && lower == 0 ? lower : lower - padding
        let paddedUpper = includeZero && upper == 0 ? upper : upper + padding
        return (paddedLower.isFinite ? paddedLower : lower)...(paddedUpper.isFinite ? paddedUpper : upper)
    }

    /// Server bins cover [start, end), so the final bucket begins before end.
    /// Missing metadata yields nil: the view should show bucket indices instead
    /// of inventing a day-long range for the ten-minute System chart.
    func date(at index: Int, metric: DashboardMetric) -> Date? {
        guard samples.indices.contains(index), let start, start.timeIntervalSince1970.isFinite else { return nil }
        let interval: TimeInterval
        if let end, end.timeIntervalSince1970.isFinite, end > start {
            interval = end.timeIntervalSince(start) / Double(samples.count)
        } else if let seconds = Self.positiveInterval(intervalSeconds) {
            interval = seconds
        } else if let minutes = Self.positiveInterval(intervalMinutes) {
            interval = minutes * 60
        } else { return nil }
        let offset = Double(index) * interval
        guard interval.isFinite, offset.isFinite else { return nil }
        let date = start.addingTimeInterval(offset)
        return date.timeIntervalSince1970.isFinite ? date : nil
    }

    private static func positiveInterval(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Python's isoformat emits offsets and optional fractional seconds.
        // Older offset-free payloads are interpreted as UTC deterministically.
        let hasZone = text.range(of: "(?:[zZ]|[+-][0-9]{2}:?[0-9]{2})$", options: .regularExpression) != nil
        let normalized = hasZone ? text : text + "Z"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }
}

struct DashboardSnapshot: Equatable, Sendable {
    var solar = 0.0
    var solar1 = 0.0
    var solar2 = 0.0
    var mppt1 = 0.0
    var mppt2 = 0.0
    var load = 0.0
    var load1 = 0.0
    var load2 = 0.0
    var load3 = 0.0
    var batteryPercent = 0.0
    var batteryVoltage = 0.0
    var batteryPower = 0.0
    var bms1 = 0.0
    var bms2 = 0.0
    var gridVoltage = 0.0
    var gridVoltage1 = 0.0
    var gridVoltage2 = 0.0
    var gridVoltage3 = 0.0
    var gridPower = 0.0
    var gridFrequency = 0.0
    var cpu = 0.0
    var memory = 0.0
    var temperature = 0.0
    var disk = 0.0
    var todaySolar = 0.0
    var todayLoad = 0.0
    var coverage = 0.0
    var gridImport = 0.0
    var gridExport = 0.0
    var updatedAt: Date?

    static func applyingCurrent(_ data: Data, to previous: Self = .init()) throws -> Self {
        let response = try JSONDecoder().decode(CurrentResponse.self, from: data)
        let parsed = response.parsed
        var value = previous
        value.solar = parsed.pvPower?.total ?? 0
        value.solar1 = parsed.pvPower?.pv1 ?? 0
        value.solar2 = parsed.pvPower?.pv2 ?? 0
        value.mppt1 = parsed.pvVoltage?.mppt1 ?? 0
        value.mppt2 = parsed.pvVoltage?.mppt2 ?? 0
        value.load = parsed.loadPower?.total ?? 0
        value.load1 = parsed.loadPower?.l1 ?? 0
        value.load2 = parsed.loadPower?.l2 ?? 0
        value.load3 = parsed.loadPower?.l3 ?? 0
        value.batteryPercent = parsed.socPercent ?? 0
        value.batteryVoltage = parsed.batteryVoltage ?? 0
        value.batteryPower = parsed.batteryPower ?? 0
        value.bms1 = parsed.batteries?.first?.socPercent ?? 0
        value.bms2 = parsed.batteries?.dropFirst().first?.socPercent ?? 0
        let voltages = [parsed.gridVoltage?.l1, parsed.gridVoltage?.l2, parsed.gridVoltage?.l3].compactMap { $0 }
        value.gridVoltage = voltages.isEmpty ? 0 : voltages.reduce(0, +) / Double(voltages.count)
        value.gridVoltage1 = parsed.gridVoltage?.l1 ?? 0
        value.gridVoltage2 = parsed.gridVoltage?.l2 ?? 0
        value.gridVoltage3 = parsed.gridVoltage?.l3 ?? 0
        value.gridPower = parsed.gridPower?.total ?? 0
        value.gridFrequency = parsed.gridFrequency ?? 0
        value.updatedAt = Date()
        return value
    }

    static func applyingSummary(_ data: Data, to previous: Self = .init()) throws -> Self {
        let response = try JSONDecoder().decode(SummaryResponse.self, from: data)
        var value = previous
        value.cpu = response.system.cpu ?? 0
        value.memory = response.system.memory ?? 0
        value.temperature = response.system.temperature ?? 0
        value.disk = response.system.disk ?? 0
        value.todaySolar = response.today.solar ?? 0
        value.todayLoad = response.today.load ?? 0
        value.coverage = response.today.coverage ?? 0
        value.gridImport = response.today.gridImport ?? 0
        value.gridExport = response.today.gridExport ?? 0
        return value
    }
}

private struct CurrentResponse: Decodable {
    let parsed: Parsed
}

private struct Parsed: Decodable {
    let pvPower: PhaseValues?
    let loadPower: PhaseValues?
    let pvVoltage: PhaseValues?
    let gridVoltage: PhaseValues?
    let gridPower: PhaseValues?
    let socPercent: Double?
    let batteryVoltage: Double?
    let batteryPower: Double?
    let gridFrequency: Double?
    let batteries: [BatteryValues]?

    enum CodingKeys: String, CodingKey {
        case pvPower = "pv_power_w"
        case loadPower = "load_power_w"
        case pvVoltage = "pv_voltage_v"
        case gridVoltage = "grid_voltage_v"
        case gridPower = "grid_power_w"
        case socPercent = "soc_percent"
        case batteryVoltage = "battery_voltage_v"
        case batteryPower = "battery_power_w"
        case gridFrequency = "grid_frequency_hz"
        case batteries
    }
}

private struct PhaseValues: Decodable {
    let total: Double?
    let pv1: Double?
    let pv2: Double?
    let l1: Double?
    let l2: Double?
    let l3: Double?
    let mppt1: Double?
    let mppt2: Double?
}

private struct BatteryValues: Decodable {
    let socPercent: Double?
    enum CodingKeys: String, CodingKey { case socPercent = "soc_percent" }
}

private struct SummaryResponse: Decodable {
    let system: SystemValues
    let today: TodayValues
}

private struct SystemValues: Decodable {
    let cpu: Double?
    let memory: Double?
    let temperature: Double?
    let disk: Double?

    enum CodingKeys: String, CodingKey {
        case cpu = "cpu_percent"
        case memory = "memory_percent"
        case temperature = "temperature_c"
        case disk = "disk_percent"
    }
}

private struct TodayValues: Decodable {
    let solar: Double?
    let load: Double?
    let coverage: Double?
    let gridImport: Double?
    let gridExport: Double?

    enum CodingKeys: String, CodingKey {
        case solar = "pv_kwh"
        case load = "load_kwh"
        case coverage = "coverage_percent"
        case gridImport = "grid_import_kwh"
        case gridExport = "grid_export_kwh"
    }
}

private struct ChartResponse: Decodable {
    let samples: [[Double]?]
    let channels: Int
    let start: String?
    let end: String?
    let intervalMinutes: Double?
    let intervalSeconds: Double?
    let metric: String?

    enum CodingKeys: String, CodingKey {
        case samples, channels, start, end, metric
        case intervalMinutes = "interval_minutes"
        case intervalSeconds = "interval_seconds"
    }
}
