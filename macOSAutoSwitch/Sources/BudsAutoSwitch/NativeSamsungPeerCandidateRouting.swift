import Foundation

/// Host calls these only after its pinned GCM decision. Routing never proves identity.
@MainActor protocol NativeSamsungPeerCandidateRouting: AnyObject {
    func expectedPeerAuthenticated()
    func rejectUnexpectedPeerCandidate() -> Bool
}

/// Process-local routing hints, keyed ONLY by the host's expected Samsung address.
/// Never persist or include this state in diagnostics. UUIDs are CB routing hints.
@MainActor final class NativeSamsungPeerCandidateCache {
    private struct Hint { let id: UUID; let at: TimeInterval; let order: UInt64 }
    private struct Target {
        var preferred: Hint?
        var excluded: [UUID: Hint] = [:]
        var order: UInt64
    }
    private let monotonic: () -> TimeInterval
    private var targets: [SamsungPeerAddress: Target] = [:]
    private var sequence: UInt64 = 0
    private var lastTime: TimeInterval?
    init(monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.monotonic = monotonic
    }
    private func prune() -> TimeInterval? {
        let now = monotonic()
        guard now.isFinite else { targets.removeAll(); return nil }
        if let lastTime, now < lastTime { targets.removeAll() }
        lastTime = now
        for (key, var target) in targets {
            if let hint = target.preferred, now - hint.at >= 60 { target.preferred = nil }
            target.excluded = target.excluded.filter { now - $0.value.at < 60 }
            if target.preferred == nil && target.excluded.isEmpty { targets.removeValue(forKey: key) }
            else { targets[key] = target }
        }
        return now
    }
    func preferredIdentifier(expectedSamsungPeerAddress: SamsungPeerAddress) -> UUID? {
        guard prune() != nil else { return nil }
        return targets[expectedSamsungPeerAddress]?.preferred?.id
    }
    func isExcluded(_ identifier: UUID, expectedSamsungPeerAddress: SamsungPeerAddress) -> Bool {
        guard prune() != nil else { return false }
        return targets[expectedSamsungPeerAddress]?.excluded[identifier] != nil
    }
    /// Only the host's successful expected-peer authentication may learn a hint.
    func expectedPeerAuthenticated(expectedSamsungPeerAddress: SamsungPeerAddress, routingIdentifier: UUID) {
        guard let now = prune() else { return }
        sequence += 1
        var target = targets[expectedSamsungPeerAddress] ?? Target(order: sequence)
        target.preferred = Hint(id: routingIdentifier, at: now, order: sequence)
        target.excluded.removeValue(forKey: routingIdentifier)
        save(target, for: expectedSamsungPeerAddress)
    }
    /// Only a known wrong peer from GCM may exclude a route for this target.
    /// False also fences repeated rejection of the same mapping.
    func rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: SamsungPeerAddress, routingIdentifier: UUID) -> Bool {
        guard let now = prune(), targets[expectedSamsungPeerAddress]?.excluded[routingIdentifier] == nil else { return false }
        sequence += 1
        var target = targets[expectedSamsungPeerAddress] ?? Target(order: sequence)
        if target.preferred?.id == routingIdentifier { target.preferred = nil }
        target.excluded[routingIdentifier] = Hint(id: routingIdentifier, at: now, order: sequence)
        save(target, for: expectedSamsungPeerAddress)
        return true
    }
    private func save(_ value: Target, for address: SamsungPeerAddress) {
        var target = value; target.order = sequence
        while target.excluded.count + (target.preferred == nil ? 0 : 1) > 16 {
            guard let oldest = target.excluded.min(by: { $0.value.order < $1.value.order })?.key else { break }
            target.excluded.removeValue(forKey: oldest)
        }
        targets[address] = target
        while targets.count > 16 {
            guard let oldest = targets.min(by: { $0.value.order < $1.value.order })?.key else { break }
            targets.removeValue(forKey: oldest)
        }
    }
}

/// Pure scan ordering. All returned tokens remain untrusted; one token per lease.
struct NativeSamsungPeerCandidateSelection {
    private var startedAt: TimeInterval?
    private var pending: [(token: UUID, identifier: UUID)] = []
    private var selected = false
    mutating func begin(now: TimeInterval) { if startedAt == nil { startedAt = now } }
    mutating func offer(token: UUID, identifier: UUID, now: TimeInterval,
                        preferred: UUID?, isTemporarilyUnavailable: (UUID) -> Bool = { _ in false },
                        isExcluded: (UUID) -> Bool) -> UUID? {
        guard !selected, !isExcluded(identifier) else { return nil }
        let limit = preferred != nil && preferred != identifier ? 15 : 16
        if !pending.contains(where: { $0.identifier == identifier }), pending.count < limit {
            pending.append((token, identifier))
        }
        return poll(now: now, preferred: preferred, isTemporarilyUnavailable: isTemporarilyUnavailable,
                    isExcluded: isExcluded)
    }
    mutating func poll(now: TimeInterval, preferred: UUID?,
                       isTemporarilyUnavailable: (UUID) -> Bool = { _ in false },
                       isExcluded: (UUID) -> Bool) -> UUID? {
        guard !selected, let startedAt, now.isFinite, now >= startedAt else { return nil }
        pending.removeAll { isExcluded($0.identifier) }
        let available = pending.filter { !isTemporarilyUnavailable($0.identifier) }
        let candidate: (token: UUID, identifier: UUID)?
        if let preferred, let match = available.first(where: { $0.identifier == preferred }) { candidate = match }
        else if preferred == nil || now - startedAt >= 1 { candidate = available.first }
        else { candidate = nil }
        guard let candidate else { return nil }
        selected = true; pending.removeAll()
        return candidate.token
    }
}
