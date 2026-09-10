import Charts
import SwiftUI

enum FelicityPalette {
    static let background = Color(red: 7 / 255, green: 17 / 255, blue: 15 / 255)
    static let header = Color(red: 14 / 255, green: 48 / 255, blue: 43 / 255)
    static let card = Color(red: 13 / 255, green: 39 / 255, blue: 35 / 255)
    static let accent = Color(red: 89 / 255, green: 222 / 255, blue: 209 / 255)
    static let primary = Color(red: 232 / 255, green: 248 / 255, blue: 244 / 255)
    static let secondary = Color(red: 150 / 255, green: 190 / 255, blue: 184 / 255)
    static let live = Color(red: 98 / 255, green: 231 / 255, blue: 148 / 255)
    static let warning = Color(red: 1, green: 184 / 255, blue: 103 / 255)
}

struct AppRootView: View {
    @StateObject private var model = DashboardViewModel()
    @StateObject private var cameras = CameraRepository()
    @StateObject private var cameraPreferences = CameraPreferences()
    @State private var settingsPresented = false
    @State private var activeCamera: CameraDescriptor?
    @State private var eventsPresented = false
    @State private var selectedMetric: DashboardMetric?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let landscape = proxy.size.width >= proxy.size.height
                let compact = proxy.size.width < 900 || !landscape
                let columns = min(proxy.size.width, proxy.size.height) < 600 ? (landscape ? 2 : 1) : (landscape ? 3 : 2)
                let rows = Int(ceil(6.0 / Double(columns)))
                let cardHeight = max(154, (proxy.size.height - 68 - 28 - CGFloat(rows - 1) * 12) / CGFloat(rows))
                VStack(spacing: 0) {
                    HeaderView(
                        model: model,
                        selectedCamera: cameras.selected,
                        compact: compact,
                        settingsPresented: $settingsPresented,
                        cameraAction: {
                            if let camera = cameras.selected { activeCamera = camera }
                            else { settingsPresented = true }
                        },
                        eventsAction: {
                            if cameraPreferences.threeEyeConfiguration != nil { eventsPresented = true }
                            else { settingsPresented = true }
                        }
                    )
                    ScrollView {
                        DashboardGrid(snapshot: model.snapshot, columns: columns, minimumCardHeight: cardHeight) { selectedMetric = $0 }
                            .padding(14)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .background(FelicityPalette.background.ignoresSafeArea())
                .overlay {
                    if !model.isLive && model.snapshot.updatedAt == nil {
                        NoDataView(message: model.error)
                    }
                }
            }
        }
        .tint(FelicityPalette.accent)
        .task {
            await runArchiveSelfTestIfRequested()
            await model.run()
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(model: model, cameras: cameras, cameraPreferences: cameraPreferences)
                .presentationDetents([.large])
        }
        .fullScreenCover(item: $activeCamera) { camera in
            LiveCameraView(camera: camera, repository: cameras, preferences: cameraPreferences)
        }
        .fullScreenCover(isPresented: $eventsPresented) {
            if let configuration = cameraPreferences.threeEyeConfiguration {
                EventsView(configuration: configuration, cameraName: cameras.selected?.name, backLabel: "ENERGY", repository: cameras, preferences: cameraPreferences)
            }
        }
        .fullScreenCover(item: $selectedMetric) { metric in
            EnergyDetailView(metric: metric, model: model)
        }
    }

    @MainActor
    private func runArchiveSelfTestIfRequested() async {
        guard ProcessInfo.processInfo.environment["FELICITY_ARCHIVE_SELFTEST"] == "1" else { return }
        if cameras.selected == nil {
            await cameras.discover(using: cameraPreferences.recorderConfiguration)
        }
        guard let camera = cameras.selected else {
            archiveSelfTestTrace("FAIL no camera: \(cameras.error)")
            return
        }
        let probe = ArchiveSelfTestProbe()
        let session = ArchiveRTSPSession()
        do {
            var target = Date().addingTimeInterval(-60)
            if let threeEye = cameraPreferences.threeEyeConfiguration,
               let events = try? await ThreeEyeAPI().events(
                configuration: threeEye,
                camera: camera.name,
                classes: Set(ThreeEyeEventClass.allCases),
                limit: 4
               ), let captured = events.first?.capturedAt {
                target = captured
            }
            let quality = cameras.preferredQuality(for: camera, compactDisplay: false)
            let descriptor = try await ProfileGArchiveService.shared.replay(
                camera: camera,
                quality: quality,
                configuration: cameraPreferences.recorderConfiguration
            )
            let format = try await session.open(
                descriptor: descriptor,
                configuration: cameraPreferences.recorderConfiguration,
                fallbackSize: camera.encodedSize(for: quality),
                onFrame: { unit, _ in probe.accept(unit) },
                onStatistics: { _ in },
                onState: { value in probe.accept(value) }
            )
            archiveSelfTestTrace("OPEN camera=\(camera.name) format=\(format.width)x\(format.height) \(format.codecName) target=\(target.timeIntervalSince1970)")
            try await session.seek(to: target, autoplay: false, frameGeneration: 1)
            try? await Task.sleep(for: .seconds(5))
            let paused = probe.snapshot
            archiveSelfTestTrace("PAUSED \(paused.summary)")
            guard paused.frames > 0, paused.keyframes > 0, paused.state == .paused else {
                throw ArchiveSelfTestError.noPausedKeyframe
            }
            try await session.seek(to: target, autoplay: true, frameGeneration: 2)
            try? await Task.sleep(for: .seconds(3))
            let playing = probe.snapshot
            archiveSelfTestTrace("PLAYING \(playing.summary)")
            guard playing.frames > paused.frames, playing.state == .playing else {
                throw ArchiveSelfTestError.noPlayback
            }
            await session.pause()
            await session.close()
            archiveSelfTestTrace("PASS")
        } catch {
            await session.close()
            archiveSelfTestTrace("FAIL \(error.localizedDescription)")
        }
    }
}

