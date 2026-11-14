import Foundation

/// Relative camera light is not a lux measurement. Keep night wake comfortable
/// and cap the backlight, with a user adjustment for the installation location.
enum KioskBrightnessPolicy {
    static func dashboard(level: Double, adjustment: Double) -> Double {
        let light = level.isFinite ? min(1, max(0, level)) : 0.5
        let offset = adjustment.isFinite ? min(0.25, max(-0.25, adjustment)) : 0
        return min(0.85, max(0.05, 0.06 + 0.68 * light * light + offset))
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
