import Foundation

/// Closed public diagnostic vocabulary. No names, UUIDs, addresses, keys,
/// fingerprints, raw advertisements or SDK error descriptions are serialized.
public struct NativeSamsungBlePeerDiagnostics: Codable, Equatable {
    public enum Phase: String, Codable { case idle, waitingForPower, discovering, connecting, opening, channelOpen, cancelling, closed }
    public enum Reason: String, Error, Codable {
        case cancelled, discoveryDeadline, connectDeadline, channelDeadline, unavailable
        case connectionFailed, channelFailed, disconnected, invalidState, peerDraining
        case bufferLimit, streamFailure, invalidClock, invalidConfiguration, candidateRejected
    }
    public let phase: Phase
    public let reason: Reason?
    public let candidates: Int
    public let rejected: Int
    public let channelsOpened: Int
    public let authenticated: Bool // always false: host SamsungPeerSession owns authentication
}

/// UUID is an opaque routing handle only. It is never a Bluetooth address,
/// roster identity, account proof or public diagnostic field.
struct NativeSamsungBlePeerLease: Hashable {
    let generation: UInt64
    let peripheral: UUID
}

struct NativeSamsungBlePeerPolicy {
    typealias Reason = NativeSamsungBlePeerDiagnostics.Reason
    typealias Phase = NativeSamsungBlePeerDiagnostics.Phase
    struct Budgets {
        var discovery: TimeInterval = 15
        var connect: TimeInterval = 10
        var channel: TimeInterval = 10
        func validate() throws {
            guard [discovery, connect, channel].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 60 }) else { throw Reason.invalidConfiguration }
        }
    }
    enum Effect: Equatable {
        case initializeCentral, scan, stopScan
        case connect(NativeSamsungBlePeerLease)
        case open(NativeSamsungBlePeerLease, UInt16)
        case cancel(NativeSamsungBlePeerLease)
        case closeStream(UUID)
        case ready(NativeSamsungBlePeerLease, UUID)
    }
    private struct Attempt {
        let lease: NativeSamsungBlePeerLease
        let psm: UInt16
        var pendingOpen = false
        var cancelAck = false
        var cancelling = false
        var stream: UUID?
    }
    private(set) var phase: Phase = .idle
    private(set) var reason: Reason?
    private(set) var active: NativeSamsungBlePeerLease?
    private var attempts: [NativeSamsungBlePeerLease: Attempt] = [:]
    private var generation: UInt64 = 0
    private var deadline: TimeInterval?
    private var lastTime: TimeInterval?
    private let budgets: Budgets
    private(set) var channelsOpened = 0
    init(budgets: Budgets = .init()) throws { try budgets.validate(); self.budgets = budgets }

    mutating func begin(now: TimeInterval) throws -> [Effect] {
        try clock(now)
        guard active == nil, [.idle, .closed].contains(phase) else { throw Reason.invalidState }
        phase = .waitingForPower; reason = nil; deadline = now + budgets.discovery
        return [.initializeCentral]
    }
    mutating func power(_ poweredOn: Bool, now: TimeInterval) throws -> [Effect] {
        try clock(now)
        if !poweredOn { return stop(.unavailable) }
        guard phase == .waitingForPower else { return [] }
        if let deadline, now >= deadline { return stop(.discoveryDeadline) }
        phase = .discovering; return [.scan]
    }
    mutating func connect(peripheral: UUID, psm: UInt16, now: TimeInterval) throws -> [Effect] {
        try clock(now)
        guard phase == .discovering else { throw Reason.invalidState }
        guard let deadline, now < deadline else { return stop(.discoveryDeadline) }
        guard (0x80...0xff).contains(psm) else { throw Reason.candidateRejected }
        guard !attempts.values.contains(where: { $0.lease.peripheral == peripheral }) else { throw Reason.peerDraining }
        guard generation < UInt64.max else { throw Reason.invalidState }
        generation += 1
        let lease = NativeSamsungBlePeerLease(generation: generation, peripheral: peripheral)
        attempts[lease] = Attempt(lease: lease, psm: psm); active = lease
        phase = .connecting; self.deadline = now + budgets.connect
        return [.stopScan, .connect(lease)]
    }
    mutating func connected(_ lease: NativeSamsungBlePeerLease, now: TimeInterval) throws -> [Effect] {
        guard var attempt = attempts[lease] else { return [] }
        guard active == lease, !attempt.cancelling, phase == .connecting else { return [] }
        try clock(now)
        guard let deadline, now < deadline else { return stop(.connectDeadline) }
        attempt.pendingOpen = true; attempts[lease] = attempt
        phase = .opening; self.deadline = now + budgets.channel
        return [.open(lease, attempt.psm)]
    }
    mutating func opened(_ lease: NativeSamsungBlePeerLease, stream: UUID?, psm: UInt16?, now: TimeInterval) throws -> [Effect] {
        // Even late callbacks with a bad clock can only close the returned stream.
        guard var attempt = attempts[lease], attempt.pendingOpen else {
            if let stream, attempts.values.contains(where: { $0.stream == stream }) { return [] }
            return stream.map { [.closeStream($0)] } ?? []
        }
        attempt.pendingOpen = false; attempts[lease] = attempt
        guard active == lease, !attempt.cancelling else {
            releaseIfDrained(lease)
            return stream.map { [.closeStream($0)] } ?? []
        }
        guard now.isFinite, lastTime.map({ now >= $0 }) ?? true else {
            return (stream.map { [.closeStream($0)] } ?? []) + stop(.invalidClock)
        }
        try clock(now)
        guard let deadline, now < deadline else {
            return (stream.map { [.closeStream($0)] } ?? []) + stop(.channelDeadline)
        }
        guard let stream, psm == attempt.psm else {
            return (stream.map { [.closeStream($0)] } ?? []) + stop(.channelFailed)
        }
        attempt.stream = stream; attempts[lease] = attempt
        phase = .channelOpen; self.deadline = nil; channelsOpened += 1
        return [.ready(lease, stream)]
    }
    mutating func terminal(_ lease: NativeSamsungBlePeerLease, failedToConnect: Bool = false) -> [Effect] {
        guard var attempt = attempts[lease] else { return [] }
        var effects: [Effect] = []
        if let stream = attempt.stream { effects.append(.closeStream(stream)); attempt.stream = nil }
        attempt.cancelAck = true; attempt.cancelling = true; attempts[lease] = attempt
        if active == lease {
            active = nil; deadline = nil; phase = .closed
            if reason == nil { reason = failedToConnect ? .connectionFailed : .disconnected }
        }
        releaseIfDrained(lease)
        return effects
    }
    mutating func poll(now: TimeInterval) throws -> [Effect] {
        try clock(now)
        guard let deadline, now >= deadline else { return [] }
        switch phase {
        case .waitingForPower, .discovering: return stop(.discoveryDeadline)
        case .connecting: return stop(.connectDeadline)
        case .opening: return stop(.channelDeadline)
        default: return []
        }
    }
    mutating func stop(_ why: Reason = .cancelled) -> [Effect] {
        var effects: [Effect] = [.stopScan]
        reason = why; deadline = nil
        if let active, var attempt = attempts[active] {
            if let stream = attempt.stream { effects.append(.closeStream(stream)); attempt.stream = nil }
            if !attempt.cancelling { effects.append(.cancel(active)) }
            attempt.cancelling = true; attempts[active] = attempt
            phase = .cancelling
        } else { phase = .closed }
        return effects
    }
    func owns(_ lease: NativeSamsungBlePeerLease, stream: UUID) -> Bool {
        active == lease && phase == .channelOpen && attempts[lease]?.stream == stream
    }
    func isDraining(_ peripheral: UUID) -> Bool { attempts.values.contains { $0.lease.peripheral == peripheral } }
    private mutating func releaseIfDrained(_ lease: NativeSamsungBlePeerLease) {
        guard let a = attempts[lease], a.cancelAck, !a.pendingOpen else { return }
        attempts.removeValue(forKey: lease)
    }
    private mutating func clock(_ now: TimeInterval) throws {
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else { throw Reason.invalidClock }
        lastTime = now
    }
}