private func archiveSelfTestTrace(_ message: String) {
    guard let data = "[Felicity ArchiveSelfTest] \(message)\n".data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

private final class ArchiveSelfTestProbe: @unchecked Sendable {
    struct Snapshot: Sendable {
        let frames: Int
        let keyframes: Int
        let firstTime: Date?
        let lastTime: Date?
        let state: ArchivePlaybackState

        var summary: String {
            "state=\(state) frames=\(frames) keyframes=\(keyframes) first=\(firstTime?.timeIntervalSince1970 ?? 0) last=\(lastTime?.timeIntervalSince1970 ?? 0)"
        }
    }

    private var frames = 0
    private var keyframes = 0
    private var firstTime: Date?
    private var lastTime: Date?
    private var state: ArchivePlaybackState = .idle
    private let lock = NSLock()

    func accept(_ unit: VideoAccessUnit) {
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        if unit.isKeyframe { keyframes += 1 }
        if firstTime == nil { firstTime = unit.archiveTime }
        lastTime = unit.archiveTime ?? lastTime
    }

    func accept(_ value: ArchivePlaybackState) {
        lock.lock()
        state = value
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(frames: frames, keyframes: keyframes, firstTime: firstTime, lastTime: lastTime, state: state)
    }
}

private enum ArchiveSelfTestError: LocalizedError {
    case noPausedKeyframe
    case noPlayback

    var errorDescription: String? {
        switch self {
        case .noPausedKeyframe: return "Archive did not deliver a paused keyframe"
        case .noPlayback: return "Archive did not advance during playback"
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: DashboardViewModel
    let selectedCamera: CameraDescriptor?
    let compact: Bool
    @Binding var settingsPresented: Bool
    let cameraAction: () -> Void
    let eventsAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button { settingsPresented = true } label: {
                Text("☯")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(FelicityPalette.accent)
                    .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)
            Text("v0.4.7 · iOS")
                .font(.headline.monospaced())
                .foregroundStyle(FelicityPalette.accent)
            Spacer()
            Button(action: cameraAction) {
                if compact {
                    Image(systemName: selectedCamera == nil ? "video.slash" : "video.fill")
                        .font(.headline)
                        .frame(width: 44, height: 42)
                } else {
                    Label(selectedCamera?.name ?? "SET UP CAMERAS", systemImage: selectedCamera == nil ? "video.slash" : "video.fill")
                        .font(.headline)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 42)
                }
            }
            .buttonStyle(HomeHeaderButtonStyle())
            Button(action: eventsAction) {
                if compact {
                    Image(systemName: "rectangle.stack.badge.person.crop")
                        .font(.headline)
                        .frame(width: 44, height: 42)
                } else {
                    Label("EVENTS", systemImage: "rectangle.stack.badge.person.crop")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 42)
                }
            }
            .buttonStyle(HomeHeaderButtonStyle())
            Text(model.isLive ? "LIVE" : "NO DATA")
                .font((compact ? Font.subheadline : Font.headline).bold())
                .foregroundStyle(model.isLive ? FelicityPalette.live : FelicityPalette.warning)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Group {
                    if compact {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(context.date, format: .dateTime.day().month().year())
                            Text(context.date, format: .dateTime.hour().minute().second())
                        }
                    } else {
                        HStack(spacing: 18) {
                            Text(context.date, format: .dateTime.day().month().year())
                            Text(context.date, format: .dateTime.hour().minute().second())
                        }
                    }
                }
                .font((compact ? Font.subheadline : Font.title2).bold().monospacedDigit())
                .foregroundStyle(FelicityPalette.primary)
            }
        }
        .padding(.horizontal, compact ? 12 : 18)
        .frame(minHeight: 68)
        .background(FelicityPalette.header)
    }
}

