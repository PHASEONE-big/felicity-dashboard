import Combine
import SwiftUI
import UIKit

/// Owns display changes only while Felicity is in the foreground.
@MainActor
final class KioskController: ObservableObject {
    @Published var enabled: Bool { didSet { savePreferences(); updateRuntime() } }
    @Published var cameraWakeEnabled: Bool { didSet { savePreferences(); updateRuntime() } }
    @Published var idleTimeout: Double { didSet { savePreferences() } }
    @Published var clockBrightness: Double { didSet { savePreferences(); applyBrightness(force: true) } }
    @Published var adaptiveBrightness: Bool { didSet { savePreferences(); applyBrightness(force: true) } }
    @Published var brightnessAdjustment: Double { didSet { savePreferences(); applyBrightness(force: true) } }
    @Published var motionSensitivity: Double { didSet { savePreferences(); camera.motionSensitivity = motionSensitivity } }
    @Published var darknessThreshold: Double { didSet { savePreferences() } }
    @Published private(set) var lightLevel: Double?
    @Published private(set) var isSleeping = false
    @Published private(set) var cameraStatus: PresenceCameraStatus = .stopped
    @Published private(set) var cameraProblem: String?

    private let defaults: UserDefaults
    private let camera = PresenceCamera()
    private var policy = KioskIdlePolicy(now: ProcessInfo.processInfo.systemUptime)
    private var sceneIsActive = false
    private var dashboardVisible = false
    private weak var screen: UIScreen?
    private var savedBrightness: CGFloat?
    private var savedIdleTimerDisabled: Bool?
    private var ignorePresenceUntil: TimeInterval = 0
    private var lastBrightnessChange: TimeInterval = -.infinity
    private var runGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "kiosk.enabled") as? Bool ?? true
        cameraWakeEnabled = defaults.object(forKey: "kiosk.cameraWake") as? Bool ?? true
        let timeout = defaults.double(forKey: "kiosk.idleTimeout")
        idleTimeout = [30.0, 60, 120, 300].contains(timeout) ? timeout : 60
        let brightness = defaults.object(forKey: "kiosk.clockBrightness") as? Double ?? 0.04
        clockBrightness = min(0.2, max(0.01, brightness))
        adaptiveBrightness = defaults.object(forKey: "kiosk.adaptiveBrightness") as? Bool ?? true
        brightnessAdjustment = min(0.25, max(-0.25, defaults.double(forKey: "kiosk.brightnessAdjustment")))
        motionSensitivity = min(1, max(0, defaults.object(forKey: "kiosk.motionSensitivity") as? Double ?? 0.5))
        darknessThreshold = min(0.45, max(0.05, defaults.object(forKey: "kiosk.darknessThreshold") as? Double ?? 0.18))
        camera.motionSensitivity = motionSensitivity
        camera.lightLevelChanged = { [weak self] level in
            guard let self, self.eligible else { return }
            if self.lightLevel == nil || abs((self.lightLevel ?? level) - level) >= 0.03 {
                self.lightLevel = level
            }
            self.applyBrightness(force: false)
        }
        camera.statusChanged = { [weak self] status in
            self?.cameraStatus = status
            switch status {
            case .permissionDenied, .unavailable, .failed:
                self?.cameraProblem = status.description
                self?.lightLevel = nil
                self?.applyBrightness(force: true)
            case .running: self?.cameraProblem = nil
            default: break
            }
        }
        camera.activityDetected = { [weak self] in
            guard let self, self.eligible, self.now >= self.ignorePresenceUntil else { return }
            self.recordActivity()
        }
    }

    func attach(screen: UIScreen) {
        guard self.screen !== screen else { return }
        restoreBrightness()
        self.screen = screen
        applyBrightness(force: true)
    }

    func setContext(active: Bool, dashboardVisible: Bool) {
        let wasEligible = eligible
        sceneIsActive = active
        self.dashboardVisible = dashboardVisible
        if eligible && !wasEligible {
            // The timer cannot update while iOS suspends the app. Returning to
            // the dashboard starts a fresh idle interval, even after a long lock.
            policy.recordActivity(at: now)
        }
        updateRuntime()
    }

    func run() async {
        runGeneration += 1
        let generation = runGeneration
        while !Task.isCancelled {
            updatePolicy()
            synchronizeDisplay()
            do { try await Task.sleep(for: .seconds(1)) }
            catch { break }
        }
        // Also restore if the root view is removed while the scene is active.
        if generation == runGeneration { setContext(active: false, dashboardVisible: false) }
    }

    func recordActivity() {
        guard sceneIsActive else { return }
        policy.recordActivity(at: now)
        synchronizeDisplay()
    }

    func showClock() {
        guard eligible else { return }
        policy.showClock(at: now)
        synchronizeDisplay()
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var eligible: Bool { enabled && sceneIsActive && dashboardVisible }

    private func updatePolicy() {
        policy.update(at: now, idleTimeout: idleTimeout, eligible: eligible,
                      lightLevel: cameraWakeEnabled ? lightLevel : nil,
                      darkThreshold: darknessThreshold)
    }

    private func updateRuntime() {
        if enabled && sceneIsActive {
            if savedIdleTimerDisabled == nil {
                savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let original = savedIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = original
            savedIdleTimerDisabled = nil
        }
        if eligible && cameraWakeEnabled { camera.start() }
        else { camera.stop(); lightLevel = nil }
        updatePolicy()
        synchronizeDisplay()
        applyBrightness(force: true)
    }

    private func synchronizeDisplay() {
        let sleeping = policy.isSleeping && eligible
        guard sleeping != isSleeping else { return }
        isSleeping = sleeping
        // Ignore reflected light from our own screen changing brightness.
        ignorePresenceUntil = now + 3
        camera.recalibrate()
        applyBrightness(force: true)
    }

    private func applyBrightness(force: Bool) {
        guard eligible, let screen else { restoreBrightness(); return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        let target: CGFloat
        if isSleeping {
            target = CGFloat(clockBrightness)
        } else if adaptiveBrightness && cameraWakeEnabled, let lightLevel {
            target = CGFloat(KioskBrightnessPolicy.dashboard(level: lightLevel, adjustment: brightnessAdjustment))
        } else {
            target = savedBrightness ?? screen.brightness
        }
        // Avoid brightness hunting and frequent camera recalibration. Clock
        // brightness remains fixed; only the active dashboard adapts to light.
        guard force || (now - lastBrightnessChange >= 10 && abs(screen.brightness - target) >= 0.04) else { return }
        guard abs(screen.brightness - target) >= 0.005 else { return }
        screen.brightness = target
        lastBrightnessChange = now
        ignorePresenceUntil = now + 3
        camera.recalibrate()
    }

    private func restoreBrightness() {
        if let original = savedBrightness { screen?.brightness = original }
        savedBrightness = nil
    }

    private func savePreferences() {
        defaults.set(enabled, forKey: "kiosk.enabled")
        defaults.set(cameraWakeEnabled, forKey: "kiosk.cameraWake")
        defaults.set(idleTimeout, forKey: "kiosk.idleTimeout")
        defaults.set(clockBrightness, forKey: "kiosk.clockBrightness")
        defaults.set(adaptiveBrightness, forKey: "kiosk.adaptiveBrightness")
        defaults.set(brightnessAdjustment, forKey: "kiosk.brightnessAdjustment")
        defaults.set(motionSensitivity, forKey: "kiosk.motionSensitivity")
        defaults.set(darknessThreshold, forKey: "kiosk.darknessThreshold")
    }
}

struct KioskClockView: View {
    let load: Double
    let updatedAt: Date?
    let online: Bool
    let wake: () -> Void

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.everyMinute) { context in
                let minute = Calendar.current.component(.minute, from: context.date)
                let fresh = online && updatedAt.map { context.date.timeIntervalSince($0) < 90 } == true
                VStack(spacing: 22) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: min(proxy.size.width * 0.26, 260), weight: .light, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: min(proxy.size.width * 0.045, 36), weight: .light))
                    Text(fresh ? "\(Int(load.rounded())) W" : "— W")
                        .font(.system(size: min(proxy.size.width * 0.08, 64), weight: .light, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel(fresh ? "Home consumption \(Int(load.rounded())) watts" : "Home consumption unavailable")
                }
                .foregroundStyle(Color(red: 0.85, green: 0.04, blue: 0.02))
                .offset(x: CGFloat(minute % 3 - 1) * 12, y: CGFloat(minute / 3 % 3 - 1) * 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(30)
            }
        }
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture(perform: wake)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Clock. Open dashboard")
        .accessibilityAction { wake() }
        .ignoresSafeArea()
    }
}

