import Foundation

/// Only these closed values/counters may cross the native snapshot boundary.
struct NativeSamsungPeerCoordinatorDiagnostics: Codable, Equatable {
    enum Phase: String, Codable { case idle, refreshing, opening, authenticating, authenticated, failed, closed }
    enum Failure: String, Error, Codable {
        case materialUnavailable, invalidMaterial, expiredKey, noSelectedPhone, opening, transport
        case authentication, handshakeTimeout, packetLimit, cancelled, accountChanged, ownedContext
    }
    enum MaterialStage: String, Codable { case none, capabilities, ownAddress, phoneAddress, distinctIdentity, ready }
    var materialStage: MaterialStage = .none
    var phase: Phase = .idle
    var failure: Failure?
    var authenticated = false
    var requestSent = false
    var remoteACK = false
    var ownedContextSent = false
    var protocolFailure: SamsungPeerDiagnostics.Failure?
    var contextFailure = ""
    var receivedKinds: [String: Int] = [:]
    var candidateAttempts = 0
    var candidateRejections = 0
    var rosterCount = 0
    var queuedPackets = 0
    var ignoredCommands = 0
    var incomingSwitchRequests = 0
    var switchResponsesSent = 0
    var correlatedReadyEvents = 0
    var keepRequestSent = false
    var keepAcknowledged = false
    var keepResponsesSent = 0
    var publicValues: [String: Any] {
        ["phase": phase.rawValue, "failure": failure?.rawValue ?? "", "authenticated": authenticated,
         "request_sent": requestSent, "remote_ack": remoteACK, "roster_count": rosterCount,
         "queued_packets": queuedPackets, "ignored_commands": ignoredCommands, "material_stage": materialStage.rawValue,
         "owned_context_sent": ownedContextSent, "protocol_failure": protocolFailure?.rawValue ?? "",
         "context_failure": contextFailure, "received_kinds": receivedKinds,
         "candidate_attempts": candidateAttempts, "candidate_rejections": candidateRejections,
         "incoming_switch_requests": incomingSwitchRequests, "switch_responses_sent": switchResponsesSent,
         "correlated_ready_events": correlatedReadyEvents,
         "keep_request_sent": keepRequestSent, "keep_acknowledged": keepAcknowledged,
         "keep_responses_sent": keepResponsesSent]
    }
}

/// Concrete implementation keeps NativeSamsungPeerTransport's shared operation drain.
/// Fake adapters replace only I/O; authentication always runs SamsungPeerSession.
@MainActor protocol NativeSamsungPeerCoordinatorTransport: AnyObject {
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws
    func close()
}
extension NativeSamsungPeerTransport: NativeSamsungPeerCoordinatorTransport {}

