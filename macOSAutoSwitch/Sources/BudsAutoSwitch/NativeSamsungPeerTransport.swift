import Foundation

/// Captured expected identity is routing context, never authenticated provenance.
struct NativeSamsungPeerUntrustedPacket: CustomStringConvertible, CustomDebugStringConvertible {
    enum Trust { case untrustedUntilSamsungPeerSessionValidation }
    let expectedPeer: NativeSamsungPeerVerifiedAddress
    let packet: SamsungPeerWire.Packet
    let trust: Trust = .untrustedUntilSamsungPeerSessionValidation
    var description: String { "NativeSamsungPeerUntrustedPacket(redacted)" }
    var debugDescription: String { description }
}

/// Explicit outgoing-only foundation. No default startup, discovery advertising,
/// session/key provisioning, UI, Cloud, Keychain or headset coupling.
@MainActor final class NativeSamsungPeerTransport {
    static let serviceUUID = "3A622E58-C035-4A26-928C-5601DDE7C657"
    private let effects: any NativeSamsungPeerEffects
    private let clock: any NativeSamsungPeerClock
    private let drain: NativeSamsungPeerOperationDrain
    private var lease: NativeSamsungPeerLease?
    /// Concrete hosts share peer ownership across all transport instances.
    convenience init(effects: any NativeSamsungPeerEffects, clock: any NativeSamsungPeerClock) {
        self.init(effects: effects, clock: clock, drain: .shared)
    }
    /// A non-shared drain is for isolated fake tests only.
    init(effects: any NativeSamsungPeerEffects, clock: any NativeSamsungPeerClock,
         drain: NativeSamsungPeerOperationDrain) {
        self.effects = effects; self.clock = clock; self.drain = drain
    }
    var diagnostics: NativeSamsungPeerDiagnostics { lease?.diagnostics ?? .init() }
    var isOpen: Bool { lease?.diagnostics.phase == .openUntrusted }

    /// Callbacks are captured for this lease, never looked up from a newer session.
    /// onTermination must close the host SamsungPeerSession, including mid-handshake.
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval = 15,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {
        try Task.checkCancellation()
        guard lease?.active != true else { throw NativeSamsungPeerFailure.busy }
        let next = try NativeSamsungPeerLease(peer: peer, effects: effects, clock: clock,
                                             drain: drain, budget: openingBudget,
                                             onPacket: onUntrustedPacket, onTermination: onTermination)
        try drain.acquire(peer, id: next.id, owner: next)
        lease = next
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { next.stop(.cancelled); c.resume(throwing: NativeSamsungPeerFailure.cancelled) }
                else { next.begin(c) }
            }
        } onCancel: { Task { @MainActor in next.stop(.cancelled) } }
        try Task.checkCancellation()
    }
    /// Local SDK completion of ALL chunks, not delivery, auth or Samsung acknowledgment.
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval = 5) async throws {
        try Task.checkCancellation()
        guard let captured = lease else { throw NativeSamsungPeerFailure.closed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { captured.stop(.cancelled); c.resume(throwing: NativeSamsungPeerFailure.cancelled) }
                else { captured.send(packet, budget: budget, continuation: c) }
            }
        } onCancel: { Task { @MainActor in captured.stop(.cancelled) } }
        try Task.checkCancellation()
    }
    func close() { lease?.stop(.closed) }
    deinit {
        let captured = lease
        Task { @MainActor in captured?.stop(.closed) }
    }
}

