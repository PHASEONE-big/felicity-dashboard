import SwiftUI
import UIKit

private struct DoorbellCardBoundsKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// A scene-local overlay also covers charts, settings and camera sheets. Outside
/// the small caller card, the window passes touches through to the dashboard.
struct DoorbellOverlayHost: UIViewRepresentable {
    @ObservedObject var controller: DoorbellController
    let repository: CameraRepository
    let preferences: CameraPreferences

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> AnchorView {
        let anchor = AnchorView()
        anchor.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        anchor.attached = { [weak coordinator] source in
            coordinator?.attach(source: source, controller: controller, repository: repository, preferences: preferences)
        }
        return anchor
    }
    func updateUIView(_ uiView: AnchorView, context: Context) {
        if let source = uiView.window {
            context.coordinator.attach(source: source, controller: controller, repository: repository, preferences: preferences)
        }
    }
    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) { coordinator.detach() }

    final class AnchorView: UIView {
        var attached: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { DispatchQueue.main.async { [weak self] in self?.attached?(window) } }
        }
    }
    @MainActor
    final class Coordinator {
        private var window: DoorbellOverlayWindow?
        func attach(source: UIWindow, controller: DoorbellController, repository: CameraRepository, preferences: CameraPreferences) {
            guard let scene = source.windowScene else { return }
            if let window, window.windowScene === scene {
                window.fullScreen = controller.isPresenting
                window.isHidden = !controller.isPresenting && controller.thumbnail == nil
                return
            }
            detach()
            let overlay = DoorbellOverlayWindow(windowScene: scene)
            overlay.backgroundColor = .clear
            overlay.windowLevel = UIWindow.Level(rawValue: source.windowLevel.rawValue + 1)
            overlay.fullScreen = controller.isPresenting
            let root = DoorbellOverlayView(controller: controller, repository: repository, preferences: preferences) { [weak overlay] rect in
                overlay?.cardBounds = rect
            }
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            overlay.isHidden = !controller.isPresenting && controller.thumbnail == nil
            window = overlay
        }
        func detach() { window?.isHidden = true; window?.rootViewController = nil; window = nil }
    }
}

@MainActor
private final class DoorbellOverlayWindow: UIWindow {
    var fullScreen = false
    var cardBounds = CGRect.zero
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard fullScreen || cardBounds.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct DoorbellOverlayView: View {
    @ObservedObject var controller: DoorbellController
    let repository: CameraRepository
    let preferences: CameraPreferences
    let cardBounds: (CGRect) -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let session = controller.session {
                DoorbellCallView(session: session, controller: controller, repository: repository, preferences: preferences)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = controller.thumbnail {
                thumbnail(image)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: DoorbellCardBoundsKey.self, value: geometry.frame(in: .global))
                    })
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .coordinateSpace(name: "doorbell-overlay")
        .onPreferenceChange(DoorbellCardBoundsKey.self, perform: cardBounds)
        .preferredColorScheme(.dark)
    }

    private func thumbnail(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            Button { controller.reopen() } label: {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 208, height: 117).clipped()
            }
            .accessibilityLabel("Last doorbell caller. Open live doorbell")
            HStack {
                Image(systemName: "bell.fill").foregroundStyle(FelicityPalette.accent)
                if let date = controller.thumbnailDate {
                    Text(date, format: .dateTime.hour().minute()).font(.caption.weight(.semibold))
                }
                Spacer()
                Button { controller.clearThumbnail() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("Dismiss caller snapshot")
            }
            .padding(.leading, 10).padding(.trailing, 2)
        }
        .frame(width: 208)
        .background(FelicityPalette.header)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(FelicityPalette.accent.opacity(0.6)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

private struct DoorbellCallView: View {
    let session: DoorbellCallSession
    @ObservedObject var controller: DoorbellController
    @ObservedObject private var audio: DoorbellAudio
    let preferences: CameraPreferences
    @StateObject private var video: LiveCameraViewModel
    @State private var videoReady = false
    @State private var captured = false
    @Environment(\.scenePhase) private var scenePhase

    init(session: DoorbellCallSession, controller: DoorbellController, repository: CameraRepository, preferences: CameraPreferences) {
        self.session = session
        self.controller = controller
        self.audio = controller.audio
        self.preferences = preferences
        _video = StateObject(wrappedValue: LiveCameraViewModel(camera: session.camera, repository: repository, preferences: preferences))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(FelicityPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DOORBELL").font(.caption.weight(.semibold)).tracking(2)
                        Text(session.camera.name).font(.headline).lineLimit(1)
                    }
                    Spacer()
                    Text("\(controller.secondsRemaining)s").font(.subheadline.monospacedDigit()).foregroundStyle(FelicityPalette.secondary)
                    Button { controller.close() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    }.accessibilityLabel("Close doorbell call")
                }
                .padding(.horizontal, 18).padding(.vertical, 10).background(FelicityPalette.header)
                ZStack {
                    Color.black
                    ZoomableVideoView(renderer: video.renderer, aspect: session.camera.displayAspect, rotationDegrees: session.camera.rotationDegrees)
                    if !videoReady {
                        VStack(spacing: 12) {
                            if video.errorMessage == nil { ProgressView().tint(.white) }
                            Text(video.errorMessage ?? "Connecting to doorbell…").font(.subheadline)
                        }.padding(20).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                guard !Task.isCancelled, controller.session?.id == session.id else { return }
                                await audio.setListening(!audio.listeningEnabled, camera: session.camera, configuration: preferences.recorderConfiguration)
                            }
                        } label: {
                            Label(audio.listeningEnabled ? "Sound on" : "Sound off", systemImage: audio.listeningEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .background(FelicityPalette.card, in: RoundedRectangle(cornerRadius: 14))
                        Button { controller.toggleMicrophone(configuration: preferences.recorderConfiguration) } label: {
                            Label(audio.microphoneEnabled ? "Microphone on" : "Talk", systemImage: audio.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .background(audio.microphoneEnabled ? Color.red.opacity(0.65) : FelicityPalette.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text(audio.status.isEmpty ? "Microphone is off. Video closes automatically after 60 seconds." : audio.status)
                        .font(.caption).foregroundStyle(FelicityPalette.secondary).multilineTextAlignment(.center)
                }
                .padding(geometry.size.width < 600 ? 14 : 20)
                .background(FelicityPalette.background)
            }
            .foregroundStyle(.white).background(Color.black.ignoresSafeArea())
        }
        .task { await video.start() }
        .onReceive(video.renderer.$isReady) { videoReady = $0 }
        .task(id: videoReady) {
            guard session.captureCaller, videoReady, !captured else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !captured, let jpeg = await video.renderer.snapshotJPEG() else { return }
            captured = true
            await controller.saveSnapshot(jpeg, sessionID: session.id)
        }
        .onChange(of: audio.microphoneEnabled) { enabled in
            if !enabled { controller.microphoneStopped() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { controller.close() }
        }
        .onDisappear { Task { await video.stop(savePreview: false) } }
    }
}