@MainActor final class NativeSamsungPeerCoordinator {
    typealias MaterialProvider = () async throws -> SamsungCloudCertificate.PeerMaterial
    typealias TransportFactory = () -> any NativeSamsungPeerCoordinatorTransport
    typealias OwnedContextProvider = (SamsungCloudCertificate.PeerMaterial) throws -> Data
    typealias Failure = NativeSamsungPeerCoordinatorDiagnostics.Failure
    private let provider: MaterialProvider
    private let factory: TransportFactory
    private let clock: any NativeSamsungPeerClock
    private let wallNow: () -> Date
    private let crypto: any SamsungPeerCryptography
    private let persistSelection: (String) -> Void
    private let ownedContextProvider: OwnedContextProvider?
    private(set) var diagnostics = NativeSamsungPeerCoordinatorDiagnostics()
    private(set) var phones: [PhoneDevice] = []
    private(set) var selectedPhone = ""
    var onRoster: (([PhoneDevice], String) -> Void)?
    /// Intent hint only. Empty READY has no Buds ID and never attests ownership;
    /// bind it to an ACKed request on the current authenticated selected session.
    var onRemoteReady: ((UUID, String) -> Void)?
    private var enabled = false
    private var generation = UUID()
    private var materialTask: Task<Void, Never>?
    private var materialTimer: (any NativeSamsungPeerTimer)?
    private var materialRun: UUID?
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var connectionID: UUID?
    private var transport: (any NativeSamsungPeerCoordinatorTransport)?
    private var lastRadioSummary = NativeSamsungPeerRadioSummary()
    var publicDiagnostics: [String: Any] {
        var values = diagnostics.publicValues
        let radio = (transport as? any NativeSamsungPeerRadioDiagnosticSource)?.radioSummary ?? lastRadioSummary
        values["radio"] = radio.safeValues
        return values
    }
    private var session: SamsungPeerSession?
    private var context: Context?
    private var timer: (any NativeSamsungPeerTimer)?
    // Samsung's ConnectionDelegate uses handler100/cmd3 to stop the remote
    // Bluetooth inactivity timer. This is a session lease, never audio intent.
    private var peerKeepsConnection = false
    private var keepResponsesPending = 0
    // Bind queued commands at ingress: a delayed packet cannot adopt a newer ownership epoch.
    private struct QueuedPacket { let packet: SamsungPeerWire.Packet; let acquisition: Acquisition? }
    private var queue: [QueuedPacket] = []
    private var wake: CheckedContinuation<Void, Never>?
    private var connectRequested = false
    private var candidateDeadline: TimeInterval?
    private var unexpectedCandidateRetries = 0
    private var mac: Acquisition?
    // Ownership UUIDs are single use, including after stop/reconnect. A delayed
    // callback for an already observed acquisition cannot resurrect its authority.
    private var acquiredEpochs: Set<UUID> = []
    private var pending: Acquisition?
    private var sent: Acquisition?
    private var readyHinted: Acquisition?
    private var yieldAcquisition: Acquisition?
    private var incomingSwitch: Acquisition?
    private var preparedYield: Acquisition?
    private var responseAttempted: Acquisition?
    private struct Acquisition: Equatable { let epoch: UUID; let buds: SamsungPeerAddress }
    private struct Context {
        let material: SamsungCloudCertificate.PeerMaterial
        let own: SamsungPeerAddress
        let phone: SamsungPeerAddress
        let roster: SamsungPeerRoster
        func matches(_ other: Context) -> Bool {
            own == other.own && phone == other.phone && material.revision == other.material.revision
                && material.accountKey.bytes == other.material.accountKey.bytes
                && material.accountKey.expireTime == other.material.accountKey.expireTime
                && material.accountFingerprint?.bytes == other.material.accountFingerprint?.bytes
                && Set(material.phones.map(\.address)) == Set(other.material.phones.map(\.address))
        }
    }