/// Observe touches without participating in gesture recognition. A root SwiftUI
/// zero-distance drag can steal button/scroll touches on older iPadOS versions.
struct KioskScreenReader: UIViewRepresentable {
    let attach: (UIScreen) -> Void
    let activity: () -> Void

    func makeUIView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.attach = attach
        view.activity = activity
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ScreenView, context: Context) {
        uiView.attach = attach
        uiView.activity = activity
    }

    static func dismantleUIView(_ uiView: ScreenView, coordinator: ()) { uiView.detach() }

    final class ScreenView: UIView, UIGestureRecognizerDelegate {
        var attach: ((UIScreen) -> Void)?
        var activity: (() -> Void)?
        private weak var observedWindow: UIWindow?
        private lazy var observer: UIGestureRecognizer = {
            let recognizer = UIGestureRecognizer()
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            observedWindow = window
            window.addGestureRecognizer(observer)
            let screen = window.screen
            DispatchQueue.main.async { [weak self] in self?.attach?(screen) }
        }

        func detach() {
            observedWindow?.removeGestureRecognizer(observer)
            observedWindow = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            activity?()
            // Returning false leaves all touch delivery and recognition to the
            // app's buttons, scrolling and zoom gestures.
            return false
        }
    }
}

struct KioskSettingsSection: View {
    @ObservedObject var kiosk: KioskController
    let preview: () -> Void

