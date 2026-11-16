import Foundation

/// Apply the selected display brightness directly; ambient light chooses a mode
/// rather than silently reducing the user's chosen value.
enum KioskBrightnessPolicy {
    static func dashboard(isNight: Bool, day: Double, night: Double, adaptive: Bool) -> Double {
        bounded(adaptive && isNight ? night : day, minimum: 0.05)
    }

    static func clock(isNight: Bool, day: Double, night: Double) -> Double {
        bounded(isNight ? night : day, minimum: 0.01)
    }

    private static func bounded(_ value: Double, minimum: Double) -> Double {
        min(1, max(minimum, value.isFinite ? value : minimum))
    }
}

/// Hysteresis keeps small camera fluctuations from changing color/brightness.
struct KioskLightMode {
    private(set) var isNight = false

    mutating func update(level: Double?, darkThreshold: Double) {
        guard let level, level.isFinite, (0...1).contains(level), darkThreshold.isFinite else { return }
        let threshold = min(1, max(0, darkThreshold))
        if isNight {
            if level >= min(1, threshold + 0.06) { isNight = false }
        } else if level < threshold {
            isNight = true
        }
    }
}

/// The kiosk's idle state, driven by monotonic uptime rather than wall-clock time.
struct KioskIdlePolicy {
    private(set) var isSleeping = false
    private(set) var lastActivity: TimeInterval
    private var darknessStartedAt: TimeInterval?
    private var darknessConsumed = false

    init(now: TimeInterval) {
        lastActivity = now
    }

    mutating func recordActivity(at now: TimeInterval) {
        // A delayed callback must not move the inactivity deadline backwards.
        lastActivity = max(lastActivity, now)
        if isSleeping, darknessStartedAt != nil {
            darknessConsumed = true
        }
        isSleeping = false
    }

    mutating func update(
        at now: TimeInterval,
        idleTimeout: TimeInterval,
        eligible: Bool,
        lightLevel: Double? = nil,
        darkThreshold: Double = 0.18
    ) {
        guard eligible else {
            resetDarkness()
            recordActivity(at: now)
            return
        }
        // Track light even while sleeping: a touch wake in the same dark room
        // must get a full idle interval instead of immediately showing the clock.
        if let lightLevel, lightLevel.isFinite {
            let threshold = darkThreshold.isFinite ? min(1, max(0, darkThreshold)) : 0.18
            if lightLevel >= min(1, threshold + 0.06) {
                resetDarkness()
            } else if lightLevel <= threshold, darknessStartedAt == nil {
                darknessStartedAt = max(now, lastActivity)
                darknessConsumed = isSleeping
            }
            if let start = darknessStartedAt, !darknessConsumed, now - start >= 3 {
                // Ignore activity during the transition itself (for example,
                // moving a hand over the camera), but trigger only once.
                darknessConsumed = true
                isSleeping = true
            }
        } else {
            resetDarkness()
        }
        guard !isSleeping else { return }
        let elapsed = max(0, now - lastActivity)
        if elapsed >= max(0, idleTimeout) {
            isSleeping = true
        }
    }

    mutating func showClock(at now: TimeInterval) {
        lastActivity = max(lastActivity, now)
        if darknessStartedAt != nil { darknessConsumed = true }
        isSleeping = true
    }

    private mutating func resetDarkness() {
        darknessStartedAt = nil
        darknessConsumed = false
    }
}
