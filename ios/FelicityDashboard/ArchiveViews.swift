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

    private(set) var timelineRevision = 0

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
    private var timelineWarmupTask: Task<Void, Never>?
    private var rendererReadinessTask: Task<Void, Never>?
    private var pendingReadyTime: Date?
    private var pendingReadyGeneration: UInt64?
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
    private var deferredTimelineTarget: Date?
    private var exactCurrentTime: Date?
    private var lastCurrentTimePublish = Date.distantPast
    private var entryStartedAt: Date?
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
        entryStartedAt = .now
        let target = await initialTarget()
        currentTime = target
        exactCurrentTime = target
        ArchiveMarkerStore.shared.set(target)
        prepareViewport(for: target)
        await loadPoster()
        await openSession(at: target)
    }

    func stop() async {
        started = false
        deferredTimelineTarget = nil
        seekTask?.cancel()
        timelineTask?.cancel()
        calendarTask?.cancel()
        timelineWarmupTask?.cancel()
        rendererReadinessTask?.cancel()
        ArchiveMarkerStore.shared.flush()
        await session.close()
        savePreviewInBackground(for: camera)
    }

    func suspendForOverlay(savePreview: Bool) async {
        publishExactCurrentTime()
        playbackRequestedTime = nil
        playbackKeyframeLead = 0
        activePlaybackEnd = nil
        state = .paused
        statistics = .init(kbps: 0, fps: 0)
        await session.pause()
        if savePreview { savePreviewInBackground(for: camera) }
    }

    func togglePlayback() {
        playClick()
        if isPlaying {
            publishExactCurrentTime()
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
        rendererReadinessTask?.cancel()
        rendererReadinessTask = nil
        pendingReadyTime = nil
        pendingReadyGeneration = nil
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
        if let jpeg = await renderer.snapshotJPEG() {
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
        await openSession(at: target)
    }

    func switchCamera(to camera: CameraDescriptor) async {
        guard camera.id != self.camera.id else { return }
        let target = currentTime ?? ArchiveMarkerStore.shared.value() ?? .now
        if let jpeg = await renderer.snapshotJPEG() { await CameraPreviewStore.shared.save(jpeg, for: self.camera) }
        await session.close()
        self.camera = camera
        repository.select(camera)
        quality = repository.preferredQuality(for: camera, compactDisplay: UIScreen.main.bounds.width < 700)
        entryEvent = nil
        format = nil
        resetTimelineCache(clearCalendar: true)
        poster = nil
        renderer.flush()
        poster = await CameraPreviewStore.shared.image(for: camera)
        await openSession(at: target)
    }

    func chooseDay(_ date: Date) {
        let calendar = Calendar.current
        let existing = currentTime ?? date
        let components = calendar.dateComponents([.hour, .minute, .second], from: existing)
        var target = calendar.startOfDay(for: date)
        target = calendar.date(byAdding: components, to: target) ?? target
        deferredTimelineTarget = nil
        timelineWarmupTask?.cancel()
        timelineWarmupTask = nil
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
        return Date().addingTimeInterval(-5)
    }

    private func loadPoster() async {
        if let event = entryEvent, let url = event.imageURL ?? event.thumbnailURL, let threeEye,
           let data = try? await ThreeEyeImageStore.shared.data(for: url, configuration: threeEye),
           let image = await Task.detached(priority: .utility, operation: {
               CameraPreviewStore.thumbnail(from: data, maxPixelSize: 1_440)
           }).value {
            poster = image
            return
        }
        poster = await CameraPreviewStore.shared.image(for: camera)
    }

    private func openSession(at target: Date) async {
        error = ""
        deferredTimelineTarget = target
        timelineWarmupTask?.cancel()
        do {
            let descriptor = try await ProfileGArchiveService.shared.replay(camera: camera, quality: quality, configuration: preferences.recorderConfiguration)
            let openedFormat = try await session.open(
                descriptor: descriptor,
                configuration: preferences.recorderConfiguration,
                fallbackSize: camera.encodedSize(for: quality),
                onFrame: { [weak self] unit, frameGeneration in
                    self?.acceptFrame(unit, generation: frameGeneration)
                },
                onStatistics: { [weak self] value in Task { @MainActor in self?.statistics = value } },
                onState: { [weak self] value in Task { @MainActor in self?.state = value } }
            )
            format = openedFormat
            renderer.configure(openedFormat)
            seek(to: target, autoplay: false, snapToRecording: false)
            timelineWarmupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.startDeferredTimelineLoad()
            }
        } catch {
            self.error = error.localizedDescription
            state = .failed(error.localizedDescription)
        }
    }

    private func acceptFrame(_ unit: VideoAccessUnit, generation: UInt64) {
        guard renderer.enqueue(unit, generation: generation), let time = unit.archiveTime else { return }
        if renderer.isReady(for: generation) {
            commitDisplayedTime(time)
            return
        }

        pendingReadyTime = time
        guard pendingReadyGeneration != generation else { return }
        pendingReadyGeneration = generation
        rendererReadinessTask?.cancel()
        rendererReadinessTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, self.pendingReadyGeneration == generation else { return }
                if self.renderer.isReady(for: generation) {
                    if let time = self.pendingReadyTime { self.commitDisplayedTime(time) }
                    self.pendingReadyGeneration = nil
                    self.pendingReadyTime = nil
                    self.rendererReadinessTask = nil
                    return
                }
            }
        }
    }

    private func commitDisplayedTime(_ time: Date) {
        acceptDecodedTime(time)
        if let began = seekRequestedAt {
            logger.info("First decoded archive frame camera=\(self.camera.name, privacy: .public) actual=\(time.timeIntervalSince1970, privacy: .public) latency_ms=\(Int(Date().timeIntervalSince(began) * 1000), privacy: .public)")
            seekRequestedAt = nil
        }
    }

    private func loadTimeline(around target: Date) {
        requestTimelineWindow(centeredOn: target, recenterOn: target)
    }

    private func startDeferredTimelineLoad() {
        guard let target = deferredTimelineTarget else { return }
        deferredTimelineTarget = nil
        timelineWarmupTask?.cancel()
        timelineWarmupTask = nil
        loadTimeline(around: target)
        Task { await loadRecordingDays() }
    }

    private func prepareViewport(for target: Date) {
        visibleSpan = ArchiveTimelineRules.maximumVisibleSpan
        visibleStart = Calendar.current.startOfDay(for: target)
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
        let requestedAt = Date()
        logger.info("Timeline metadata requested camera=\(self.camera.name, privacy: .public) start=\(start.timeIntervalSince1970, privacy: .public) end=\(end.timeIntervalSince1970, privacy: .public)")
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
                self.timelineRevision &+= 1
                self.intervals = combined
                self.loadedTimelineStart = start
                self.loadedTimelineEnd = end
                self.requestedTimelineStart = nil
                self.requestedTimelineEnd = nil
                self.addRecordingDays(from: combined)
                self.logger.info("Timeline metadata loaded camera=\(self.camera.name, privacy: .public) intervals=\(combined.count, privacy: .public) latency_ms=\(Int(Date().timeIntervalSince(requestedAt) * 1000), privacy: .public)")
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
        timelineRevision &+= 1
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
        if state == .playing, let exactCurrentTime, time < exactCurrentTime { return }
        let previousDay = exactCurrentTime.map(calendar.startOfDay(for:))
        exactCurrentTime = time
        let now = Date()
        if state != .playing || currentTime == nil || now.timeIntervalSince(lastCurrentTimePublish) >= 0.25 {
            currentTime = time
            lastCurrentTimePublish = now
            ArchiveMarkerStore.shared.set(time, now: now)
        }
        if let began = entryStartedAt {
            logger.info("Archive first frame camera=\(self.camera.name, privacy: .public) entry_latency_ms=\(Int(now.timeIntervalSince(began) * 1000), privacy: .public)")
            entryStartedAt = nil
        }
        let dayStart = calendar.startOfDay(for: time)
        if time < visibleStart || time > visibleStart.addingTimeInterval(visibleSpan) {
            visibleStart = clampedToPresent(time.addingTimeInterval(-visibleSpan / 2), span: visibleSpan)
            ensureTimelineCoverage()
        } else if previousDay != nil, previousDay != dayStart {
            ensureTimelineCoverage()
        }
        advancePlaybackIfNeeded(at: time)
        startDeferredTimelineLoad()
    }

    private func publishExactCurrentTime() {
        guard let exactCurrentTime else { return }
        currentTime = exactCurrentTime
        let now = Date()
        lastCurrentTimePublish = now
        ArchiveMarkerStore.shared.set(exactCurrentTime, now: now)
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
        publishExactCurrentTime()
        playbackRequestedTime = nil
        playbackKeyframeLead = 0
        activePlaybackEnd = nil
        state = .paused
        statistics = .init(kbps: 0, fps: 0)
        Task { await session.pause() }
    }

    private func savePreviewInBackground(for camera: CameraDescriptor) {
        Task { [renderer] in
            guard let jpeg = await renderer.snapshotJPEG() else { return }
            await CameraPreviewStore.shared.save(jpeg, for: camera)
        }
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
    @State private var pendingCamera: CameraDescriptor?
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
        .onDisappear {
            guard !cameraPicker, !livePresented, !calendarPresented else { return }
            Task { await model.stop() }
        }
        .fullScreenCover(isPresented: $cameraPicker, onDismiss: {
            let selected = pendingCamera
            pendingCamera = nil
            if let selected { Task { await model.switchCamera(to: selected) } }
        }) {
            CameraWallView(repository: repository, backLabel: "ARCHIVE") { camera in pendingCamera = camera }
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
        CameraBarButton(title: model.camera.name, systemImage: "video.fill") { presentCameraPicker() }
        streamStatistics
        Spacer(minLength: 4)
        playbackClock
        Button(model.quality.rawValue) { Task { await model.toggleQuality() } }.buttonStyle(HeaderButtonStyle())
        CameraBarButton(title: "LIVE", systemImage: "dot.radiowaves.left.and.right") { presentLive() }
    }

    @ViewBuilder private var headerContentsCompact: some View {
        CameraBarButton(title: backLabel, systemImage: "chevron.left") { dismiss() }
        CameraBarButton(title: model.camera.name, systemImage: "video.fill") { presentCameraPicker() }
        Spacer(minLength: 0)
        playbackClock
        Button(model.quality.rawValue) { Task { await model.toggleQuality() } }.buttonStyle(HeaderButtonStyle())
        Button { presentLive() } label: { Image(systemName: "dot.radiowaves.left.and.right").frame(width: 42, height: 42) }
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

    private func presentCameraPicker() {
        Task { @MainActor in
            await model.suspendForOverlay(savePreview: true)
            cameraPicker = true
        }
    }

    private func presentLive() {
        Task { @MainActor in
            await model.suspendForOverlay(savePreview: true)
            livePresented = true
        }
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

private struct ArchiveTimelineView: UIViewRepresentable {
    // The timeline is backed by UIKit, so it must subscribe explicitly. A
    // plain reference here left the surface at its initial empty render when
    // Profile G metadata arrived after the archive screen was presented.
    @ObservedObject var model: ArchiveViewModel

    func makeUIView(context: Context) -> ArchiveTimelineSurface {
        let view = ArchiveTimelineSurface()
        view.onPan = { [weak model] baseStart, seconds in
            model?.panTimeline(from: baseStart, seconds: seconds)
        }
        view.onZoom = { [weak model] baseStart, baseSpan, magnification, anchorRatio in
            model?.zoomTimeline(
                from: baseStart,
                span: baseSpan,
                magnification: magnification,
                anchorRatio: anchorRatio
            )
        }
        view.onSeek = { [weak model] time in model?.seek(to: time) }
        return view
    }

    func updateUIView(_ view: ArchiveTimelineSurface, context: Context) {
        view.update(
            visibleStart: model.visibleStart,
            visibleSpan: model.visibleSpan,
            intervals: model.intervals,
            revision: model.timelineRevision,
            currentTime: model.currentTime,
            isLoading: model.isLoadingTimeline
        )
    }
}

/// A timeline whose hot interaction path never publishes SwiftUI state.
/// Bars and labels are drawn once into a three-viewport backing store; a
/// drag only transforms that strip. The archive model is updated once, after
/// the gesture (and its short inertial continuation) finishes.
final class ArchiveTimelineSurface: UIView, UIGestureRecognizerDelegate {
    var onPan: ((Date, TimeInterval) -> Void)?
    var onZoom: ((Date, TimeInterval, Double, Double) -> Void)?
    var onSeek: ((Date) -> Void)?

    private(set) var renderPassCount = 0
    var isUsingRasterCache: Bool { contentView.layer.shouldRasterize }
    var stripWidth: CGFloat { contentView.bounds.width }

    private let contentView = ArchiveTimelineStripView()
    private let cursorLayer = CALayer()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var visibleStart = Date.distantPast
    private var visibleSpan = ArchiveTimelineRules.maximumVisibleSpan
    private var intervals: [ArchiveInterval] = []
    private var revision = -1
    private var currentTime: Date?
    private var renderedSize = CGSize.zero
    private var renderedStart = Date.distantPast
    private var renderedSpan: TimeInterval = 0
    private var renderedRevision = -1
    private var animator: UIViewPropertyAnimator?
    private var panning = false
    private var pinching = false
    private var pinchAnchorRatio = 0.5
    private var pinchCursorX: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.09, alpha: 1)
        clipsToBounds = true
        contentView.isUserInteractionEnabled = false
        contentView.layer.anchorPoint = .zero
        contentView.layer.position = .zero
        addSubview(contentView)

        cursorLayer.backgroundColor = UIColor.white.cgColor
        layer.addSublayer(cursorLayer)

        loadingIndicator.color = .cyan
        loadingIndicator.hidesWhenStopped = true
        addSubview(loadingIndicator)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)

        isAccessibilityElement = true
        accessibilityLabel = "Archive timeline"
        accessibilityHint = "Swipe to browse, pinch to change scale, or tap to seek"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard bounds.size != renderedSize else { return }
        rebuildLayers()
    }

    func update(
        visibleStart: Date,
        visibleSpan: TimeInterval,
        intervals: [ArchiveInterval],
        revision: Int,
        currentTime: Date?,
        isLoading: Bool
    ) {
        self.visibleStart = visibleStart
        self.visibleSpan = visibleSpan
        self.intervals = intervals
        self.revision = revision
        self.currentTime = currentTime

        if isLoading { loadingIndicator.startAnimating() }
        else { loadingIndicator.stopAnimating() }

        if visibleStart != renderedStart || visibleSpan != renderedSpan || revision != renderedRevision {
            rebuildLayers()
        } else if !panning, !pinching, animator == nil {
            updateCursor()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard bounds.width > 0 else { return }
        let ratio = min(1, max(0, gesture.location(in: self).x / bounds.width))
        onSeek?(visibleStart.addingTimeInterval(visibleSpan * Double(ratio)))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !pinching, bounds.width > 0 else { return }
        switch gesture.state {
        case .began:
            cancelAnimation()
            panning = true
        case .changed:
            let translation = gesture.translation(in: self).x
            contentView.transform = neutralTransform.translatedBy(x: translation, y: 0)
            cursorLayer.setAffineTransform(CGAffineTransform(translationX: translation, y: 0))
        case .ended:
            let translation = gesture.translation(in: self).x
            let velocity = gesture.velocity(in: self).x
            finishPan(translation: translation, velocity: velocity)
        case .cancelled, .failed:
            panning = false
            restoreNeutralTransform(animated: true)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard bounds.width > 0 else { return }
        switch gesture.state {
        case .began:
            cancelAnimation()
            pinching = true
            pinchAnchorRatio = min(1, max(0, gesture.location(in: self).x / bounds.width))
            pinchCursorX = cursorLayer.frame.midX
        case .changed:
            let scale = effectiveScale(for: Double(gesture.scale))
            let anchor = bounds.width * pinchAnchorRatio
            contentView.transform = CGAffineTransform(
                a: scale,
                b: 0,
                c: 0,
                d: 1,
                tx: -scale * bounds.width + anchor * (1 - scale),
                ty: 0
            )
            if let pinchCursorX {
                setCursorCenterX(anchor + (pinchCursorX - anchor) * scale)
            }
        case .ended:
            let scale = effectiveScale(for: Double(gesture.scale))
            let baseStart = visibleStart
            let baseSpan = visibleSpan
            let anchor = Double(pinchAnchorRatio)
            pinching = false
            pinchCursorX = nil
            onZoom?(baseStart, baseSpan, scale, anchor)
        case .cancelled, .failed:
            pinching = false
            pinchCursorX = nil
            restoreNeutralTransform(animated: true)
        default:
            break
        }
    }

    private func finishPan(translation: CGFloat, velocity: CGFloat) {
        let projected = min(bounds.width * 1.5, max(-bounds.width * 1.5, translation + velocity * 0.16))
        guard abs(projected) > 4 else {
            panning = false
            restoreNeutralTransform(animated: true)
            return
        }
        let baseStart = visibleStart
        let seconds = -Double(projected / bounds.width) * visibleSpan
        let remaining = abs(projected - translation)
        let duration = min(0.28, max(0.08, TimeInterval(remaining / max(abs(velocity), 600))))
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            self.contentView.transform = self.neutralTransform.translatedBy(x: projected, y: 0)
            self.cursorLayer.setAffineTransform(CGAffineTransform(translationX: projected, y: 0))
        }
        self.animator = animator
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            self.animator = nil
            self.panning = false
            if position == .end { self.onPan?(baseStart, seconds) }
            else { self.restoreNeutralTransform(animated: false) }
        }
        animator.startAnimation()
    }

    private func effectiveScale(for rawScale: Double) -> CGFloat {
        let requestedSpan = visibleSpan / max(0.01, rawScale)
        let span = min(
            ArchiveTimelineRules.maximumVisibleSpan,
            max(ArchiveTimelineRules.minimumVisibleSpan, requestedSpan)
        )
        return CGFloat(visibleSpan / span)
    }

    private var neutralTransform: CGAffineTransform {
        CGAffineTransform(translationX: -bounds.width, y: 0)
    }

    private func cancelAnimation() {
        animator?.stopAnimation(true)
        animator = nil
        contentView.transform = neutralTransform
        cursorLayer.setAffineTransform(.identity)
    }

    private func restoreNeutralTransform(animated: Bool) {
        animator?.stopAnimation(true)
        animator = nil
        guard animated else {
            contentView.transform = neutralTransform
            cursorLayer.setAffineTransform(.identity)
            updateCursor()
            return
        }
        UIView.animate(withDuration: 0.12) {
            self.contentView.transform = self.neutralTransform
            self.cursorLayer.setAffineTransform(.identity)
        }
    }

    private func rebuildLayers() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderPassCount += 1
        cancelAnimation()
        renderedSize = bounds.size
        renderedStart = visibleStart
        renderedSpan = visibleSpan
        renderedRevision = revision

        contentView.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * 3, height: bounds.height))
        contentView.layer.position = .zero
        contentView.transform = neutralTransform
        contentView.configure(visibleStart: visibleStart, visibleSpan: visibleSpan, intervals: intervals)
        // iOS 16 can defer a redraw of a transformed, partially off-screen
        // UIView indefinitely. Draw the newly arrived metadata now; this is a
        // single cheap Core Graphics pass and only runs when the viewport or
        // timeline revision changes, never for cursor movement.
        contentView.layer.displayIfNeeded()
        updateCursor()
    }

    private func updateCursor() {
        guard let currentTime else {
            cursorLayer.isHidden = true
            return
        }
        let x = CGFloat(currentTime.timeIntervalSince(visibleStart) / visibleSpan) * bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = x < 0 || x > bounds.width
        cursorLayer.setAffineTransform(.identity)
        cursorLayer.frame = CGRect(x: x, y: 0, width: 2, height: min(92, bounds.height))
        CATransaction.commit()
    }

    private func setCursorCenterX(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position.x = x
        CATransaction.commit()
    }

}