    var body: some View {
        Section {
            Toggle("Dim clock when idle", isOn: $kiosk.enabled)
            if kiosk.enabled {
                Toggle("Motion wake with front camera", isOn: $kiosk.cameraWakeEnabled)
                if kiosk.cameraWakeEnabled {
                    VStack(alignment: .leading) {
                        Text("Darkness threshold: \(Int(kiosk.darknessThreshold * 100))%")
                        Slider(value: $kiosk.darknessThreshold, in: 0.05...0.45, step: 0.01)
                            .accessibilityLabel("Darkness threshold")
                        Text("Shows the clock after 3 seconds of darkness. Move or tap to wake; the usual idle timeout then applies.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Brightness follows room light", isOn: $kiosk.adaptiveBrightness)
                    if kiosk.adaptiveBrightness {
                        VStack(alignment: .leading) {
                            Text("Dashboard brightness adjustment")
                            Slider(value: $kiosk.brightnessAdjustment, in: -0.25...0.25, step: 0.01)
                                .accessibilityLabel("Dashboard brightness adjustment")
                            Text("Darker ← → Brighter").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Motion sensitivity: \(Int(kiosk.motionSensitivity * 100))%")
                        Slider(value: $kiosk.motionSensitivity, in: 0...1, step: 0.05)
                            .accessibilityLabel("Motion sensitivity")
                    }
                }
                Picker("Show clock after", selection: $kiosk.idleTimeout) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                VStack(alignment: .leading) {
                    Text("Clock brightness: \(Int(kiosk.clockBrightness * 100))%")
                    Slider(value: $kiosk.clockBrightness, in: 0.01...0.2, step: 0.01)
                        .accessibilityLabel("Clock brightness")
                }
                Button("Show clock now", action: preview)
                if kiosk.cameraWakeEnabled {
                    Text("Compares a tiny brightness grid about once a second. No face recognition, video recording or uploads. Movement wakes the dashboard; a still person may let it dim. The green camera indicator stays visible.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let problem = kiosk.cameraProblem {
                        Text(problem)
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Clock & presence")
        } footer: {
            Text("Idle mode shows only red time, date and home consumption on black. Consumption refreshes every 30 seconds; the clock updates once a minute. Tap wakes immediately. Clock mode pauses outside the dashboard; original brightness returns when leaving it.")
        }
    }
}
