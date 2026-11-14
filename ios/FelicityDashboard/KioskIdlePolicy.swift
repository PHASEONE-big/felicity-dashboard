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

    init(now: TimeInterval) {
        lastActivity = now
    }

    mutating func recordActivity(at now: TimeInterval) {
        // A delayed callback must not move the inactivity deadline backwards.
        lastActivity = max(lastActivity, now)
        isSleeping = false
    }

    mutating func update(at now: TimeInterval, idleTimeout: TimeInterval, eligible: Bool) {
        guard eligible else {
            recordActivity(at: now)
            return
        }
        guard !isSleeping else { return }
        let elapsed = max(0, now - lastActivity)
        if elapsed >= max(0, idleTimeout) {
            isSleeping = true
        }
    }

    mutating func showClock(at now: TimeInterval) {
        lastActivity = max(lastActivity, now)
        isSleeping = true
    }
}