    init(materialProvider: @escaping MaterialProvider, transportFactory: @escaping TransportFactory,
         clock: any NativeSamsungPeerClock, wallNow: @escaping () -> Date = Date.init,
         crypto: any SamsungPeerCryptography = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification),
         savedSelectedPhone: String = "", persistSelection: @escaping (String) -> Void = { _ in },
         ownedContextProvider: OwnedContextProvider? = nil) {
        provider = materialProvider; factory = transportFactory; self.clock = clock
        self.wallNow = wallNow; self.crypto = crypto; self.persistSelection = persistSelection
        self.ownedContextProvider = ownedContextProvider
        if let saved = try? Self.address(savedSelectedPhone) { selectedPhone = Self.string(saved) }
    }
    deinit {
        materialTask?.cancel(); worker?.cancel()
        let transport = transport, session = session, timer = timer, materialTimer = materialTimer, wake = wake
        Task { @MainActor in
            timer?.cancel(); materialTimer?.cancel(); session?.close(); transport?.close(); wake?.resume()
        }
    }
    static func live(materialProvider: @escaping MaterialProvider,
                     budsContextProvider: @escaping () -> SamsungContinuityBudsContext? = { nil }) -> NativeSamsungPeerCoordinator {
        let clock = NativeSamsungPeerSystemClock()
        let effects = NativeSamsungPeerIOBluetoothEffects()
        let candidateCache = NativeSamsungPeerCandidateCache(monotonic: { clock.now })
        return .init(materialProvider: materialProvider, transportFactory: {
            NativeSamsungBlePeerFallbackTransport(classic: NativeSamsungPeerTransport(effects: effects, clock: clock), clock: clock, strategy: .advertisedLEFirst, candidateCache: candidateCache)
        }, clock: clock,
           savedSelectedPhone: UserDefaults.standard.string(forKey: "BudsContinuitySelectedPhone") ?? "",
           persistSelection: { UserDefaults.standard.set($0, forKey: "BudsContinuitySelectedPhone") },
           ownedContextProvider: { try NativeSamsungOwnedContextProvider.make(material: $0, buds: budsContextProvider()) })
    }
    func start() { enabled = true; refreshRoster() }
    /// Explicit protected read, never a snapshot/poll side effect.
    func refreshRoster() { refresh(connect: false) }
    /// Called only after the host explicitly starts the peer lifecycle. Reuse
    /// validated, selected OWN account material; never supply a bare fallback.
    /// Real cancellable sleeps bound this wait even with a frozen test clock.
    func ownedMDEConfiguration() async throws -> Data {
        try Task.checkCancellation()
        guard enabled else {
            throw diagnostics.failure == .accountChanged ? Failure.accountChanged : Failure.cancelled
        }
        let token = generation
        guard diagnostics.phase != .failed else {
            throw diagnostics.failure == .invalidMaterial ? Failure.invalidMaterial : Failure.materialUnavailable
        }
        if context == nil { refreshRoster() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.materialUnavailable }
            guard diagnostics.phase != .failed else {
                throw diagnostics.failure == .invalidMaterial ? Failure.invalidMaterial : Failure.materialUnavailable
            }
            guard enabled, generation == token else {
                throw diagnostics.failure == .accountChanged ? Failure.accountChanged : Failure.cancelled
            }
            if let context {
                guard context.material.identityMode == .outgoingClassicApplication,
                      let fingerprint = context.material.accountFingerprint,
                      (2...4096).contains(fingerprint.bytes.count) else { throw Failure.invalidMaterial }
                guard selectedPhone == Self.string(context.phone),
                      phones.contains(where: { $0.id == selectedPhone }) else { throw Failure.materialUnavailable }
                try checkExpiry(context.material)
                // wallNow is injected and can synchronously retire the lifecycle.
                try Task.checkCancellation()
                guard enabled, generation == token else {
                    throw diagnostics.failure == .accountChanged ? Failure.accountChanged : Failure.cancelled
                }
                guard self.context?.matches(context) == true,
                      selectedPhone == Self.string(context.phone),
                      phones.contains(where: { $0.id == selectedPhone }) else { throw Failure.materialUnavailable }
                return try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: fingerprint.bytes)
            }
            guard diagnostics.failure != .noSelectedPhone else { throw Failure.materialUnavailable }
            // One monotonic budget: sixty relative sleeps accumulated scheduler
            // delays and took over seven seconds on the CI runner.
            let next = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(50)))
            try await ContinuousClock().sleep(until: next)
        }
    }
    /// Explicit diagnostic action: legitimate selected roster peer, no audio command.
    func connectSelected() { enabled = true; connectRequested = true; refresh(connect: true) }
    func selectPhone(_ value: String) {
        guard phones.contains(where: { $0.id == value }), value != selectedPhone else { return }
        selectedPhone = value; persistSelection(value); pending = nil; sent = nil
        resetCandidateAttempt(); closeConnection(); onRoster?(phones, selectedPhone)
    }
    func acquiredMac(epoch: UUID, budsAddress: String) {
        guard enabled, let buds = try? Self.address(budsAddress) else { return }
        let acquisition = Acquisition(epoch: epoch, buds: buds)
        guard acquiredEpochs.insert(epoch).inserted else { return }
        mac = acquisition; pending = nil; sent = nil; readyHinted = nil
        yieldAcquisition = acquisition; incomingSwitch = nil; preparedYield = nil; responseAttempted = nil
        diagnostics.requestSent = false; diagnostics.remoteACK = false; diagnostics.ownedContextSent = false
        connectRequested = true; refresh(connect: true)
    }
    func lostMac() {
        mac = nil; pending = nil; sent = nil
        diagnostics.requestSent = false; diagnostics.remoteACK = false; diagnostics.ownedContextSent = false
        // Keep the full-duplex authenticated connection across phone ownership.
    }
    /// Root attests only after actual background/call MDE, verified Mac pause and
    /// guarded waiting route. Losing Mac alone is never proof of a protected yield.
    /// Covers the current or just-lost acquisition, never creates ownership or I/O.
    /// The production controller supplies the captured acquisition UUID. This
    /// also fences an old pause callback after a newer same-Buds acquisition.
    func macYieldPrepared(epoch: UUID, budsAddress: String) {
        guard mac == nil, yieldAcquisition?.epoch == epoch else { return }
        macYieldPrepared(budsAddress: budsAddress)
    }
    /// A new local playback attempt retires the old pause/route receipt before
    /// radio acquisition finishes; a late phone request cannot reuse that proof.
    func localPlaybackResumed() {
        preparedYield = nil; incomingSwitch = nil
    }
    // In-process receipt application; only the UUID-bearing overload is wired
    // to NativeIntegration. Existing isolated coordinator fixtures use this
    // lower-level entry to exercise either packet/receipt arrival order.
    func macYieldPrepared(budsAddress: String) {
        guard enabled, let buds = try? Self.address(budsAddress),
              let acquisition = yieldAcquisition, acquisition.buds == buds else { return }
        preparedYield = acquisition
        signal()
    }
    func stop(accountChanged: Bool = false) {
        resetCandidateAttempt()
        enabled = false; generation = UUID(); connectRequested = false; lostMac()
        materialTask?.cancel(); materialTimer?.cancel(); materialTimer = nil; materialRun = nil
        closeConnection()
        diagnostics.phase = .closed; diagnostics.failure = accountChanged ? .accountChanged : .cancelled
        if accountChanged { phones = []; diagnostics.rosterCount = 0; onRoster?(phones, selectedPhone) }
    }
    private func refresh(connect: Bool) {
        connectRequested = connectRequested || connect
        guard materialTask == nil else { return } // one provider call, even if cancellation is ignored
        let token = generation, run = UUID(), provider = provider
        materialRun = run
        if session == nil { diagnostics.phase = .refreshing }
        materialTimer = clock.schedule(at: clock.now + 15) { [weak self] in
            guard let self, self.materialRun == run else { return }
            self.materialRun = nil; self.materialTask?.cancel(); self.fail(.materialUnavailable)
        }
        materialTask = Task { [weak self] in
            do {
                let material = try await provider()
                guard let self, self.generation == token, self.materialRun == run, !Task.isCancelled else {
                    self?.finishedMaterial(run); return
                }
                try self.apply(material)
            } catch {
                if let self, self.generation == token, self.materialRun == run, !Task.isCancelled {
                    self.phones = []; self.diagnostics.rosterCount = 0; self.onRoster?(self.phones, self.selectedPhone)
                    self.fail((error as? Failure) ?? .materialUnavailable)
                }
            }
            self?.finishedMaterial(run)
        }
    }
    private func finishedMaterial(_ run: UUID) {
        materialTask = nil
        if materialRun == run { materialRun = nil; materialTimer?.cancel(); materialTimer = nil }
    }
    private func apply(_ material: SamsungCloudCertificate.PeerMaterial) throws {
        diagnostics.materialStage = .capabilities
        guard material.outgoingOnly, material.accountKey.bytes.count == 32,
              let revision = Int32(exactly: material.revision), revision >= 0 else { throw Failure.invalidMaterial }
        try checkExpiry(material)
        diagnostics.materialStage = .ownAddress
        let own = try Self.address(material.ownClassicAddress)
        var members: Set<SamsungPeerAddress> = [own]
        var devices: [PhoneDevice] = []
        for phone in material.phones {
            diagnostics.materialStage = .phoneAddress
            let address = try Self.address(phone.address)
            diagnostics.materialStage = .distinctIdentity
            guard address != own, members.insert(address).inserted else { throw Failure.invalidMaterial }
            devices.append(.init(id: Self.string(address), name: phone.name))
        }
        diagnostics.materialStage = .ready
        phones = devices; diagnostics.rosterCount = devices.count
        // Never replace an explicit preference when its phone is temporarily absent.
        if selectedPhone.isEmpty, devices.count == 1 { selectedPhone = devices[0].id; persistSelection(selectedPhone) }
        onRoster?(phones, selectedPhone)
        guard let chosen = devices.first(where: { $0.id == selectedPhone }) else {
            closeConnection(); diagnostics.phase = .idle; diagnostics.failure = .noSelectedPhone; return
        }
        let next = Context(material: material, own: own, phone: try Self.address(chosen.id),
                           roster: try .init(revision: revision, members: members))
        if let context, !context.matches(next) { resetCandidateAttempt(); closeConnection() }
        context = next; diagnostics.failure = nil
        guard enabled, connectRequested else { diagnostics.phase = session == nil ? .idle : diagnostics.phase; return }
        pending = mac == sent ? nil : mac
        if session == nil { launchIfNeeded() } else { signal() }
    }
    private func checkExpiry(_ material: SamsungCloudCertificate.PeerMaterial) throws {
        let now = wallNow().timeIntervalSince1970 * 1000
        guard now.isFinite, Double(material.accountKey.expireTime) > now else { throw Failure.expiredKey }
    }
    static func address(_ string: String) throws -> SamsungPeerAddress {
        let parts = string.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard parts.count == 6, bytes.count == 6, bytes.contains(where: { $0 != 0 }),
              bytes.contains(where: { $0 != 255 }), bytes[0] & 1 == 0 else { throw Failure.invalidMaterial }
        return try .init(bytes: Data(bytes))
    }
    private static func string(_ address: SamsungPeerAddress) -> String {
        address.bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    private func launchIfNeeded() {
        guard enabled, connectRequested, worker == nil, session == nil, let context else { return }
        let id = UUID(), io = factory()
        do {
            try checkExpiry(context.material)
            if candidateDeadline == nil { candidateDeadline = clock.now + 30; unexpectedCandidateRetries = 0 }
            guard let deadline = candidateDeadline, deadline > clock.now else { throw Failure.handshakeTimeout }
            let openingBudget = min(15, deadline - clock.now)
            diagnostics.candidateAttempts = min(diagnostics.candidateAttempts + 1, 1_000_000)
            (io as? any NativeSamsungBlePeerFallbackConfiguration)?.configure(material: context.material)
            let peer = try NativeSamsungPeerVerifiedAddress(hostVerifiedClassicPhone: context.phone, roster: context.roster)
            let session = try SamsungPeerSession(role: .initiator, accountKey: context.material.accountKey.bytes,
                localAddress: context.own, roster: context.roster, expectedPeer: context.phone, crypto: crypto, timeout: 10)
            connectionID = id; workerID = id; transport = io; self.session = session
            diagnostics.protocolFailure = nil; diagnostics.contextFailure = ""
            diagnostics.phase = .opening; diagnostics.authenticated = false
            worker = Task { [weak self] in
                defer { self?.finishedWorker(id) }
                do {
                    try await io.open(peer: peer, openingBudget: openingBudget, onUntrustedPacket: { [weak self] packet in
                        guard let self, self.connectionID == id else { return }
                        guard packet.expectedPeer == peer else { self.fail(.authentication); return }
                        self.enqueue(packet.packet)
                    }, onTermination: { [weak self] failure in
                        guard let self, self.connectionID == id else { return }
                        self.fail(failure == .openingDeadline ? .opening : .transport)
                    })
                    guard self?.current(id) == true else { io.close(); return }
                    try self?.checkExpiry(context.material)
                    self?.diagnostics.phase = .authenticating
                    let first = try session.start(now: self?.clock.now ?? 0)
                    self?.armTimer(id)
                    if let first { try await io.send(first, budget: 5) }
                    while self?.current(id) == true {
                        if self?.hasWork(session) == true {
                            try await self?.processOne(id, io: io, session: session, context: context)
                        } else {
                            await withCheckedContinuation { continuation in
                                guard let self else { continuation.resume(); return }
                                self.wake = continuation
                            }
                        }
                    }
                } catch {
                    if let self, self.connectionID == id {
                        self.diagnostics.protocolFailure = error as? SamsungPeerDiagnostics.Failure
                        if error as? SamsungPeerDiagnostics.Failure == .unexpectedAddress,
                           self.retryUnexpectedCandidate(id, io: io, context: context) { return }
                        guard self.current(id) else { return }
                        let failure: Failure
                        if let closed = error as? Failure { failure = closed }
                        else if error as? SamsungPeerDiagnostics.Failure == .timeout { failure = .handshakeTimeout }
                        else if error is NativeSamsungPeerFailure { failure = self.diagnostics.phase == .opening ? .opening : .transport }
                        else { failure = .authentication }
                        self.fail(failure)
                    }
                }
            }
        } catch { fail((error as? Failure) ?? .authentication) }
    }
    private func finishedWorker(_ id: UUID) {
        guard workerID == id else { return }
        worker = nil; workerID = nil
        // A replaced context can launch only after the old worker has returned.
        if connectionID == nil, context != nil { launchIfNeeded() }
    }
    private func hasWork(_ session: SamsungPeerSession) -> Bool {
        !queue.isEmpty || (session.phase == .authenticated &&
            (!diagnostics.keepRequestSent || keepResponsesPending > 0 || pending != nil || readySwitchResponse != nil))
    }
    private func processOne(_ id: UUID, io: any NativeSamsungPeerCoordinatorTransport,
                            session: SamsungPeerSession, context: Context) async throws {
        guard current(id) else { return }
        try checkExpiry(context.material)
        if !queue.isEmpty {
            let queued = queue.removeFirst(), packet = queued.packet
            diagnostics.queuedPackets = queue.count
            if session.phase != .authenticated {
                let reply = try session.receiveAuthentication(packet, now: clock.now)
                if let reply {
                    try await io.send(reply, budget: 5)
                    guard current(id) else { return }
                    try checkExpiry(context.material)
                    if session.phase == .awaitingFinalSend { try session.confirmFinalReplySent(now: clock.now) }
                }
                if session.phase == .authenticated {
                    (io as? any NativeSamsungPeerCandidateRouting)?.expectedPeerAuthenticated()
                    resetCandidateAttempt()
                    diagnostics.authenticated = true; diagnostics.phase = .authenticated
                }
            } else { try receiveCommand(packet, session: session, acquisition: queued.acquisition) }
        } else if session.phase == .authenticated, keepResponsesPending > 0 {
            let packet = try session.encodeCommand(.init(commandID: 3, type: 2, payload: Data()), handlerID: 100)
            guard current(id), keepResponsesPending > 0 else { return }
            keepResponsesPending -= 1
            try await io.send(packet, budget: 5)
            guard current(id) else { return }
            diagnostics.keepResponsesSent = min(diagnostics.keepResponsesSent + 1, 1_000_000)
        } else if session.phase == .authenticated, !diagnostics.keepRequestSent {
            // One authenticated request per channel, through the same serialized
            // worker as every other packet. No polling, audio command or regrab.
            let packet = try session.encodeCommand(.init(commandID: 3, type: 1, payload: Data([1])), handlerID: 100)
            guard current(id), !diagnostics.keepRequestSent else { return }
            diagnostics.keepRequestSent = true
            try await io.send(packet, budget: 5)
        } else if session.phase == .authenticated, let acquisition = readySwitchResponse {
            let ownedContext = try makeOwnedContext(context.material)
            guard current(id), readySwitchResponse == acquisition else { return }
            let packet = try session.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: acquisition.buds).command(),
                handlerID: 1, advertisement: ownedContext)
            // Provider/encoding may invoke synchronous callbacks. Recheck the lease
            // and epoch immediately before this worker's sole transport write.
            guard current(id), readySwitchResponse == acquisition else { return }
            responseAttempted = acquisition
            incomingSwitch = nil
            try await io.send(packet, budget: 5)
            guard current(id), yieldAcquisition == acquisition else { return }
            diagnostics.switchResponsesSent = min(diagnostics.switchResponsesSent + 1, 1_000_000)
            diagnostics.ownedContextSent = !ownedContext.isEmpty
        } else if session.phase == .authenticated, let command = pending {
            pending = nil
            // Root may attest the current epoch before its ownership-loss callback.
            // That completed yield also retires an acquisition request not yet submitted.
            guard mac == command, preparedYield != command, enabled else { return }
            try checkExpiry(context.material)
            // The Samsung receiver processes this owned context before the
            // BUDS_SWITCH handler. It is session-delivered metadata outside CBC,
            // not an independently authenticated advertisement or Cloud identity.
            let ownedContext = try makeOwnedContext(context.material)
            let packet = try session.encodeCommand(SamsungPeerBudsSwitch.request(
                advertisingID: command.buds.advertisingID, address: command.buds, reason: .media).command(),
                handlerID: 1, advertisement: ownedContext)
            // No suspension between epoch check and submitting this write.
            guard current(id), mac == command, preparedYield != command else { return }
            try await io.send(packet, budget: 5)
            guard current(id), mac == command else { return }
            sent = command; diagnostics.requestSent = true
            diagnostics.ownedContextSent = !ownedContext.isEmpty
        }
    }
    private var readySwitchResponse: Acquisition? {
        guard enabled, let acquisition = yieldAcquisition, incomingSwitch == acquisition,
              preparedYield == acquisition, responseAttempted != acquisition else { return nil }
        return acquisition
    }
    private func makeOwnedContext(_ material: SamsungCloudCertificate.PeerMaterial) throws -> Data {
        do { return try ownedContextProvider?(material) ?? Data() }
        catch {
            diagnostics.contextFailure = (error as? SamsungContinuityOwnedContext.Failure)?.rawValue
                ?? (error as? SamsungContinuityAdvertisement.Failure)?.rawValue ?? "unavailable"
            throw Failure.ownedContext
        }
    }
    private func current(_ id: UUID) -> Bool { enabled && connectionID == id && !Task.isCancelled }
    private func enqueue(_ packet: SamsungPeerWire.Packet) {
        guard queue.count < 64 else { fail(.packetLimit); return }
        queue.append(.init(packet: packet, acquisition: yieldAcquisition)); diagnostics.queuedPackets = queue.count; signal()
    }
    private func signal() { let waiter = wake; wake = nil; waiter?.resume() }
    private func armTimer(_ id: UUID) {
        timer = clock.schedule(at: clock.now + 0.25) { [weak self] in
            guard let self, self.connectionID == id, let session = self.session, let context = self.context else { return }
            do {
                try self.checkExpiry(context.material)
                if let deadline = self.candidateDeadline, self.clock.now >= deadline { throw Failure.handshakeTimeout }
                try session.pollTimeout(now: self.clock.now); self.armTimer(id)
            }
            catch { self.fail((error as? Failure) ?? .handshakeTimeout) }
        }
    }
    private func receiveCommand(_ packet: SamsungPeerWire.Packet, session: SamsungPeerSession,
                                acquisition: Acquisition?) throws {
        let received = try session.receiveCommand(packet)
        if received.handlerID == 100, received.command.commandID == 3 {
            // Recovered t9.d.run: reply only when the peer's keep flag changes.
            // Reject malformed forms without granting a lease or ownership.
            if received.command.type == 1, received.command.payload.count == 1,
               let value = received.command.payload.first, value <= 1 {
                let keeps = value == 1
                if peerKeepsConnection != keeps {
                    guard keepResponsesPending < 64 else { throw Failure.packetLimit }
                    peerKeepsConnection = keeps; keepResponsesPending += 1
                }
            } else if received.command.type == 2, received.command.payload.isEmpty,
                      diagnostics.keepRequestSent {
                diagnostics.keepAcknowledged = true
            } else { diagnostics.ignoredCommands = min(diagnostics.ignoredCommands + 1, 1_000_000) }
            return
        }
        let key: String
        if received.handlerID == 1, [1, 2, 3, 4, 5, 10, 11].contains(received.command.commandID),
           (1...3).contains(received.command.type) {
            key = "h1_c\(received.command.commandID)_t\(received.command.type)"
        } else { key = "other" }
        diagnostics.receivedKinds[key] = min((diagnostics.receivedKinds[key] ?? 0) + 1, 1_000_000)
        // READY precedes the phone's C102/profile attempt. Only an ACKed current
        // acquisition supplies its missing Buds correlation. The host decides
        // whether to act; this event is never a switch ACK or yielded receipt.
        if received.handlerID == 1, [10, 11].contains(received.command.commandID),
           received.command.type == 3, received.command.payload.isEmpty {
            if received.command.commandID == 10, enabled, diagnostics.authenticated,
               let acquisition, mac == acquisition, sent == acquisition,
               diagnostics.remoteACK, readyHinted != acquisition {
                readyHinted = acquisition
                diagnostics.correlatedReadyEvents = min(diagnostics.correlatedReadyEvents + 1, 1_000_000)
                onRemoteReady?(acquisition.epoch, Self.string(acquisition.buds))
            }
            return
        }
        guard let value = try? SamsungPeerBudsSwitch.decode(handlerID: received.handlerID, command: received.command) else {
            diagnostics.ignoredCommands = min(diagnostics.ignoredCommands + 1, 1_000_000); return
        }
        if case .response(let success, let id, let address) = value, success == 1,
           let sent, mac == sent, diagnostics.requestSent,
           address == sent.buds, id == sent.buds.advertisingID { diagnostics.remoteACK = true }
        if case .request(let id, let address, _) = value {
            diagnostics.incomingSwitchRequests = min(diagnostics.incomingSwitchRequests + 1, 1_000_000)
            guard let acquisition, yieldAcquisition == acquisition,
                  acquisition.buds == address, address.advertisingID == id,
                  responseAttempted != acquisition else { return }
            incomingSwitch = acquisition
            // Only the worker may reply, after the separate root attestation.
        }
    }
    private func fail(_ failure: Failure) {
        resetCandidateAttempt()
        // A concurrent protected read from the terminated lease cannot resurrect
        // it. A later explicit connect/new acquisition may request a fresh read.
        generation = UUID(); connectRequested = false
        materialRun = nil; materialTask?.cancel(); materialTimer?.cancel(); materialTimer = nil
        closeConnection(); diagnostics.phase = .failed; diagnostics.failure = failure
    }
    private func resetCandidateAttempt() { candidateDeadline = nil; unexpectedCandidateRetries = 0 }
    /// A valid GCM response from another KNOWN roster member is not the selected
    /// phone. Reject that opaque LE route and try another, never relaxing the pin
    /// or falling back after a crypto/unknown-member failure. Three candidates,
    /// one thirty-second aggregate budget; no audio command reaches a wrong peer.
    private func retryUnexpectedCandidate(_ id: UUID, io: any NativeSamsungPeerCoordinatorTransport,
                                          context: Context) -> Bool {
        guard current(id), let route = io as? any NativeSamsungPeerCandidateRouting else { return false }
        // Rejection closes its channel synchronously. Fence that termination
        // before invoking the adapter, while its routing mapping still exists.
        let token = generation
        connectionID = nil
        let rejected = route.rejectUnexpectedPeerCandidate()
        guard enabled, generation == token, workerID == id, connectionID == nil else { return false }
        connectionID = id
        guard rejected else { return false }
        diagnostics.candidateRejections = min(diagnostics.candidateRejections + 1, 1_000_000)
        guard unexpectedCandidateRetries < 2, let deadline = candidateDeadline, clock.now < deadline else { return false }
        let next = unexpectedCandidateRetries + 1
        closeConnection()
        self.context = context; yieldAcquisition = mac; pending = mac
        connectRequested = true; candidateDeadline = deadline; unexpectedCandidateRetries = next
        diagnostics.phase = .opening; diagnostics.failure = nil
        return true
    }
    private func closeConnection() {
        connectionID = nil; context = nil; pending = nil; sent = nil; readyHinted = nil
        yieldAcquisition = nil; incomingSwitch = nil; preparedYield = nil; responseAttempted = nil
        diagnostics.authenticated = false; diagnostics.requestSent = false; diagnostics.remoteACK = false
        diagnostics.ownedContextSent = false
        diagnostics.keepRequestSent = false; diagnostics.keepAcknowledged = false
        peerKeepsConnection = false; keepResponsesPending = 0
        timer?.cancel(); timer = nil
        worker?.cancel(); signal()
        session?.close(); session = nil
        let old = transport
        if let source = old as? any NativeSamsungPeerRadioDiagnosticSource { lastRadioSummary = source.radioSummary }
        transport = nil; old?.close()
        queue.removeAll(); diagnostics.queuedPackets = 0
    }
}
