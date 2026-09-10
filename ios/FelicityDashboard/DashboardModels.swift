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
}

struct DashboardChart: Equatable, Sendable {
    var samples: [[Double]?] = []
    var channels = 0

    static func decode(_ data: Data) throws -> Self {
        let response = try JSONDecoder().decode(ChartResponse.self, from: data)
        return .init(samples: response.samples, channels: max(0, response.channels))
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
}
