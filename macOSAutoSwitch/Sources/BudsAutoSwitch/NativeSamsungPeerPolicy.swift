import Foundation

/// Host assertion, not enrollment: the host has independently verified a Classic
/// PHONE address in a legitimate current roster. Never construct from UI/HTTP JSON,
/// a Buds address, BLE peripheral UUID, or an unresolved private address.
struct NativeSamsungPeerVerifiedAddress: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let address: SamsungPeerAddress
    init(hostVerifiedClassicPhone address: SamsungPeerAddress, roster: SamsungPeerRoster) throws {
        guard roster.contains(address), address.bytes.contains(where: { $0 != 0 }),
              address.bytes.contains(where: { $0 != 255 }) else { throw NativeSamsungPeerFailure.invalidPeer }
        self.address = address
    }
    var description: String { "NativeSamsungPeerVerifiedAddress(redacted)" }
    var debugDescription: String { description }
}

enum NativeSamsungPeerFailure: String, Error, Codable {
    case invalidPeer, invalidConfiguration, peerDraining, busy, cancelled, closed
    case openingDeadline, writeDeadline, aclFailed, sdpFailed, serviceUnavailable
    case channelFailed, profileCloseFailed, invalidMTU, writeFailed, malformedStream, receiveLimit, invalidPacket
}

struct NativeSamsungPeerDiagnostics: Codable, Equatable {
    enum Phase: String, Codable { case idle, acl, sdp, channel, openUntrusted, failed, closed }
    var phase: Phase = .idle
    var failure: NativeSamsungPeerFailure?
    var receivedBytes = 0
    var receivedPackets = 0
    var completedPackets = 0
    var completedChunks = 0
    var pendingOperations = 0
}

/// Pure total-budget policy: no retries, channel guesses or timeout extensions.
struct NativeSamsungPeerOpeningPolicy {
    private(set) var phase: NativeSamsungPeerDiagnostics.Phase = .acl
    let deadline: TimeInterval
    init(now: TimeInterval, budget: TimeInterval) throws {
        guard now.isFinite, budget.isFinite, budget > 0, budget <= 120, (now + budget).isFinite else {
            throw NativeSamsungPeerFailure.invalidConfiguration
        }
        deadline = now + budget
    }
    func check(now: TimeInterval) throws {
        guard now.isFinite, now < deadline else { throw NativeSamsungPeerFailure.openingDeadline }
    }
    mutating func connected(now: TimeInterval) throws { try check(now: now); phase = .sdp }
    mutating func discovered(recordChannel: UInt8?, now: TimeInterval) throws -> UInt8 {
        try check(now: now)
        guard let id = recordChannel, (1...30).contains(id) else { throw NativeSamsungPeerFailure.serviceUnavailable }
        phase = .channel; return id
    }
    mutating func opened(mtu: Int, now: TimeInterval) throws {
        try check(now: now)
        guard (1...65535).contains(mtu) else { throw NativeSamsungPeerFailure.invalidMTU }
        phase = .openUntrusted
    }
}

/// A packet has one deadline across ALL MTU chunks; one chunk can be in flight.
struct NativeSamsungPeerWritePolicy {
    let count: Int
    let mtu: Int
    let deadline: TimeInterval
    private(set) var offset = 0
    private(set) var pending: (id: UInt, count: Int)?
    init(count: Int, mtu: Int, now: TimeInterval, budget: TimeInterval) throws {
        guard count > 0, count <= 1_048_586, (1...65535).contains(mtu), now.isFinite,
              budget.isFinite, budget > 0, budget <= 120, (now + budget).isFinite else {
            throw NativeSamsungPeerFailure.invalidConfiguration
        }
        self.count = count; self.mtu = mtu; deadline = now + budget
    }
    var finished: Bool { offset == count && pending == nil }
    mutating func next(id: UInt, now: TimeInterval) throws -> Range<Int>? {
        try check(now: now)
        guard pending == nil else { throw NativeSamsungPeerFailure.busy }
        guard offset < count else { return nil }
        let range = offset..<min(offset + mtu, count)
        pending = (id, range.count); return range
    }
    /// Unknown/duplicate IDs cannot complete the active chunk.
    mutating func complete(id: UInt, success: Bool, bytesWritten: Int?, now: TimeInterval) throws -> Bool {
        guard let pending, pending.id == id else { return false }
        try check(now: now)
        guard success, bytesWritten == nil || bytesWritten == pending.count else { throw NativeSamsungPeerFailure.writeFailed }
        offset += pending.count; self.pending = nil; return true
    }
    func check(now: TimeInterval) throws {
        guard now.isFinite, now < deadline else { throw NativeSamsungPeerFailure.writeDeadline }
    }
}
