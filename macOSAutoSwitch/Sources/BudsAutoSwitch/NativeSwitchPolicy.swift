import Foundation

/// Valid vendor state belongs to a channel session, not to a four-second timer.
/// Duplicate notifications do not create state transitions. A valid duplicate
/// received after a request can confirm an idempotent foreground response, but
/// still requires a fresh radio check and a verified HAL route in the controller.
struct NativeSwitchEvidence {
    static var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    private(set) var status: SamsungMdePacket.MultipointStatus?
    private(set) var observedAt: TimeInterval = -.infinity
    private(set) var serial: UInt64 = 0
    private(set) var notificationCount: UInt64 = 0
    private var notificationObservedAt: TimeInterval = -.infinity
    private(set) var backgroundStreamRejected = false
    private var previousPlaying: Bool?
    private var previousRevision: UInt64?
    var callActive: Bool { status?.isCall == true }

    mutating func resetVendorState() {
        status = nil; observedAt = -.infinity; serial = 0; notificationCount = 0; notificationObservedAt = -.infinity
        backgroundStreamRejected = false
    }

    @discardableResult mutating func observe(_ value: SamsungMdePacket.MultipointStatus, at now: TimeInterval) -> Bool {
        guard now.isFinite, now >= observedAt else { return false }
        notificationCount &+= 1; notificationObservedAt = now
        guard value != status else { return false }
        // EasyConnect2 OnBackground also requires a non-NULL prior status.
        backgroundStreamRejected = status != nil && value.rejectsBackgroundStream
        status = value; observedAt = now; serial &+= 1
        return true
    }
    func fresh(at now: TimeInterval) -> Bool { status != nil && now >= observedAt }
    func confirmsMac(after serial: UInt64, afterNotification: UInt64? = nil, at now: TimeInterval) -> Bool {
        let notified = self.serial > serial || afterNotification.map { notificationCount > $0 && now >= notificationObservedAt } == true
        return fresh(at: now) && notified && status?.state == .foreground && !callActive
    }
    var remoteStream: Bool {
        guard let status, status.state == .background else { return false }
        return !status.streamType.intersection([.a2dp, .hfp, .cisMedia, .cisCall, .bis]).isEmpty
    }
    mutating func playEdge(playing: Bool, revision: UInt64, trustworthy: Bool = true) -> Bool {
        // An unknown MediaRemote read plus a retained HAL stream is not a new
        // user play. It must not replace the explicit pause baseline or arm a
        // request that fires later at the end of the loss cooldown.
        guard trustworthy else { return false }
        defer { previousPlaying = playing; previousRevision = revision }
        guard let previousPlaying else { return false }
        return playing && (!previousPlaying || previousRevision != revision)
    }
}

struct NativeSwitchRecoveryPolicy {
    private(set) var failures = 0
    mutating func nextDelay() -> TimeInterval {
        failures = min(failures + 1, 6)
        return min(pow(2, Double(failures - 1)), 30)
    }
    mutating func stable() { failures = 0 }
    static let handoffTimeout: TimeInterval = 12
    static let audioLossCooldown: TimeInterval = 3
}

/// User route/guard changes need a new explicit start, not an automatic re-arm.
struct NativeSwitchSafetyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
