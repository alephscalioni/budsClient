import Foundation

/// HAL is only a reason to release an idle pre-arm, never acquisition intent.
/// The caller must verify guard ownership and the waiting route before restore.
struct NativeUnknownPlaybackGuardPolicy {
    static let settlingWindow: TimeInterval = 2
    private(set) var startedAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    var isObserving: Bool { startedAt != nil }

    mutating func reset() { startedAt = nil; lastObservedAt = nil }

    mutating func observe(at now: TimeInterval, halOutput: Bool,
                          mediaPlaying: Bool?, eligible: Bool) -> Bool {
        guard eligible, halOutput, mediaPlaying != true, now.isFinite else {
            reset(); return false
        }
        if let lastObservedAt, now < lastObservedAt { reset() }
        lastObservedAt = now
        if startedAt == nil { startedAt = now }
        return now - startedAt! >= Self.settlingWindow
    }
}
