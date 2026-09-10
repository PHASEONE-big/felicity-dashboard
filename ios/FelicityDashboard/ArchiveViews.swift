import AudioToolbox
import OSLog
import SwiftUI
import UIKit

@MainActor
final class ArchiveViewModel: ObservableObject {
    @Published private(set) var camera: CameraDescriptor
    @Published private(set) var quality: StreamQuality
    @Published private(set) var state: ArchivePlaybackState = .idle
    @Published private(set) var statistics = LiveStreamStatistics(kbps: 0, fps: 0)
    @Published private(set) var format: VideoStreamFormat?
    @Published private(set) var currentTime: Date?
    @Published private(set) var intervals: [ArchiveInterval] = []
    @Published private(set) var poster: UIImage?
    @Published private(set) var error = ""
    @Published private(set) var visibleStart = Calendar.current.startOfDay(for: .now)
    @Published private(set) var visibleSpan: TimeInterval = 24 * 60 * 60
    @Published private(set) var isLoadingTimeline = false
    @Published private(set) var recordingDays: [Date] = []
    @Published private(set) var isLoadingCalendar = false

    let renderer = SampleBufferRenderer()

    private let repository: CameraRepository
    private let preferences: CameraPreferences
    private let threeEye: ThreeEyeConfiguration?
    private var entryEvent: ThreeEyeEvent?
    private let session = ArchiveRTSPSession()
    private let activityClient = OnvifActivityClient()
    private var seekTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var started = false
    private var seekRequestedAt: Date?
    private var playbackRequestedTime: Date?
    private var playbackKeyframeLead: TimeInterval = 0
    private var activePlaybackEnd: Date?
    private var loadedTimelineStart: Date?
    private var loadedTimelineEnd: Date?
    private var requestedTimelineStart: Date?
    private var requestedTimelineEnd: Date?
    private var loadedCalendarMonths = Set<Date>()
    private var requestedCalendarMonth: Date?
    private let logger = Logger(subsystem: "io.github.homedashboard.ios", category: "Archive")

    init(
        camera: CameraDescriptor,
        event: ThreeEyeEvent?,
        repository: CameraRepository,
        preferences: CameraPreferences
    ) {
        self.camera = camera
        self.entryEvent = event
        self.repository = repository
        self.preferences = preferences
        self.threeEye = preferences.threeEyeConfiguration
        quality = repository.preferredQuality(for: camera, compactDisplay: UIScreen.main.bounds.width < 700)
    }

    var isPlaying: Bool { state == .playing }
    var stateLabel: String {
        switch state {
        case .idle: return "ARCHIVE"
        case .connecting: return "CONNECTING…"
        case .seeking: return "SEEKING…"
        case .paused: return "PAUSED"
        case .playing: return "PLAYBACK"
        case .failed: return "ARCHIVE ERROR"
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        let target = await initialTarget()
        currentTime = target
        ArchiveMarkerStore.shared.set(target)
        await loadPoster()
        Task { await loadRecordingDays() }
        await openSession(at: target)
    }

    func stop() async {
        started = false
        seekTask?.cancel()
        timelineTask?.cancel()
        calendarTask?.cancel()
        if let jpeg = renderer.snapshotJPEG() { await CameraPreviewStore.shared.save(jpeg, for: camera) }
        await session.close()
    }

    func togglePlayback() {
        playClick()
        if isPlaying {
            playbackRequestedTime = nil
            playbackKeyframeLead = 0
            activePlaybackEnd = nil
            state = .paused
            statistics = .init(kbps: 0, fps: 0)
            Task { await session.pause() }
        } else if let target = ArchiveTimelineRules.preferredPlaybackTarget(
            currentTime: currentTime,
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            intervals: intervals,
            keyframeLead: 10
        ) {
            seek(to: target, autoplay: true, snapToRecording: false, keyframeLead: 10)
        }
    }

    func seek(
        to requested: Date,
        autoplay: Bool = false,
        snapToRecording: Bool = true,
        keyframeLead: TimeInterval = 0
    ) {
        playClick()
        let target = snapToRecording ? ArchiveTimelineRules.nearestRecordedTime(to: requested, in: intervals) ?? requested : requested
        playbackRequestedTime = autoplay ? target : nil
        playbackKeyframeLead = autoplay ? keyframeLead : 0
        activePlaybackEnd = autoplay ? ArchiveTimelineRules.playbackEnd(for: target, in: intervals, keyframeLead: keyframeLead) : nil
        seekTask?.cancel()
        let frameGeneration = renderer.beginSeek()
        state = .seeking
        seekRequestedAt = .now
        logger.info("Seek requested camera=\(self.camera.name, privacy: .public) target=\(target.timeIntervalSince1970, privacy: .public) autoplay=\(autoplay, privacy: .public)")
        seekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let self else { return }
            do { try await self.session.seek(to: target, autoplay: autoplay, frameGeneration: frameGeneration) }
            catch { await MainActor.run { self.error = error.localizedDescription; self.state = .failed(error.localizedDescription) } }
        }
    }