/// Bounded owned buffers. A synchronous writer consumes only its reported prefix;
/// zero means backpressure. Host reads raw stream chunks and frames with
/// SamsungPeerWire.FrameDecoder. No read boundary is a protobuf boundary.
struct NativeSamsungBlePeerStreamBuffer {
    typealias Reason = NativeSamsungBlePeerDiagnostics.Reason
    private var outgoing = Data()
    private var incoming = Data()
    let limit: Int
    init(limit: Int = 65_536) throws {
        guard (1...1_048_576).contains(limit) else { throw Reason.invalidConfiguration }
        self.limit = limit
    }
    var pendingWriteBytes: Int { outgoing.count }
    var pendingReadBytes: Int { incoming.count }
    mutating func enqueue(_ bytes: Data) throws {
        guard bytes.count <= limit - outgoing.count else { throw Reason.bufferLimit }
        outgoing.append(bytes)
    }
    mutating func receive(_ bytes: Data) throws {
        guard bytes.count <= limit - incoming.count else { throw Reason.bufferLimit }
        incoming.append(bytes)
    }
    mutating func takeReceived(maximum: Int = 4096) -> Data {
        guard maximum > 0 else { return Data() }
        let n = min(maximum, incoming.count), data = Data(incoming.prefix(n))
        incoming.removeFirst(n); return data
    }
    mutating func pump(hasSpace: () -> Bool, write: (Data) -> Int) throws {
        for _ in 0..<16 {
            guard !outgoing.isEmpty, hasSpace() else { return }
            let offered = Data(outgoing.prefix(4096)), n = write(offered)
            guard n >= 0, n <= offered.count else { throw Reason.streamFailure }
            if n == 0 { return }
            outgoing.removeFirst(n)
        }
    }
}