/// Draws the complete strip in one pass. This replaces hundreds of CALayers
/// without using `shouldRasterize`: a three-screen raster cache can exceed the
/// maximum texture size on older iPads and disappear entirely.
final class ArchiveTimelineStripView: UIView {
    private var visibleStart = Date.distantPast
    private var visibleSpan = ArchiveTimelineRules.maximumVisibleSpan
    private var intervals: [ArchiveInterval] = []

    private lazy var timeFormatter: DateFormatter = Self.formatter(template: "HHmm")
    private lazy var dateTimeFormatter: DateFormatter = Self.formatter(template: "ddMMMHHmm")
    private lazy var labelStyle: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.75),
            .paragraphStyle: paragraph,
        ]
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.09, alpha: 1)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(visibleStart: Date, visibleSpan: TimeInterval, intervals: [ArchiveInterval]) {
        self.visibleStart = visibleStart
        self.visibleSpan = visibleSpan
        self.intervals = intervals
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard visibleSpan > 0, bounds.width > 0, bounds.height > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let pageWidth = bounds.width / 3
        let stripStart = visibleStart.addingTimeInterval(-visibleSpan)
        let stripEnd = visibleStart.addingTimeInterval(visibleSpan * 2)

        context.setFillColor(backgroundColor?.cgColor ?? UIColor.black.cgColor)
        context.fill(rect)

        for interval in intervals where interval.end >= stripStart && interval.start <= stripEnd {
            let x1 = xPosition(of: interval.start, stripStart: stripStart, pageWidth: pageWidth)
            let x2 = xPosition(of: interval.end, stripStart: stripStart, pageWidth: pageWidth)
            context.setFillColor(interval.kind.uiColor.cgColor)
            let bar = CGRect(x: x1, y: 8, width: max(3, x2 - x1), height: 34)
            context.addPath(UIBezierPath(roundedRect: bar, cornerRadius: 1.5).cgPath)
            context.fillPath()
        }

        drawTicks(context: context, stripStart: stripStart, pageWidth: pageWidth)
    }

    private func drawTicks(context: CGContext, stripStart: Date, pageWidth: CGFloat) {
        let count = visibleSpan <= 6 * 3_600 ? 7 : 9
        context.setFillColor(UIColor.white.withAlphaComponent(0.55).cgColor)
        for page in -1...1 {
            let pageStart = visibleStart.addingTimeInterval(Double(page) * visibleSpan)
            let pageEnd = pageStart.addingTimeInterval(visibleSpan)
            let crossesMidnight = !Calendar.current.isDate(pageStart, inSameDayAs: pageEnd)
            for index in 0..<count {
                if page > -1, index == 0 { continue }
                let ratio = CGFloat(index) / CGFloat(max(1, count - 1))
                let date = pageStart.addingTimeInterval(Double(ratio) * visibleSpan)
                let x = xPosition(of: date, stripStart: stripStart, pageWidth: pageWidth)
                context.fill(CGRect(x: x, y: 60, width: 1, height: index.isMultiple(of: 2) ? 18 : 10))
                let text = (crossesMidnight ? dateTimeFormatter : timeFormatter).string(from: date) as NSString
                text.draw(in: CGRect(x: x - 48, y: 82, width: 96, height: 18), withAttributes: labelStyle)
            }
        }
    }

    private func xPosition(of date: Date, stripStart: Date, pageWidth: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(stripStart) / visibleSpan) * pageWidth
    }

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

private extension ArchiveActivityKind {
    var uiColor: UIColor {
        switch self {
        case .person, .face: return UIColor(red: 0.07, green: 0.68, blue: 0.94, alpha: 1)
        case .animal: return UIColor(red: 0.50, green: 0.25, blue: 0.94, alpha: 1)
        case .vehicle: return UIColor(red: 0.48, green: 0.78, blue: 0.18, alpha: 1)
        case .ring: return UIColor(red: 0.15, green: 0.73, blue: 0.61, alpha: 1)
        }
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