    func jumpRecording(_ direction: Int) {
        guard !intervals.isEmpty else { return }
        let time = currentTime ?? intervals[0].start
        let target: Date?
        if direction < 0 {
            target = intervals.last(where: { $0.end < time.addingTimeInterval(-0.25) })?.start ?? intervals.first?.start
        } else {
            target = intervals.first(where: { $0.start > time.addingTimeInterval(0.25) })?.start ?? intervals.last?.start
        }
        if let target { seek(to: target, snapToRecording: false) }
    }

    func toggleQuality() async {
        let target = currentTime ?? .now
        if let jpeg = renderer.snapshotJPEG() {
            poster = UIImage(data: jpeg)
            await CameraPreviewStore.shared.save(jpeg, for: camera)
        }
        await session.close()
        quality = quality == .lq ? .hq : .lq
        repository.setPreferredQuality(quality, for: camera)
        resetTimelineCache(clearCalendar: true)
        format = nil
        statistics = .init(kbps: 0, fps: 0)
        renderer.flush()
        Task { await loadRecordingDays() }
        await openSession(at: target)
    }

    func switchCamera(to camera: CameraDescriptor) async {
        guard camera.id != self.camera.id else { return }
        let target = currentTime ?? ArchiveMarkerStore.shared.value() ?? .now
        if let jpeg = renderer.snapshotJPEG() { await CameraPreviewStore.shared.save(jpeg, for: self.camera) }
        await session.close()
        self.camera = camera
        repository.select(camera)
        quality = repository.preferredQuality(for: camera, compactDisplay: UIScreen.main.bounds.width < 700)
        entryEvent = nil
        format = nil
        resetTimelineCache(clearCalendar: true)
        poster = nil
        renderer.flush()
        if let cached = await CameraPreviewStore.shared.data(for: camera) { poster = UIImage(data: cached) }
        Task { await loadRecordingDays() }
        await openSession(at: target)
    }

    func chooseDay(_ date: Date) {
        let calendar = Calendar.current
        let existing = currentTime ?? date
        let components = calendar.dateComponents([.hour, .minute, .second], from: existing)
        var target = calendar.startOfDay(for: date)
        target = calendar.date(byAdding: components, to: target) ?? target
        loadTimeline(around: target)
    }

    var selectedTimelineDay: Date {
        Calendar.current.startOfDay(for: visibleStart.addingTimeInterval(visibleSpan / 2))
    }

    func hasRecording(on day: Date) -> Bool {
        recordingDays.contains { Calendar.current.isDate($0, inSameDayAs: day) }
    }