/// Drain-owned state, independent of caller/controller/transport lifetime.
@MainActor private final class NativeSamsungPeerLease {
    let id = UUID()
    let peer: NativeSamsungPeerVerifiedAddress
    let effects: any NativeSamsungPeerEffects
    let clock: any NativeSamsungPeerClock
    let drain: NativeSamsungPeerOperationDrain
    var active = true
    var diagnostics = NativeSamsungPeerDiagnostics()
    private var opening: NativeSamsungPeerOpeningPolicy
    private var openingContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var openTimer: (any NativeSamsungPeerTimer)?
    private var writeTimer: (any NativeSamsungPeerTimer)?
    private var operations: [UInt: NativeSamsungPeerOperation] = [:]
    private var nextID: UInt = 0
    private var channels: [ObjectIdentifier: any NativeSamsungPeerChannel] = [:]
    private var closing = Set<ObjectIdentifier>()
    private var closeCount = 0
    private var channel: (any NativeSamsungPeerChannel)?
    private var mtu = 0
    private var earlyChunks: [Data] = []
    private var earlyByteCount = 0
    private var decoder = SamsungPeerWire.FrameDecoder()
    private var writePolicy: NativeSamsungPeerWritePolicy?
    private var outgoing: Data?
    private var onPacket: ((NativeSamsungPeerUntrustedPacket) -> Void)?
    private var onTermination: ((NativeSamsungPeerFailure) -> Void)?
    init(peer: NativeSamsungPeerVerifiedAddress, effects: any NativeSamsungPeerEffects,
         clock: any NativeSamsungPeerClock, drain: NativeSamsungPeerOperationDrain, budget: TimeInterval,
         onPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
         onTermination: @escaping (NativeSamsungPeerFailure) -> Void) throws {
        self.peer = peer; self.effects = effects; self.clock = clock; self.drain = drain
        opening = try .init(now: clock.now, budget: budget)
        self.onPacket = onPacket; self.onTermination = onTermination
    }
    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        openingContinuation = continuation; diagnostics.phase = .acl
        openTimer = clock.schedule(at: opening.deadline) { [weak self] in self?.stop(.openingDeadline) }
        launch(.connect(peer))
    }
    private func launch(_ request: NativeSamsungPeerRequest) {
        guard active, nextID < UInt.max else { stop(.closed); return }
        nextID += 1; let token = nextID
        let effects = effects
        let deadline: TimeInterval
        if case .write = request { deadline = writePolicy?.deadline ?? clock.now }
        else { deadline = opening.deadline }
        // Map the injectable policy clock to the SDK worker's real monotonic
        // clock. A delayed actor timer cannot allow an expired queued request.
        let sdkDeadline = ProcessInfo.processInfo.systemUptime + max(0, deadline - clock.now)
        let op = NativeSamsungPeerOperation(id: token, request: request, sdkDeadline: sdkDeadline, onReturn: { [weak self] ok, ch, resource in
            self?.returned(token, accepted: ok, channel: ch, resource: resource)
        }, onResult: { [weak self] result in
            guard let self else {
                if case .opened(let ch?, _, _) = result { effects.close(ch) { _ in } }; return
            }
            self.completed(token, result: result)
        }, onBytes: { [weak self] ch, bytes in self?.received(ch, bytes: bytes) },
        onClosed: { [weak self] ch in self?.closed(ch) })
        operations[token] = op; updatePending()
        effects.start(request, operation: op)
    }
    private func own(_ ch: (any NativeSamsungPeerChannel)?) {
        if let ch { channels[ObjectIdentifier(ch)] = ch }
    }
    private func returned(_ token: UInt, accepted: Bool, channel ch: (any NativeSamsungPeerChannel)?, resource: AnyObject?) {
        guard let op = operations[token], !op.didReturn else { return }
        op.sdkResource = resource; op.didReturn = true; op.returnedChannel = ch; own(ch)
        if !accepted {
            let reason: NativeSamsungPeerFailure
            switch op.request {
            case .connect: reason = .aclFailed
            case .discover: reason = .sdpFailed
            case .open: reason = .channelFailed
            case .write: reason = .writeFailed
            }
            settle(token); if active { stop(reason) }; releaseIfDrained(); return
        }
        advanceIfComplete(token)
    }
    private func completed(_ token: UInt, result: NativeSamsungPeerResult) {
        if case .opened(let ch, _, _) = result { own(ch) }
        guard let op = operations[token], op.result == nil else { return }
        // The callback must match BOTH the operation kind and the exact channel/write ID.
        switch (op.request, result) {
        case (.connect, .connected), (.discover, .discovered), (.open, .opened): break
        case (.write(let expected, _), .written(let actual, let id, _, _)):
            guard expected === actual, token == id else { return }
        default: return
        }
        op.result = result
        advanceIfComplete(token)
    }
    private func advanceIfComplete(_ token: UInt) {
        guard let op = operations[token], op.didReturn, let result = op.result else { return }
        let returned = op.returnedChannel
        settle(token)
        guard active else { releaseIfDrained(); return }
        do {
            switch result {
            case .connected(let ok):
                guard ok else { throw NativeSamsungPeerFailure.aclFailed }
                try opening.connected(now: clock.now); diagnostics.phase = .sdp; launch(.discover(peer))
            case .discovered(let success, let id):
                guard success else { throw NativeSamsungPeerFailure.sdpFailed }
                let id = try opening.discovered(recordChannel: id, now: clock.now)
                diagnostics.phase = .channel; launch(.open(peer, id))
            case .opened(let ch, let success, let mtu):
                guard success, let ch, let returned, ch === returned else { throw NativeSamsungPeerFailure.channelFailed }
                try opening.opened(mtu: mtu, now: clock.now)
                self.channel = ch; self.mtu = mtu; diagnostics.phase = .openUntrusted
                openTimer?.cancel(); openTimer = nil
                let c = openingContinuation; openingContinuation = nil
                c?.resume()
                let buffered = earlyChunks; earlyChunks = []; earlyByteCount = 0
                for bytes in buffered { received(ch, bytes: bytes) }
            case .written(_, let id, let success, let bytes):
                guard var policy = writePolicy,
                      try policy.complete(id: id, success: success, bytesWritten: bytes, now: clock.now) else { return }
                writePolicy = policy; diagnostics.completedChunks += 1
                if policy.finished {
                    outgoing = nil; writePolicy = nil; writeTimer?.cancel(); writeTimer = nil
                    diagnostics.completedPackets += 1
                    let c = writeContinuation; writeContinuation = nil; c?.resume()
                } else { writeNext() }
            }
        } catch { stop((error as? NativeSamsungPeerFailure) ?? .channelFailed) }
    }
    private func settle(_ token: UInt) {
        if let op = operations.removeValue(forKey: token) {
            // Break SDK receiver / operation / channel retention cycles.
            op.sdkResource = nil; op.result = nil; op.returnedChannel = nil
        }
        updatePending()
    }
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
        guard active, channel != nil, diagnostics.phase == .openUntrusted else {
            continuation.resume(throwing: NativeSamsungPeerFailure.closed); return
        }
        guard writeContinuation == nil else { continuation.resume(throwing: NativeSamsungPeerFailure.busy); return }
        do {
            let data: Data
            do { data = try SamsungPeerWire.frame(packet) } catch { throw NativeSamsungPeerFailure.invalidPacket }
            let policy = try NativeSamsungPeerWritePolicy(count: data.count, mtu: mtu, now: clock.now, budget: budget)
            outgoing = data; writePolicy = policy; writeContinuation = continuation
            writeTimer = clock.schedule(at: policy.deadline) { [weak self] in self?.stop(.writeDeadline) }
            writeNext()
        } catch { continuation.resume(throwing: error) }
    }
    private func writeNext() {
        guard active, let channel, let outgoing, var policy = writePolicy, nextID < UInt.max else { stop(.closed); return }
        do {
            guard let range = try policy.next(id: nextID + 1, now: clock.now) else { return }
            writePolicy = policy
            launch(.write(channel, .init(Data(outgoing[range]))))
        } catch { stop((error as? NativeSamsungPeerFailure) ?? .writeFailed) }
    }
    private func received(_ ch: any NativeSamsungPeerChannel, bytes: Data?) {
        guard active else { return }
        if diagnostics.phase == .channel, channels[ObjectIdentifier(ch)] != nil {
            guard let bytes, bytes.count <= 65536, earlyByteCount <= 262144 - bytes.count,
                  earlyChunks.count < 64 else { stop(.receiveLimit); return }
            earlyChunks.append(bytes); earlyByteCount += bytes.count; return
        }
        guard let channel, ch === channel, diagnostics.phase == .openUntrusted else { return }
        guard let bytes, bytes.count <= 65536 else { stop(.receiveLimit); return }
        diagnostics.receivedBytes += bytes.count
        do {
            // Local decoder copy avoids exclusivity conflicts when a host callback closes us.
            var stream = decoder
            try stream.append(bytes) { [self] packet in
                guard active else { return }
                diagnostics.receivedPackets += 1
                onPacket?(.init(expectedPeer: peer, packet: packet))
            }
            if active { decoder = stream }
        } catch { stop(.malformedStream) }
    }
    private func closed(_ ch: any NativeSamsungPeerChannel) {
        guard channels[ObjectIdentifier(ch)] != nil else { return }
        if active { stop(.closed) }
        // Close notification does NOT complete a write/open SDK operation.
    }
    func stop(_ failure: NativeSamsungPeerFailure) {
        guard active else { releaseIfDrained(); return }
        active = false
        for operation in operations.values { operation.invocation.cancel() }
        diagnostics.failure = failure; diagnostics.phase = failure == .closed || failure == .cancelled ? .closed : .failed
        openTimer?.cancel(); openTimer = nil; writeTimer?.cancel(); writeTimer = nil
        channel = nil; outgoing = nil; writePolicy = nil; decoder = .init(); earlyChunks = []; earlyByteCount = 0
        let a = openingContinuation; openingContinuation = nil
        let b = writeContinuation; writeContinuation = nil
        let terminal = onTermination; onTermination = nil; onPacket = nil
        if !hasPendingOpen { for ch in Array(channels.values) { closeOwned(ch) } }
        a?.resume(throwing: failure); b?.resume(throwing: failure)
        terminal?(failure)
        releaseIfDrained()
    }
    private func closeOwned(_ ch: any NativeSamsungPeerChannel) {
        let key = ObjectIdentifier(ch)
        guard closing.insert(key).inserted else { return }
        closeCount += 1; updatePending()
        effects.close(ch) { [self] success in
            guard success else {
                // The profile may still exist: retain ownership and prevent reopen.
                diagnostics.failure = .profileCloseFailed; diagnostics.phase = .failed
                return
            }
            closeCount -= 1; updatePending()
            // Retain identity tombstone until lease release to suppress duplicate closes.
            channels.removeValue(forKey: key)
            releaseIfDrained()
        }
    }
    private func updatePending() { diagnostics.pendingOperations = operations.count + closeCount }
    private var hasPendingOpen: Bool {
        operations.values.contains { if case .open = $0.request { return true }; return false }
    }
    private func releaseIfDrained() {
        if !active, !hasPendingOpen { for ch in Array(channels.values) { closeOwned(ch) } }
        if !active, operations.isEmpty, closeCount == 0 { drain.release(peer, id: id) }
    }
}
