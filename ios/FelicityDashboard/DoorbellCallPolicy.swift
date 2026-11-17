import Foundation

/// Call deadlines use a monotonic clock supplied by the controller. This value
/// owns no timers or media; the controller stops audio/video when it closes.
struct DoorbellCallPolicy: Equatable, Sendable {
    private(set) var isPresenting = false
    private(set) var microphoneActive = false
    private(set) var deadline: TimeInterval?
    private var lastAcceptedRing: TimeInterval?

    @discardableResult
    mutating func ring(at now: TimeInterval) -> Bool {
        if let lastAcceptedRing, now - lastAcceptedRing < 5 { return false }
        lastAcceptedRing = now
        isPresenting = true
        microphoneActive = false
        deadline = now + 60
        return true
    }

    /// An explicit thumbnail tap is not a new ring and bypasses its dedup guard.
    mutating func openPreview(at now: TimeInterval) {
        isPresenting = true
        microphoneActive = false
        deadline = now + 60
    }

    mutating func beginTalking(at now: TimeInterval) {
        guard isPresenting, !microphoneActive else { return }
        microphoneActive = true
        deadline = now + 30
    }

    mutating func endTalking(at now: TimeInterval) {
        guard isPresenting, microphoneActive else { return }
        microphoneActive = false
        deadline = now + 60
    }

    mutating func close() {
        isPresenting = false
        microphoneActive = false
        deadline = nil
    }

    /// Returns true only for the tick that closes an expired call.
    @discardableResult
    mutating func update(at now: TimeInterval) -> Bool {
        guard isPresenting, let deadline, now >= deadline else { return false }
        close()
        return true
    }
}