    func loadCalendarMonth(containing date: Date) {
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: date)?.start,
              let end = calendar.date(byAdding: .month, value: 1, to: month),
              !loadedCalendarMonths.contains(month),
              requestedCalendarMonth != month else { return }
        calendarTask?.cancel()
        requestedCalendarMonth = month
        isLoadingCalendar = true
        calendarTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.activityClient.fetch(
                    camera: self.camera,
                    quality: self.quality,
                    configuration: self.preferences.recorderConfiguration,
                    start: month,
                    end: end
                )
                guard !Task.isCancelled else { return }
                self.addRecordingDays(from: loaded)
                self.loadedCalendarMonths.insert(month)
                self.requestedCalendarMonth = nil
                self.isLoadingCalendar = false
            } catch {
                guard !Task.isCancelled else { return }
                self.requestedCalendarMonth = nil
                self.isLoadingCalendar = false
            }
        }
    }

    func panTimeline(seconds: TimeInterval) {
        panTimeline(from: visibleStart, seconds: seconds)
    }

    func panTimeline(from baseStart: Date, seconds: TimeInterval) {
        visibleStart = clampedToPresent(baseStart.addingTimeInterval(seconds), span: visibleSpan)
        ensureTimelineCoverage()
    }

    func zoomTimeline(
        from baseStart: Date,
        span baseSpan: TimeInterval,
        magnification: Double,
        anchorRatio: Double
    ) {
        let viewport = ArchiveTimelineRules.zoomedContinuousViewport(
            baseStart: baseStart,
            baseSpan: baseSpan,
            magnification: magnification,
            anchorRatio: anchorRatio
        )
        visibleStart = clampedToPresent(viewport.start, span: viewport.span)
        visibleSpan = viewport.span
        ensureTimelineCoverage()
    }

    private func initialTarget() async -> Date {
        if let captured = entryEvent?.capturedAt { return captured }
        if let marker = ArchiveMarkerStore.shared.value() { return marker }
        if let threeEye {
            let events = try? await ThreeEyeAPI().events(configuration: threeEye, camera: camera.name, classes: Set(ThreeEyeEventClass.allCases), limit: 8)
            if let captured = events?.first?.capturedAt { return captured }
        }
        return Date().addingTimeInterval(-5)
    }

    private func loadPoster() async {
        if let event = entryEvent, let url = event.imageURL ?? event.thumbnailURL, let threeEye,
           let data = try? await ThreeEyeImageStore.shared.data(for: url, configuration: threeEye), let image = UIImage(data: data) {
            poster = image
            return
        }
        if let data = await CameraPreviewStore.shared.data(for: camera) { poster = UIImage(data: data) }
    }

    private func openSession(at target: Date) async {
        error = ""
        loadTimeline(around: target)
        do {
            let descriptor = try await ProfileGArchiveService.shared.replay(camera: camera, quality: quality, configuration: preferences.recorderConfiguration)
            let openedFormat = try await session.open(
                descriptor: descriptor,
                configuration: preferences.recorderConfiguration,
                fallbackSize: camera.encodedSize(for: quality),
                onFrame: { [weak self] unit, frameGeneration in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.renderer.enqueue(unit, generation: frameGeneration) else { return }
                        guard let time = unit.archiveTime else { return }
                        for _ in 0..<75 where !self.renderer.isReady(for: frameGeneration) { try? await Task.sleep(for: .milliseconds(16)) }
                        guard self.renderer.isReady(for: frameGeneration) else { return }
                        self.acceptDecodedTime(time)
                        if let began = self.seekRequestedAt {
                            self.logger.info("First decoded archive frame camera=\(self.camera.name, privacy: .public) actual=\(time.timeIntervalSince1970, privacy: .public) latency_ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
                            self.seekRequestedAt = nil
                        }
                    }
                },
                onStatistics: { [weak self] value in Task { @MainActor in self?.statistics = value } },
                onState: { [weak self] value in Task { @MainActor in self?.state = value } }
            )
            format = openedFormat
            renderer.configure(openedFormat)
            seek(to: target, autoplay: false, snapToRecording: false)
        } catch {
            self.error = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func loadTimeline(around target: Date) {
        requestTimelineWindow(centeredOn: target, recenterOn: target)
    }

    private func ensureTimelineCoverage() {
        let center = visibleStart.addingTimeInterval(visibleSpan / 2)
        if ArchiveTimelineRules.cachedTimelineCovers(
            visibleStart: visibleStart,
            visibleSpan: visibleSpan,
            loadedStart: loadedTimelineStart,
            loadedEnd: loadedTimelineEnd
        ) {
            if requestedTimelineStart != nil,
               !ArchiveTimelineRules.cachedTimelineCovers(
                   visibleStart: visibleStart,
                   visibleSpan: visibleSpan,
                   loadedStart: requestedTimelineStart,
                   loadedEnd: requestedTimelineEnd
               ) {
                timelineTask?.cancel()
                requestedTimelineStart = nil
                requestedTimelineEnd = nil
                isLoadingTimeline = false
            }
            return
        }
        requestTimelineWindow(centeredOn: center, recenterOn: nil)
    }

    private func requestTimelineWindow(centeredOn center: Date, recenterOn target: Date?) {
        let calendar = Calendar.current
        let window = ArchiveTimelineRules.cachedTimelineWindow(centeredOn: center, calendar: calendar)
        let start = window.start
        let end = window.end
        if let loadedTimelineStart, let loadedTimelineEnd, start >= loadedTimelineStart, end <= loadedTimelineEnd {
            if let target {
                let targetDay = calendar.startOfDay(for: target)
                let targetEnd = calendar.date(byAdding: .day, value: 1, to: targetDay) ?? targetDay.addingTimeInterval(24 * 60 * 60)
                let count = intervals.filter { $0.end >= targetDay && $0.start < targetEnd }.count
                visibleSpan = ArchiveTimelineRules.adaptiveSpan(eventCount: count)
                centerTimeline(on: target, dayStart: targetDay, dayEnd: targetEnd)
            }
            return
        }
        if requestedTimelineStart == start, requestedTimelineEnd == end { return }
        timelineTask?.cancel()
        requestedTimelineStart = start
        requestedTimelineEnd = end
        isLoadingTimeline = true
        timelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.activityClient.fetch(
                    camera: self.camera,
                    quality: self.quality,
                    configuration: self.preferences.recorderConfiguration,
                    start: start,
                    end: end
                )
                guard !Task.isCancelled else { return }
                var combined = loaded
                if let threeEye = self.threeEye,
                   let faces = try? await ThreeEyeAPI().events(configuration: threeEye, camera: self.camera.name, classes: [.face], limit: 200) {
                    combined.append(contentsOf: faces.compactMap { event in
                        guard let time = event.capturedAt, time >= start, time < end else { return nil }
                        return ArchiveInterval(kind: .face, start: time.addingTimeInterval(-ArchiveTimelineRules.context), end: time.addingTimeInterval(ArchiveTimelineRules.context))
                    })
                    combined.sort { $0.start < $1.start }
                }
                self.intervals = combined
                self.loadedTimelineStart = start
                self.loadedTimelineEnd = end
                self.requestedTimelineStart = nil
                self.requestedTimelineEnd = nil
                self.addRecordingDays(from: combined)
                if let target {
                    let targetDay = calendar.startOfDay(for: target)
                    let targetEnd = calendar.date(byAdding: .day, value: 1, to: targetDay) ?? targetDay.addingTimeInterval(24 * 60 * 60)
                    let count = combined.filter { $0.end >= targetDay && $0.start < targetEnd }.count
                    self.visibleSpan = ArchiveTimelineRules.adaptiveSpan(eventCount: count)
                    self.centerTimeline(on: target, dayStart: targetDay, dayEnd: targetEnd)
                }
                self.isLoadingTimeline = false
                self.refreshPlaybackBoundary()
            } catch {
                guard !Task.isCancelled else { return }
                self.requestedTimelineStart = nil
                self.requestedTimelineEnd = nil
                self.isLoadingTimeline = false
                if self.error.isEmpty { self.error = error.localizedDescription }
                if self.intervals.isEmpty {
                    self.visibleSpan = 24 * 60 * 60
                    self.visibleStart = calendar.startOfDay(for: target ?? center)
                    if self.state == .playing { self.pauseAtCurrentFrame() }
                }
            }
        }
    }

    private func centerTimeline(on target: Date, dayStart: Date, dayEnd: Date) {
        let proposed = target.addingTimeInterval(-visibleSpan / 2)
        visibleStart = min(max(dayStart, proposed), dayEnd.addingTimeInterval(-visibleSpan))
    }

    private func loadRecordingDays() async {
        if let threeEye,
           let events = try? await ThreeEyeAPI().events(
               configuration: threeEye,
               camera: camera.name,
               classes: Set(ThreeEyeEventClass.allCases),
               limit: 200
           ) {
            for event in events {
                if let time = event.capturedAt { addRecordingDay(Calendar.current.startOfDay(for: time)) }
            }
        }
    }

    private func addRecordingDays(from values: [ArchiveInterval]) {
        for interval in values {
            let midpoint = interval.start.addingTimeInterval(interval.end.timeIntervalSince(interval.start) / 2)
            addRecordingDay(midpoint)
        }
    }

    private func addRecordingDay(_ day: Date) {
        let normalized = Calendar.current.startOfDay(for: day)
        guard !recordingDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: normalized) }) else { return }
        recordingDays.append(normalized)
        recordingDays.sort(by: >)
    }

    private func resetTimelineCache(clearCalendar: Bool) {
        timelineTask?.cancel()
        isLoadingTimeline = false
        requestedTimelineStart = nil
        requestedTimelineEnd = nil
        loadedTimelineStart = nil
        loadedTimelineEnd = nil
        intervals = []
        if clearCalendar {
            calendarTask?.cancel()
            isLoadingCalendar = false
            requestedCalendarMonth = nil
            loadedCalendarMonths.removeAll()
            recordingDays = []
        }
    }

    private func clampedToPresent(_ proposed: Date, span: TimeInterval) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? Date().addingTimeInterval(24 * 60 * 60)
        return min(proposed, tomorrow.addingTimeInterval(-span))
    }

    private func acceptDecodedTime(_ time: Date) {
        let calendar = Calendar.current
        if state == .playing, let currentTime, time < currentTime { return }
        let previousDay = currentTime.map(calendar.startOfDay(for:))
        currentTime = time
        ArchiveMarkerStore.shared.set(time)
        let dayStart = calendar.startOfDay(for: time)
        if time < visibleStart || time > visibleStart.addingTimeInterval(visibleSpan) {
            visibleStart = clampedToPresent(time.addingTimeInterval(-visibleSpan / 2), span: visibleSpan)
            ensureTimelineCoverage()
        } else if previousDay != nil, previousDay != dayStart {
            ensureTimelineCoverage()
        }
        advancePlaybackIfNeeded(at: time)
    }

    private func refreshPlaybackBoundary() {
        guard isPlaying || playbackRequestedTime != nil else { return }
        let target = playbackRequestedTime ?? currentTime ?? .distantPast
        activePlaybackEnd = ArchiveTimelineRules.playbackEnd(for: target, in: intervals, keyframeLead: playbackKeyframeLead)
        guard let currentTime else { return }
        advancePlaybackIfNeeded(at: currentTime)
    }

    private func advancePlaybackIfNeeded(at time: Date) {
        guard state == .playing else { return }
        guard let end = activePlaybackEnd else {
            // Metadata has finished loading and did not identify an AI interval.
            // Do not let the recorder's ordinary motion archive leak into playback.
            if !isLoadingTimeline { pauseAtCurrentFrame() }
            return
        }
        guard time >= end else { return }
        if let next = ArchiveTimelineRules.nextPlaybackStart(after: end, in: intervals) {
            logger.info("AI segment complete camera=\(self.camera.name, privacy: .public) next=\(next.timeIntervalSince1970, privacy: .public)")
            seek(to: next, autoplay: true, snapToRecording: false)
        } else {
            logger.info("AI segment complete camera=\(self.camera.name, privacy: .public) no_next_segment")
            pauseAtCurrentFrame()
        }
    }

    private func pauseAtCurrentFrame() {
        playbackRequestedTime = nil
        playbackKeyframeLead = 0
        activePlaybackEnd = nil
        state = .paused
        statistics = .init(kbps: 0, fps: 0)
        Task { await session.pause() }
    }

    private func playClick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AudioServicesPlaySystemSound(1104)
    }
}

