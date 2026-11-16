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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = DashboardViewModel()
    @StateObject private var cameras = CameraRepository()
    @StateObject private var cameraPreferences = CameraPreferences()
    @StateObject private var kiosk = KioskController()
    @StateObject private var doorbell = DoorbellController()
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
                let cardHeight = min(landscape ? 340 : 250, max(170, (proxy.size.height - 68 - 28 - CGFloat(rows - 1) * 12) / CGFloat(rows)))
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
        .background(KioskScreenReader(attach: { kiosk.attach(screen: $0) }, activity: { kiosk.recordActivity() }).allowsHitTesting(false))
        .background(DoorbellOverlayHost(controller: doorbell, repository: cameras, preferences: cameraPreferences).allowsHitTesting(false))
        .overlay {
            if kiosk.isSleeping {
                KioskClockView(isNight: kiosk.isNight, load: model.snapshot.load, updatedAt: model.snapshot.updatedAt, online: model.status.online) { kiosk.recordActivity() }
            }
        }
        .statusBarHidden(kiosk.isSleeping)
        .task {
            kiosk.setContext(active: scenePhase == .active, dashboardVisible: isDashboardVisible)
            await kiosk.run()
        }
        .onChange(of: scenePhase) { phase in
            kiosk.setContext(active: phase == .active, dashboardVisible: isDashboardVisible)
            doorbell.setActive(phase != .background)
        }
        .onChange(of: isDashboardVisible) { visible in
            kiosk.setContext(active: scenePhase == .active, dashboardVisible: visible)
        }
        .onChange(of: doorbell.isPresenting) { presenting in
            guard presenting else { return }
            // Pause the previous camera/archive/chart route while the doorbell
            // owns video, rather than decoding a second hidden stream.
            activeCamera = nil
            eventsPresented = false
            selectedMetric = nil
            settingsPresented = false
        }
        .task { await runArchiveSelfTestIfRequested() }
        .task {
            doorbell.setActive(scenePhase != .background)
            await doorbell.restorePreview()
        }
        .task(id: doorbellMonitorKey) {
            guard doorbellMonitorKey.foreground, doorbell.enabled else { return }
            let configuration = cameraPreferences.recorderConfiguration
            if cameras.cameras.isEmpty, !configuration.username.isEmpty {
                await cameras.discover(using: configuration)
            }
            guard !Task.isCancelled else { return }
            await doorbell.monitor(configuration: configuration, cameras: { cameras.cameras })
        }
        .task(id: "\(isDashboardVisible)-\(kiosk.isSleeping)-\(scenePhase == .active)") {
            guard isDashboardVisible && scenePhase == .active else { return }
            await model.run(lowPower: kiosk.isSleeping)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(model: model, cameras: cameras, cameraPreferences: cameraPreferences, kiosk: kiosk, doorbell: doorbell) {
                model.saveServer()
                cameraPreferences.save()
                settingsPresented = false
                kiosk.setContext(active: scenePhase == .active, dashboardVisible: true)
                kiosk.showClock()
            }
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

    private var isDashboardVisible: Bool {
        !settingsPresented && activeCamera == nil && !eventsPresented && selectedMetric == nil && !doorbell.isPresenting
    }

    private struct DoorbellMonitorKey: Hashable {
        let foreground: Bool
        let enabled: Bool
        let configuration: RecorderConfiguration
    }
    private var doorbellMonitorKey: DoorbellMonitorKey {
        .init(foreground: scenePhase != .background, enabled: doorbell.enabled, configuration: cameraPreferences.recorderConfiguration)
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
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · iOS")
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

struct EnergyDetailView: View {
    @State private var metric: DashboardMetric
    @ObservedObject var model: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(metric: DashboardMetric, model: DashboardViewModel) {
        _metric = State(initialValue: metric)
        self.model = model
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height && proxy.size.width > 850
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        metricPicker
                        summary
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(metric == .system ? "Last 10 minutes" : "Today’s history")
                                    .font(.title3.weight(.semibold))
                                Text(chartCaption)
                                    .font(.subheadline).foregroundStyle(FelicityPalette.secondary)
                            }
                            Spacer()
                            if model.isLoadingChart { ProgressView().tint(FelicityPalette.accent) }
                            Button { Task { await model.refreshChart(metric, force: true) } } label: {
                                Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
                            }
                            .disabled(model.isLoadingChart)
                            .accessibilityLabel("Refresh chart")
                        }
                        chartContent(wide: wide)
                    }
                    .padding(proxy.size.width < 600 ? 16 : 24)
                    .frame(maxWidth: 1400)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .foregroundStyle(FelicityPalette.primary)
            .background(FelicityPalette.background.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .onDisappear { model.clearChart() }
        .task(id: "\(metric.rawValue)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            model.selectChart(metric)
            while !Task.isCancelled {
                await model.refreshChart(metric)
                do { try await Task.sleep(for: metric == .system ? .seconds(10) : .seconds(60)) }
                catch { return }
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.run()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to energy dashboard")
            VStack(alignment: .leading, spacing: 2) {
                Text("ENERGY").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(FelicityPalette.accent)
                Text(metric.title).font(.headline)
            }
            Spacer()
            Circle().fill(model.isLive ? FelicityPalette.live : FelicityPalette.warning).frame(width: 7, height: 7)
            Text(model.isLive ? "Live" : "Offline").font(.subheadline).foregroundStyle(FelicityPalette.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(FelicityPalette.header)
    }

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DashboardMetric.allCases) { item in
                    Button { metric = item } label: {
                        Text(item.title).font(.caption.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .foregroundStyle(metric == item ? FelicityPalette.background : FelicityPalette.secondary)
                            .background(metric == item ? FelicityPalette.accent : FelicityPalette.card, in: Capsule())
                    }
                    .accessibilityAddTraits(metric == item ? .isSelected : [])
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RIGHT NOW").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(FelicityPalette.secondary)
                    Text(primaryValue).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.65).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: metricSymbol).font(.system(size: 30, weight: .light))
                    .foregroundStyle(FelicityPalette.accent.opacity(0.8))
            }
            Rectangle().fill(FelicityPalette.secondary.opacity(0.14)).frame(height: 1)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 16) {
                ForEach(detailFacts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(fact.0).font(.caption.weight(.medium)).foregroundStyle(FelicityPalette.secondary)
                        Text(fact.1).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(FelicityPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(FelicityPalette.secondary.opacity(0.12)))
    }

    private var metricSymbol: String {
        switch metric {
        case .solar: return "sun.max"
        case .load: return "house"
        case .battery: return "battery.75"
        case .grid: return "bolt"
        case .system: return "cpu"
        case .today: return "chart.xyaxis.line"
        }
    }

    private var chartCaption: String {
        guard let start = model.chart.start else { return "Recorded measurements · gaps mean no data" }
        return start.formatted(.dateTime.day().month(.wide)) + " · " + (metric == .system ? "10-second averages" : "8-minute averages")
    }

    @ViewBuilder
    private func chartContent(wide: Bool) -> some View {
        if model.chart.samples.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: model.chartError.isEmpty ? "chart.xyaxis.line" : "wifi.exclamationmark").font(.largeTitle)
                Text(model.chartError.isEmpty ? (model.isLoadingChart ? "Loading history…" : "No measurements yet") : model.chartError)
                    .font(.subheadline).multilineTextAlignment(.center)
            }
            .foregroundStyle(FelicityPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(FelicityPalette.card, in: RoundedRectangle(cornerRadius: 22))
        } else {
            if !model.chartError.isEmpty {
                Label("History could not refresh. Showing the last available measurements.", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(FelicityPalette.warning)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: wide && metric.chartPanels.count > 1 ? 2 : 1), spacing: 18) {
                ForEach(metric.chartPanels) { panel in
                    EnergyChartPanelView(metric: metric, panel: panel, chart: model.chart).equatable()
                }
            }
        }
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

private struct NoDataView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
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
    @ObservedObject var kiosk: KioskController
    @ObservedObject var doorbell: DoorbellController
    let previewClock: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                KioskSettingsSection(kiosk: kiosk, preview: previewClock)
                Section("Doorbell") {
                    Toggle("Show incoming doorbell calls", isOn: $doorbell.enabled)
                    Text(doorbell.status).font(.caption).foregroundStyle(.secondary)
                    if let camera = cameras.cameras.first(where: \.isDoorbell) {
                        Button("Open doorbell") { doorbell.preview(camera: camera) }
                    }
                    Text("While Felicity is open, a ring shows live video for 60 seconds. The microphone starts off and can be enabled for up to 30 seconds. A caller snapshot stays in the lower corner for 30 minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                    LabeledContent("Client", value: "iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
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
