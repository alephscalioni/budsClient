import Foundation

@MainActor protocol NativeSamsungBlePeerFallbackConfiguration: AnyObject {
    func configure(material: SamsungCloudCertificate.PeerMaterial)
}

/// Explicit carrier strategy; only the host GCM/roster pin authenticates identity.
@MainActor final class NativeSamsungBlePeerFallbackTransport: NativeSamsungPeerCoordinatorTransport, NativeSamsungBlePeerFallbackConfiguration, NativeSamsungPeerRadioDiagnosticSource, NativeSamsungPeerCandidateRouting {
    typealias Strategy = NativeSamsungPeerRadioStrategy
    typealias BLEFactory = (SamsungContinuityAdvertisement.Fingerprint) throws -> any NativeSamsungPeerCoordinatorTransport
    private let classic: any NativeSamsungPeerCoordinatorTransport
    private let clock: any NativeSamsungPeerClock
    private let bleFactory: BLEFactory
    private let strategy: Strategy
    private var fingerprint: SamsungContinuityAdvertisement.Fingerprint?
    private var ble: (any NativeSamsungPeerCoordinatorTransport)?
    private var selected: (any NativeSamsungPeerCoordinatorTransport)?
    private var run: UUID?
    private var used = false
    private var opening = false
    private var classicActive = false
    private var classicAttempted = false
    private var lastRadio = NativeSamsungPeerRadioSummary()
    private var waiter: CheckedContinuation<Void, Error>?
    private var timer: (any NativeSamsungPeerTimer)?
    private var worker: Task<Void, Never>?
    private var terminated: ((NativeSamsungPeerFailure) -> Void)?
    init(classic: any NativeSamsungPeerCoordinatorTransport, clock: any NativeSamsungPeerClock,
         strategy: Strategy = .classicFirst, candidateCache: NativeSamsungPeerCandidateCache? = nil, bleFactory: BLEFactory? = nil) {
        self.classic = classic; self.clock = clock; self.strategy = strategy
        self.bleFactory = bleFactory ?? { fingerprint in
            NativeSamsungBlePeerFallbackChannel(fingerprint: fingerprint, clock: clock, candidateCache: candidateCache,
                authorization: strategy == .advertisedLEFirst ? .accountCarrierWithPinnedPeerAuthentication : .expectedPhoneSPPServiceAbsent)
        }
    }
    func expectedPeerAuthenticated() {
        guard run != nil, !opening, !classicActive else { return }
        (selected as? any NativeSamsungPeerCandidateRouting)?.expectedPeerAuthenticated()
    }
    func rejectUnexpectedPeerCandidate() -> Bool {
        guard run != nil, !opening, !classicActive,
              let routing = selected as? any NativeSamsungPeerCandidateRouting else { return false }
        return routing.rejectUnexpectedPeerCandidate()
    }
    var radioSummary: NativeSamsungPeerRadioSummary { run == nil ? lastRadio : collectRadio() }
    private func collectRadio() -> NativeSamsungPeerRadioSummary {
        .init(strategy: strategy,
              classic: classicAttempted ? (classic as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary.classic : nil,
              ble: (ble as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary.ble)
    }
    func configure(material: SamsungCloudCertificate.PeerMaterial) {
        guard !used else { return }
        fingerprint = material.accountFingerprint.flatMap { try? .init(provisionedBytes: $0.bytes) }
    }
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {
        try Task.checkCancellation()
        guard !used else { throw NativeSamsungPeerFailure.busy }
        guard openingBudget.isFinite, openingBudget > 0, openingBudget <= 30,
              clock.now.isFinite else { throw NativeSamsungPeerFailure.invalidConfiguration }
        used = true; let id = UUID(); run = id; opening = true; terminated = onTermination
        let deadline = clock.now + openingBudget
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiter = c
                timer = clock.schedule(at: deadline) { [weak self] in self?.stop(.openingDeadline) }
                worker = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        if self.strategy == .advertisedLEFirst {
                            guard self.fingerprint != nil else { throw NativeSamsungPeerFailure.invalidConfiguration }
                            do {
                                try await self.openCarrier(classic: false, peer: peer, id: id, deadline: deadline, packet: onUntrustedPacket)
                            } catch {
                                guard self.run == id else { return }
                                // Only discovery/unavailability before ANY channel can
                                // try Classic. Auth/session failure never returns here.
                                let d = (self.ble as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary.ble
                                guard let d, d.channelsOpened == 0,
                                      d.reason == .unavailable || d.reason == .discoveryDeadline,
                                      self.clock.now < deadline else { throw error }
                                self.ble?.close()
                                try await self.openCarrier(classic: true, peer: peer, id: id, deadline: deadline, packet: onUntrustedPacket)
                            }
                        } else {
                            do {
                                try await self.openCarrier(classic: true, peer: peer, id: id, deadline: deadline, packet: onUntrustedPacket)
                            } catch {
                                guard self.run == id else { return }
                                guard error as? NativeSamsungPeerFailure == .serviceUnavailable,
                                      self.fingerprint != nil else { throw error }
                                self.classicActive = false; self.classic.close()
                                try await self.openCarrier(classic: false, peer: peer, id: id, deadline: deadline, packet: onUntrustedPacket)
                            }
                        }
                        guard self.run == id else { return }
                        guard self.clock.now < deadline, !Task.isCancelled else { throw NativeSamsungPeerFailure.openingDeadline }
                        self.opening = false; self.timer?.cancel(); self.timer = nil
                        let c = self.waiter; self.waiter = nil; c?.resume()
                    } catch {
                        guard self.run == id else { return }
                        self.stop((error as? NativeSamsungPeerFailure) ?? .channelFailed)
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop(.cancelled) } }
        try Task.checkCancellation()
    }
    private func openCarrier(classic useClassic: Bool, peer: NativeSamsungPeerVerifiedAddress, id: UUID,
                             deadline: TimeInterval, packet: @escaping (NativeSamsungPeerUntrustedPacket) -> Void) async throws {
        guard run == id, clock.now < deadline else { throw NativeSamsungPeerFailure.openingDeadline }
        classicActive = useClassic
        let io: any NativeSamsungPeerCoordinatorTransport
        if useClassic { classicAttempted = true; io = classic }
        else {
            guard let fingerprint else { throw NativeSamsungPeerFailure.invalidConfiguration }
            io = try bleFactory(fingerprint); ble = io
        }
        try await io.open(peer: peer, openingBudget: deadline - clock.now,
            onUntrustedPacket: { [weak self] value in
                guard let self, self.run == id, self.classicActive == useClassic else { return }; packet(value)
            }, onTermination: { [weak self] reason in
                guard let self, self.run == id, !self.opening, self.classicActive == useClassic else { return }
                self.stop(reason)
            })
        guard run == id else { return }; selected = io
    }
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws {
        guard let id = run, !opening, let selected else { throw NativeSamsungPeerFailure.closed }
        do {
            try await selected.send(packet, budget: budget)
            guard run == id else { throw NativeSamsungPeerFailure.closed }
        } catch {
            if run == id { stop((error as? NativeSamsungPeerFailure) ?? .writeFailed) }; throw error
        }
    }
    func close() { stop(.closed) }
    private func stop(_ failure: NativeSamsungPeerFailure) {
        guard run != nil else { return }
        lastRadio = collectRadio(); lastRadio.termination = failure
        run = nil; opening = false; selected = nil; fingerprint = nil
        timer?.cancel(); timer = nil; worker?.cancel()
        let c = waiter; waiter = nil; let callback = terminated; terminated = nil
        classic.close(); ble?.close(); ble = nil
        c?.resume(throwing: failure); callback?(failure)
    }
    deinit {
        let classic = classic, ble = ble, timer = timer, worker = worker, c = waiter
        Task { @MainActor in
            timer?.cancel(); worker?.cancel(); classic.close(); ble?.close()
            c?.resume(throwing: NativeSamsungPeerFailure.closed)
        }
    }
}

/// Narrow injectable public-SDK surface; tests never instantiate CBCentralManager.
@MainActor protocol NativeSamsungBlePeerFallbackAdapter: AnyObject {
    /// Local CB identifier only; absent for adapters that cannot map their lease.
    var selectedPeripheralIdentifier: UUID? { get }
    func configureCandidateRouting(preferred: @escaping () -> UUID?, excluded: @escaping (UUID) -> Bool)
    var onCandidate: ((UUID, SamsungContinuityAdvertisement.Candidate) -> Void)? { get set }
    var onUntrustedChannel: (() -> Void)? { get set }
    var onBytesAvailable: (() -> Void)? { get set }
    var onWriteDrained: (() -> Void)? { get set }
    var onClosed: ((NativeSamsungBlePeerDiagnostics.Reason) -> Void)? { get set }
    func startFallback(authorization: NativeSamsungBlePeerCentral.FallbackAuthorization) throws
    func connectCandidate(_ token: UUID) throws
    func send(_ bytes: Data) throws
    func takeReceived(maximum: Int) -> Data
    func close()
}
extension NativeSamsungBlePeerFallbackAdapter {
    var selectedPeripheralIdentifier: UUID? { nil }
    func configureCandidateRouting(preferred: @escaping () -> UUID?, excluded: @escaping (UUID) -> Bool) {}
}
extension NativeSamsungBlePeerCentral: NativeSamsungBlePeerFallbackAdapter {}

/// Opens only an UNTRUSTED byte channel. The coordinator pins expectedPeer in its
/// real GCM/roster handshake; the scan token is never a roster/MAC identity.
@MainActor final class NativeSamsungBlePeerFallbackChannel: NativeSamsungPeerCoordinatorTransport, NativeSamsungPeerRadioDiagnosticSource, NativeSamsungPeerCandidateRouting {
    typealias AdapterFactory = () throws -> any NativeSamsungBlePeerFallbackAdapter
    private let clock: any NativeSamsungPeerClock
    private let factory: AdapterFactory
    private let authorization: NativeSamsungBlePeerCentral.FallbackAuthorization
    private let candidateCache: NativeSamsungPeerCandidateCache?
    private var routingDecisionMade = false
    private var lastRadio = NativeSamsungPeerRadioSummary()
    var radioSummary: NativeSamsungPeerRadioSummary {
        run == nil ? lastRadio : (adapter as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary ?? .init()
    }
    private var adapter: (any NativeSamsungBlePeerFallbackAdapter)?
    private var run: UUID?
    private var used = false
    private var choseCandidate = false
    private var opened = false
    private var expected: NativeSamsungPeerVerifiedAddress?
    private var decoder = SamsungPeerWire.FrameDecoder()
    private var openingWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var openTimer: (any NativeSamsungPeerTimer)?
    private var writeTimer: (any NativeSamsungPeerTimer)?
    private var writeDeadline: TimeInterval?
    private var openDeadline: TimeInterval?
    private var onPacket: ((NativeSamsungPeerUntrustedPacket) -> Void)?
    private var terminal: ((NativeSamsungPeerFailure) -> Void)?
    init(fingerprint: SamsungContinuityAdvertisement.Fingerprint, clock: any NativeSamsungPeerClock,
         candidateCache: NativeSamsungPeerCandidateCache? = nil,
         authorization: NativeSamsungBlePeerCentral.FallbackAuthorization = .expectedPhoneSPPServiceAbsent,
         adapterFactory: AdapterFactory? = nil) {
        self.clock = clock; self.authorization = authorization; self.candidateCache = candidateCache
        factory = adapterFactory ?? { try NativeSamsungBlePeerCentral(fingerprint: fingerprint,
            budgets: .init(discovery: 15, connect: 10, channel: 10), monotonic: { clock.now }) }
    }
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {
        try Task.checkCancellation()
        guard !used else { throw NativeSamsungPeerFailure.busy }
        guard openingBudget.isFinite, openingBudget > 0, openingBudget <= 30,
              clock.now.isFinite else { throw NativeSamsungPeerFailure.invalidConfiguration }
        used = true; let id = UUID(); run = id; expected = peer; onPacket = onUntrustedPacket; terminal = onTermination
        openDeadline = clock.now + openingBudget
        let io = try factory(); adapter = io
        if let candidateCache {
            let address = peer.address
            io.configureCandidateRouting(preferred: {
                candidateCache.preferredIdentifier(expectedSamsungPeerAddress: address)
            }, excluded: { identifier in
                candidateCache.isExcluded(identifier, expectedSamsungPeerAddress: address)
            })
        }
        io.onCandidate = { [weak self, weak io] token, candidate in
            guard let self, let io, self.run == id, !self.choseCandidate, candidate.device == .phone,
                  candidate.capabilities.leCoCPSM != nil else { return }
            if case .accountCarrierWithPinnedPeerAuthentication = self.authorization,
               candidate.capabilities.preferredTransport != .leCoC { return }
            self.choseCandidate = true
            do { try io.connectCandidate(token) } catch { self.stop(.channelFailed) }
        }
        io.onUntrustedChannel = { [weak self] in
            guard let self, self.run == id, !self.opened else { return }
            guard let deadline = self.openDeadline, self.clock.now < deadline else { self.stop(.openingDeadline); return }
            self.opened = true; self.openTimer?.cancel(); self.openTimer = nil; self.openDeadline = nil
            let c = self.openingWaiter; self.openingWaiter = nil; c?.resume()
        }
        io.onBytesAvailable = { [weak self] in self?.receive(id) }
        io.onWriteDrained = { [weak self] in
            guard let self, self.run == id, self.writeWaiter != nil else { return }
            guard let deadline = self.writeDeadline, self.clock.now < deadline else { self.stop(.writeDeadline); return }
            self.writeTimer?.cancel(); self.writeTimer = nil; self.writeDeadline = nil
            let c = self.writeWaiter; self.writeWaiter = nil; c?.resume()
        }
        io.onClosed = { [weak self] _ in guard self?.run == id else { return }; self?.stop(.closed) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                openingWaiter = c
                openTimer = clock.schedule(at: clock.now + openingBudget) { [weak self] in self?.stop(.openingDeadline) }
                do { try io.startFallback(authorization: authorization) }
                catch { stop(.channelFailed) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop(.cancelled) } }
        try Task.checkCancellation()
    }
    func expectedPeerAuthenticated() {
        guard run != nil, opened, !routingDecisionMade, let expected, let candidateCache,
              let identifier = adapter?.selectedPeripheralIdentifier else { return }
        routingDecisionMade = true
        candidateCache.expectedPeerAuthenticated(expectedSamsungPeerAddress: expected.address, routingIdentifier: identifier)
    }
    func rejectUnexpectedPeerCandidate() -> Bool {
        guard run != nil, opened, !routingDecisionMade, let expected, let candidateCache,
              let identifier = adapter?.selectedPeripheralIdentifier else { return false }
        routingDecisionMade = true
        let rejected = candidateCache.rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: expected.address, routingIdentifier: identifier)
        // SDK cancellation/drain remains owned by the adapter, even across a new factory.
        stop(.closed)
        return rejected
    }
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws {
        try Task.checkCancellation()
        guard run != nil, opened, let adapter else { throw NativeSamsungPeerFailure.closed }
        guard writeWaiter == nil else { throw NativeSamsungPeerFailure.busy }
        guard budget.isFinite, budget > 0, budget <= 30 else { throw NativeSamsungPeerFailure.invalidConfiguration }
        let bytes: Data
        do { bytes = try SamsungPeerWire.frame(packet) } catch { throw NativeSamsungPeerFailure.invalidPacket }
        // One whole owned packet queue. Larger packets fail before enqueueing.
        guard bytes.count <= 65_536 else { throw NativeSamsungPeerFailure.invalidPacket }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                writeWaiter = c; writeDeadline = clock.now + budget
                writeTimer = clock.schedule(at: clock.now + budget) { [weak self] in self?.stop(.writeDeadline) }
                do { try adapter.send(bytes) } catch { stop(.writeFailed) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop(.cancelled) } }
        try Task.checkCancellation()
    }
    private func receive(_ id: UUID) {
        guard run == id, let adapter, let expected else { return }
        do {
            var stream = decoder
            // Protect host callback reentrancy: close fences the rest of this batch.
            for _ in 0..<16 {
                let data = adapter.takeReceived(maximum: 4096)
                if data.isEmpty { break }
                try stream.append(data) { [weak self] packet in
                    guard let self, self.run == id else { return }
                    self.onPacket?(.init(expectedPeer: expected, packet: packet))
                }
                guard run == id else { return }
            }
            if run == id { decoder = stream }
        } catch { stop(.malformedStream) }
    }
    func close() { stop(.closed) }
    private func stop(_ reason: NativeSamsungPeerFailure) {
        guard run != nil else { return }
        lastRadio = (adapter as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary ?? .init()
        lastRadio.termination = reason
        run = nil; opened = false
        openTimer?.cancel(); openTimer = nil; writeTimer?.cancel(); writeTimer = nil; writeDeadline = nil
        let a = openingWaiter, b = writeWaiter; openingWaiter = nil; writeWaiter = nil
        let callback = terminal; terminal = nil; onPacket = nil; expected = nil; decoder = .init()
        if let io = adapter {
            io.onCandidate = nil; io.onUntrustedChannel = nil; io.onBytesAvailable = nil
            io.onWriteDrained = nil; io.onClosed = nil; io.close()
        }
        adapter = nil; a?.resume(throwing: reason); b?.resume(throwing: reason); callback?(reason)
    }
    deinit {
        let io = adapter, a = openingWaiter, b = writeWaiter, ot = openTimer, wt = writeTimer
        Task { @MainActor in
            ot?.cancel(); wt?.cancel(); io?.close()
            a?.resume(throwing: NativeSamsungPeerFailure.closed); b?.resume(throwing: NativeSamsungPeerFailure.closed)
        }
    }
}