struct ArchiveView: View {
    @ObservedObject var repository: CameraRepository
    @ObservedObject var preferences: CameraPreferences
    let backLabel: String
    @StateObject private var model: ArchiveViewModel
    @State private var cameraPicker = false
    @State private var livePresented = false
    @State private var calendarPresented = false
    @Environment(\.dismiss) private var dismiss

    init(camera: CameraDescriptor, event: ThreeEyeEvent?, backLabel: String, repository: CameraRepository, preferences: CameraPreferences) {
        self.repository = repository
        self.preferences = preferences
        self.backLabel = backLabel
        _model = StateObject(wrappedValue: ArchiveViewModel(camera: camera, event: event, repository: repository, preferences: preferences))
    }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            VStack(spacing: 0) {
                archiveHeader(compact: portrait || proxy.size.width < 900)
                ZStack(alignment: .bottomLeading) {
                    ArchiveVideoCanvas(renderer: model.renderer, camera: model.camera, poster: model.poster)
                    if case .failed = model.state {
                        Text(model.error)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.orange)
                            .padding(24)
                            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !portrait { controls }
                }
                if portrait {
                    controls
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.07, green: 0.09, blue: 0.09))
                }
                ArchiveTimelineView(model: model)
                    .frame(height: portrait ? 132 : 112)
            }
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
        .fullScreenCover(isPresented: $cameraPicker) {
            CameraWallView(repository: repository, backLabel: "ARCHIVE") { camera in Task { await model.switchCamera(to: camera) } }
        }
        .fullScreenCover(isPresented: $livePresented) {
            LiveCameraView(camera: model.camera, repository: repository, preferences: preferences)
        }
        .sheet(isPresented: $calendarPresented) {
            ArchiveCalendarPicker(model: model) { day in
                model.chooseDay(day)
                calendarPresented = false
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func archiveHeader(compact: Bool) -> some View {
        Group {
            if compact { HStack(spacing: 6) { headerContentsCompact } }
            else { HStack(spacing: 10) { headerContents } }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 66)
        .foregroundStyle(.white)
        .background(Color(red: 14 / 255, green: 48 / 255, blue: 43 / 255))
    }

    @ViewBuilder private var headerContents: some View {
        CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
        CameraBarButton(title: model.camera.name, systemImage: "video.fill") { cameraPicker = true }
        streamStatistics
        Spacer(minLength: 4)
        playbackClock
        Button(model.quality.rawValue) { Task { await model.toggleQuality() } }.buttonStyle(HeaderButtonStyle())
        CameraBarButton(title: "LIVE", systemImage: "dot.radiowaves.left.and.right") { livePresented = true }
    }

    @ViewBuilder private var headerContentsCompact: some View {
        CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
        CameraBarButton(title: model.camera.name, systemImage: "video.fill") { cameraPicker = true }
        Spacer(minLength: 0)
        playbackClock
        Button(model.quality.rawValue) { Task { await model.toggleQuality() } }.buttonStyle(HeaderButtonStyle())
        Button { livePresented = true } label: { Image(systemName: "dot.radiowaves.left.and.right").frame(width: 42, height: 42) }
            .buttonStyle(HeaderButtonStyle())
    }

    private var streamStatistics: some View {
        VStack(spacing: 1) {
            Text(model.state == .paused ? "PAUSED" : "\(Int(model.statistics.kbps.rounded())) kbps · \(model.statistics.fps, specifier: "%.1f") FPS")
            Text("\(model.format?.width ?? model.camera.encodedSize(for: model.quality).width)×\(model.format?.height ?? model.camera.encodedSize(for: model.quality).height) · \(model.format?.codecName ?? "—")")
        }
        .font(.caption.bold().monospacedDigit())
    }

    private var playbackClock: some View {
        VStack(spacing: 1) {
            Text(model.stateLabel).font(.caption2.bold())
            Text(model.currentTime?.formatted(date: .omitted, time: .standard) ?? "--:--:--")
                .font(.title3.bold().monospacedDigit())
        }
        .fixedSize()
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Button { model.jumpRecording(-1) } label: { Label("PREV", systemImage: "backward.end.fill") }
                Button { model.jumpRecording(1) } label: { Label("NEXT", systemImage: "forward.end.fill") }
                Button { calendarPresented = true } label: { Label("DATE", systemImage: "calendar") }
            }
            HStack(spacing: 8) {
                Button { model.togglePlayback() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                Button { model.jumpRecording(-1) } label: { Image(systemName: "backward.end.fill") }
                Button { model.jumpRecording(1) } label: { Image(systemName: "forward.end.fill") }
                Button { calendarPresented = true } label: { Image(systemName: "calendar") }
            }
        }
        .font(.headline.bold())
        .buttonStyle(ArchiveControlButtonStyle())
        .padding(14)
    }
}