private struct HomeHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(configuration.isPressed ? FelicityPalette.accent.opacity(0.35) : .black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct DashboardGrid: View {
    let snapshot: DashboardSnapshot
    let columns: Int
    let minimumCardHeight: CGFloat
    let onSelect: (DashboardMetric) -> Void

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            MetricCard(title: "SOLAR", value: watts(snapshot.solar), detail: "PV1 \(number(snapshot.solar1, 0)) · PV2 \(number(snapshot.solar2, 0))", minimumHeight: minimumCardHeight) { onSelect(.solar) }
            MetricCard(title: "HOME LOAD", value: watts(snapshot.load), detail: "\(number(snapshot.load1, 0)) · \(number(snapshot.load2, 0)) · \(number(snapshot.load3, 0))", minimumHeight: minimumCardHeight) { onSelect(.load) }
            MetricCard(title: "BATTERY", value: "\(number(snapshot.batteryPercent, 0))%", detail: "\(number(snapshot.batteryVoltage, 1)) V · \(signed(snapshot.batteryPower)) W", minimumHeight: minimumCardHeight) { onSelect(.battery) }
            MetricCard(title: "GRID", value: "\(number(snapshot.gridVoltage, 1)) V", detail: "\(signed(snapshot.gridPower)) W · \(number(snapshot.gridFrequency, 1)) Hz", minimumHeight: minimumCardHeight) { onSelect(.grid) }
            MetricCard(title: "SYSTEM", value: "\(number(snapshot.cpu, 0))%", detail: "RAM \(number(snapshot.memory, 0)) · TEMP \(number(snapshot.temperature, 0)) · DISK \(number(snapshot.disk, 0))", minimumHeight: minimumCardHeight) { onSelect(.system) }
            MetricCard(title: "TODAY", value: "\(number(snapshot.todaySolar, 2)) kWh", detail: "LOAD \(number(snapshot.todayLoad, 2)) · COVER \(number(snapshot.coverage, 0))%", minimumHeight: minimumCardHeight) { onSelect(.today) }
        }
    }

    private func watts(_ value: Double) -> String { "\(number(value, 0)) W" }
    private func signed(_ value: Double) -> String { "\(value > 0 ? "+" : value < 0 ? "−" : "")\(number(abs(value), 0))" }
    private func number(_ value: Double, _ decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic))
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let minimumHeight: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title)
                    .font(.headline.bold())
                    .foregroundStyle(FelicityPalette.accent)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .foregroundStyle(FelicityPalette.primary)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.title3)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .foregroundStyle(FelicityPalette.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .background(
                LinearGradient(colors: [FelicityPalette.card, FelicityPalette.background.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(FelicityPalette.accent.opacity(0.48), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

private struct EnergyDetailView: View {
    let metric: DashboardMetric
    @ObservedObject var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let compactSummary = proxy.size.width < 620
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { Label("ENERGY", systemImage: "chevron.left") }
                        .buttonStyle(HomeHeaderButtonStyle())
                    Text(metric.title)
                        .font(.title2.bold())
                        .foregroundStyle(FelicityPalette.accent)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 68)
                .background(FelicityPalette.header)

                VStack(spacing: 14) {
                    if compactSummary {
                        VStack(spacing: 10) {
                            primaryFact
                                .frame(height: 92)
                            facts
                                .frame(height: 96)
                        }
                    } else {
                        HStack(spacing: 14) {
                            primaryFact
                                .frame(width: min(300, proxy.size.width * 0.25))
                            facts
                        }
                        .frame(height: min(142, max(116, proxy.size.height * 0.2)))
                    }
                    EnergyChartView(metric: metric, chart: model.chart, loading: model.isLoadingChart, error: model.chartError)
                }
                .padding(16)
            }
            .background(FelicityPalette.background.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task(id: metric) {
            model.clearChart()
            while !Task.isCancelled {
                await model.refreshChart(metric)
                try? await Task.sleep(for: metric == .system ? .seconds(10) : .seconds(60))
            }
        }
    }

    private var primaryFact: some View {
        VStack(spacing: 8) {
            Text("CURRENT")
                .font(.caption.bold())
                .foregroundStyle(FelicityPalette.accent)
            Text(primaryValue)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .foregroundStyle(FelicityPalette.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FelicityPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(FelicityPalette.accent.opacity(0.48), lineWidth: 1.5))
    }

    private var facts: some View {
        let values = detailFacts
        return HStack(spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, fact in
                VStack(spacing: 8) {
                    Text(fact.0).font(.caption.bold()).foregroundStyle(FelicityPalette.secondary)
                    Text(fact.1).font(.title3.bold().monospacedDigit()).minimumScaleFactor(0.55).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FelicityPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(FelicityPalette.accent.opacity(0.28)))
            }
        }
        .foregroundStyle(FelicityPalette.primary)
    }

    private var primaryValue: String {
        let s = model.snapshot
        switch metric {
        case .solar: return "\(n(s.solar, 0)) W"
        case .load: return "\(n(s.load, 0)) W"
        case .battery: return "\(n(s.batteryPercent, 0))%"
        case .grid: return "\(n(s.gridVoltage, 1)) V"
        case .system: return "\(n(s.cpu, 1))% CPU"
        case .today: return "\(n(s.todaySolar, 2)) kWh"
        }
    }

    private var detailFacts: [(String, String)] {
        let s = model.snapshot
        switch metric {
        case .solar: return [("PV1", "\(n(s.solar1, 0)) W"), ("PV2", "\(n(s.solar2, 0)) W"), ("MPPT", "\(n(s.mppt1, 0)) / \(n(s.mppt2, 0)) V")]
        case .load: return [("L1", "\(n(s.load1, 0)) W"), ("L2", "\(n(s.load2, 0)) W"), ("L3", "\(n(s.load3, 0)) W")]
        case .battery: return [("VOLTAGE", "\(n(s.batteryVoltage, 1)) V"), ("POWER", "\(signed(s.batteryPower)) W"), ("BMS SOC", "\(n(s.bms1, 0)) / \(n(s.bms2, 0))%")]
        case .grid: return [("L1", "\(n(s.gridVoltage1, 1)) V"), ("L2", "\(n(s.gridVoltage2, 1)) V"), ("L3", "\(n(s.gridVoltage3, 1)) V")]
        case .system: return [("RAM", "\(n(s.memory, 1))%"), ("TEMP", "\(n(s.temperature, 1)) °C"), ("DISK", "\(n(s.disk, 1))%")]
        case .today: return [("LOAD", "\(n(s.todayLoad, 2)) kWh"), ("COVER", "\(n(s.coverage, 1))%"), ("GRID IN", "\(n(s.gridImport, 2)) kWh")]
        }
    }

    private func n(_ value: Double, _ decimals: Int) -> String { value.formatted(.number.precision(.fractionLength(decimals)).grouping(.automatic)) }
    private func signed(_ value: Double) -> String { "\(value > 0 ? "+" : value < 0 ? "−" : "")\(n(abs(value), 0))" }
}

private struct EnergyChartView: View {
    let metric: DashboardMetric
    let chart: DashboardChart
    let loading: Bool
    let error: String
    private let colors: [Color] = [FelicityPalette.accent, .orange, Color(red: 0.45, green: 0.67, blue: 1), Color(red: 0.77, green: 0.54, blue: 1)]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color(red: 9 / 255, green: 29 / 255, blue: 26 / 255))
            if chart.samples.isEmpty {
                VStack(spacing: 10) {
                    if loading { ProgressView() }
                    Text(error.isEmpty ? "Loading chart…" : error)
                        .font(.headline)
                        .foregroundStyle(error.isEmpty ? FelicityPalette.secondary : .orange)
                }
            } else {
                Chart {
                    ForEach(0..<min(4, max(1, chart.channels)), id: \.self) { channel in
                        ForEach(Array(chart.samples.enumerated()), id: \.offset) { index, row in
                            if let row, channel < row.count {
                                LineMark(x: .value("Time", index), y: .value("Value", row[channel]))
                                    .foregroundStyle(by: .value("Series", "S\(channel)"))
                                    .lineStyle(StrokeStyle(lineWidth: channel == 0 ? 3 : 1.8, lineJoin: .round))
                            }
                        }
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(FelicityPalette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.4))
                        .annotation(position: .leading, alignment: .center) {
                            Text("0").font(.headline.bold()).foregroundStyle(FelicityPalette.accent)
                        }
                }
                .chartYScale(domain: yDomain)
                .chartForegroundStyleScale(
                    domain: ["S0", "S1", "S2", "S3"],
                    range: colors
                )
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(FelicityPalette.secondary.opacity(0.26))
                        AxisValueLabel().font(.subheadline.bold()).foregroundStyle(FelicityPalette.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: xTicks) { value in
                        AxisGridLine().foregroundStyle(FelicityPalette.secondary.opacity(0.22))
                        AxisValueLabel {
                            if let index = value.as(Int.self) { Text(xLabel(index)).font(.subheadline.bold()) }
                        }
                    }
                }
                .chartPlotStyle { plot in plot.border(FelicityPalette.secondary.opacity(0.42), width: 1.2) }
                .overlay(alignment: .topTrailing) {
                    Text(metric.unit)
                        .font(.subheadline.bold())
                        .foregroundStyle(FelicityPalette.accent)
                        .padding(.top, 8)
                        .padding(.trailing, 20)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var values: [Double] { chart.samples.flatMap { $0 ?? [] } }
    private var yDomain: ClosedRange<Double> {
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        if minimum >= 0 { return 0...max(1, maximum * 1.08) }
        let low = minimum - max(1, (maximum - minimum) * 0.08)
        let high = max(0, maximum) + max(1, (maximum - minimum) * 0.08)
        return low...max(low + 1, high)
    }
    private var xTicks: [Int] {
        let last = max(0, chart.samples.count - 1)
        return Array(Set([0, last / 2, last])).sorted()
    }
    private func xLabel(_ index: Int) -> String {
        let last = max(1, chart.samples.count - 1)
        let fraction = Double(index) / Double(last)
        if metric == .system { return fraction < 0.25 ? "−10m" : fraction > 0.75 ? "NOW" : "−5m" }
        let hour = Int((fraction * 24).rounded())
        return String(format: "%02d:00", hour)
    }
}

private struct NoDataView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 38, weight: .medium))
            Text("NO DATA")
                .font(.title.bold())
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(FelicityPalette.primary.opacity(0.78))
        }
        .foregroundStyle(FelicityPalette.warning)
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(FelicityPalette.warning.opacity(0.45)))
        .shadow(color: .black.opacity(0.55), radius: 24)
        .padding(30)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: DashboardViewModel
    @ObservedObject var cameras: CameraRepository
    @ObservedObject var cameraPreferences: CameraPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Felicity server") {
                    TextField("http://homeassistant.local:8000", text: $model.serverText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("ONVIF recorder · Profile G") {
                    TextField("192.168.13.234:8080", text: $cameraPreferences.recorderHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ONVIF username", text: $cameraPreferences.recorderUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("ONVIF password", text: $cameraPreferences.recorderPassword)
                    Button {
                        cameraPreferences.save()
                        Task { await cameras.discover(using: cameraPreferences.recorderConfiguration) }
                    } label: {
                        HStack {
                            Label(cameras.cameras.isEmpty ? "Discover cameras" : "Refresh camera catalogue", systemImage: "arrow.triangle.2.circlepath.camera")
                            Spacer()
                            if cameras.isDiscovering { ProgressView() }
                        }
                    }
                    .disabled(cameras.isDiscovering)
                    if !cameras.error.isEmpty {
                        Text(cameras.error)
                            .foregroundStyle(.orange)
                    } else if !cameras.cameras.isEmpty {
                        LabeledContent("Cameras", value: cameras.cameras.count.formatted())
                    }
                }
                Section("3ye events") {
                    TextField("http://192.168.13.148:8765", text: $cameraPreferences.threeEyeURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("3ye username", text: $cameraPreferences.threeEyeUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("3ye password", text: $cameraPreferences.threeEyePassword)
                    Text("Used for the native Events view. This build does not send push notifications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Client", value: "iOS 0.4.7")
                    LabeledContent("Server", value: model.status.version)
                    LabeledContent("Connection", value: model.isLive ? "Live" : "Offline")
                    if !cameraPreferences.saveError.isEmpty {
                        LabeledContent("Keychain", value: cameraPreferences.saveError)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.saveServer()
                        cameraPreferences.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
