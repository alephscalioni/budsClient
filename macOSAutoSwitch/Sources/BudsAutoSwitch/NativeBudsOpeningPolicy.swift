import Foundation

/// On macOS a fresh SDP request can remain pending even when the cached SMEP
/// channel works. Prefer that paired service record, refreshing only after an
/// explicit channel failure. A deadline never cancels an SDK operation, so it
/// must not start another operation on top of the unfinished one.
struct NativeBudsOpeningPolicy {
    enum Phase: String { case idle, bluetooth, discovery, channel, open, failed }
    enum Action: Equatable { case queryService, openChannel(UInt8), fail }
    private(set) var phase: Phase = .idle
    private(set) var channelAttempts = 0
    private var cachedChannel: UInt8?
    private var discoveryUsed = false

    mutating func begin(cachedChannel: UInt8?, bluetoothConnected: Bool) {
        self = Self()
        self.cachedChannel = cachedChannel.flatMap { (1...30).contains($0) ? $0 : nil }
        if bluetoothConnected { _ = nextServiceAction() }
        else { phase = .bluetooth }
    }
    var serviceAction: Action {
        if phase == .channel, let cachedChannel { return .openChannel(cachedChannel) }
        return .queryService
    }
    var timeout: TimeInterval {
        switch phase {
        case .bluetooth: return 10
        case .discovery: return 4
        case .channel: return 8
        default: return 0
        }
    }
    mutating func bluetoothCompleted(success: Bool) -> Action {
        guard phase == .bluetooth else { return .fail }
        guard success else { phase = .failed; return .fail }
        return nextServiceAction()
    }
    mutating func discoveryCompleted(channel: UInt8?) -> Action {
        guard phase == .discovery else { return .fail }
        if let channel, (1...30).contains(channel) {
            phase = .channel; channelAttempts += 1
            return .openChannel(channel)
        }
        phase = .failed
        return .fail
    }
    mutating func channelCompleted(success: Bool) -> Action? {
        guard phase == .channel else { return .fail }
        if success { phase = .open; return nil }
        guard !discoveryUsed else { phase = .failed; return .fail }
        discoveryUsed = true; phase = .discovery
        return .queryService
    }
    mutating func timedOut() -> Action {
        phase = .failed
        return .fail
    }
    private mutating func nextServiceAction() -> Action {
        if let cachedChannel {
            phase = .channel; channelAttempts += 1
            return .openChannel(cachedChannel)
        }
        discoveryUsed = true; phase = .discovery
        return .queryService
    }
}