private struct ArchiveCalendarPicker: View {
    @ObservedObject var model: ArchiveViewModel
    let select: (Date) -> Void
    @State private var month: Date
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    init(model: ArchiveViewModel, select: @escaping (Date) -> Void) {
        self.model = model
        self.select = select
        let selected = model.selectedTimelineDay
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: selected)?.start ?? selected)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month, format: .dateTime.month(.wide).year())
                    .font(.headline.bold())
                if model.isLoadingCalendar { ProgressView().controlSize(.small).padding(.leading, 6) }
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!canAdvance)
            }
            .buttonStyle(HeaderButtonStyle())

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption2.bold()).foregroundStyle(.secondary).frame(height: 20)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Button { select(day) } label: {
                            VStack(spacing: 3) {
                                Text(day, format: .dateTime.day())
                                    .font(.subheadline.bold().monospacedDigit())
                                Circle()
                                    .fill(model.hasRecording(on: day) ? FelicityPalette.accent : .clear)
                                    .frame(width: 6, height: 6)
                            }
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(isSelected(day) ? Color.black : Color.primary)
                            .background(isSelected(day) ? FelicityPalette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                if calendar.isDateInToday(day) {
                                    RoundedRectangle(cornerRadius: 10).stroke(FelicityPalette.accent.opacity(0.75), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(day > Date())
                        .opacity(day > Date() ? 0.28 : 1)
                        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        .accessibilityValue(model.hasRecording(on: day) ? "Recordings" : "No recordings")
                    } else {
                        Color.clear.frame(height: 38)
                    }
                }
            }
            Text("•  ONVIF RECORDINGS")
                .font(.caption2.bold())
                .foregroundStyle(FelicityPalette.accent)
        }
        .padding(22)
        .onAppear { model.loadCalendarMonth(containing: month) }
        .onChange(of: month) { model.loadCalendarMonth(containing: $0) }
    }

    private var weekdaySymbols: [String] {
        let source = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { source[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + (0..<count).map {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
    }

    private var canAdvance: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { return false }
        return next <= (calendar.dateInterval(of: .month, for: .now)?.start ?? .now)
    }

    private func isSelected(_ day: Date) -> Bool {
        calendar.isDate(day, inSameDayAs: model.selectedTimelineDay)
    }

    private func changeMonth(_ value: Int) {
        if let next = calendar.date(byAdding: .month, value: value, to: month) { month = next }
    }
}

private struct ArchiveVideoCanvas: View {
    @ObservedObject var renderer: SampleBufferRenderer
    let camera: CameraDescriptor
    let poster: UIImage?

    var body: some View {
        ZStack {
            Color.black
            ZoomableVideoView(renderer: renderer, aspect: camera.displayAspect, rotationDegrees: camera.rotationDegrees)
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .opacity(renderer.isReady ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: renderer.isReady)
    }
}

private struct ArchiveTimelineView: View {
    @ObservedObject var model: ArchiveViewModel
    @State private var pinchBaseStart: Date?
    @State private var pinchBaseSpan: TimeInterval?
    @State private var suppressDrag = false
    @State private var dragBaseStart: Date?

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            interactiveTimeline(width: width)
        }
    }

    @ViewBuilder private func interactiveTimeline(width: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            timeline(width: width)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            updateZoom(magnification: Double(value.magnification), anchorRatio: Double(value.startAnchor.x))
                        }
                        .onEnded { _ in finishZoom() }
                )
        } else {
            timeline(width: width)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in updateZoom(magnification: Double(value), anchorRatio: 0.5) }
                        .onEnded { _ in finishZoom() }
                )
        }
    }

    private func timeline(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color(red: 0.07, green: 0.09, blue: 0.09)
            tickMarks(width: width)
            ForEach(model.intervals) { interval in
                let x1 = x(interval.start, width: width)
                let x2 = x(interval.end, width: width)
                if x2 >= 0, x1 <= width {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(interval.kind.color)
                        .frame(width: max(3, x2 - x1), height: 34)
                        .offset(x: x1, y: -18)
                }
            }
            if let current = model.currentTime {
                Rectangle().fill(.white).frame(width: 2, height: 92).offset(x: x(current, width: width))
            }
            if model.isLoadingTimeline { ProgressView().tint(.cyan).frame(maxWidth: .infinity) }
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !suppressDrag else { return }
                if dragBaseStart == nil { dragBaseStart = model.visibleStart }
                guard abs(value.translation.width) > 4, let base = dragBaseStart else { return }
                model.panTimeline(from: base, seconds: -Double(value.translation.width / width) * model.visibleSpan)
            }
            .onEnded { value in
                let base = dragBaseStart ?? model.visibleStart
                dragBaseStart = nil
                guard !suppressDrag else { return }
                if abs(value.translation.width) > 10 {
                    model.panTimeline(from: base, seconds: -Double(value.translation.width / width) * model.visibleSpan)
                } else {
                    let ratio = min(1, max(0, value.location.x / width))
                    model.seek(to: model.visibleStart.addingTimeInterval(Double(ratio) * model.visibleSpan))
                }
            }
    }

    private func updateZoom(magnification: Double, anchorRatio: Double) {
        if pinchBaseStart == nil {
            pinchBaseStart = model.visibleStart
            pinchBaseSpan = model.visibleSpan
        }
        suppressDrag = true
        guard let baseStart = pinchBaseStart, let baseSpan = pinchBaseSpan else { return }
        model.zoomTimeline(from: baseStart, span: baseSpan, magnification: magnification, anchorRatio: anchorRatio)
    }

    private func finishZoom() {
        pinchBaseStart = nil
        pinchBaseSpan = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { suppressDrag = false }
    }

    @ViewBuilder private func tickMarks(width: CGFloat) -> some View {
        let count = model.visibleSpan <= 3 * 3600 ? 7 : model.visibleSpan <= 6 * 3600 ? 7 : 9
        let visibleEnd = model.visibleStart.addingTimeInterval(model.visibleSpan)
        let crossesMidnight = !Calendar.current.isDate(model.visibleStart, inSameDayAs: visibleEnd)
        ForEach(0..<count, id: \.self) { index in
            let ratio = CGFloat(index) / CGFloat(max(1, count - 1))
            let date = model.visibleStart.addingTimeInterval(Double(ratio) * model.visibleSpan)
            VStack(spacing: 4) {
                Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: index % 2 == 0 ? 18 : 10)
                if crossesMidnight {
                    Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .position(x: width * ratio, y: 86)
        }
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(model.visibleStart) / model.visibleSpan) * width
    }
}

private struct ArchiveControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(configuration.isPressed ? Color.cyan.opacity(0.42) : Color(red: 0.18, green: 0.21, blue: 0.20).opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
