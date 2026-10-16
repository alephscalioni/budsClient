import Foundation
import CoreBluetooth

/// Optional outgoing-only public-SDK adapter. Construction has no Bluetooth
/// effects. Explicit startFallback is single-use; there is no app-init wiring.
/// Explicit host carrier policy selects SDP-confirmed fallback or account-filtered
/// LE-first with pinned host authentication; neither policy itself proves identity.
/// Matching BLE data cannot map a CBPeripheral to that expected roster address.
/// Host MUST configure SamsungPeerSession(expectedPeer: knownPhoneAddress),
/// provisioned own KU, own enrolled Mac Classic address and known roster. Neither
/// CBPeripheral.identifier nor name may supply any of those identities.
@MainActor final class NativeSamsungBlePeerCentral: NSObject, @preconcurrency CBCentralManagerDelegate {
    enum FallbackAuthorization {
        case expectedPhoneSPPServiceAbsent
        /// Account-matched carrier only; host MUST authenticate the expected roster peer.
        case accountCarrierWithPinnedPeerAuthentication
    }
    typealias Candidate = SamsungContinuityAdvertisement.Candidate
    typealias Reason = NativeSamsungBlePeerDiagnostics.Reason
    var onCandidate: ((UUID, Candidate) -> Void)?
    var onUntrustedChannel: (() -> Void)?
    var onBytesAvailable: (() -> Void)?
    var onClosed: ((Reason) -> Void)?
    /// All queued bytes accepted by OutputStream locally; never remote receipt.
    var onWriteDrained: (() -> Void)?

    private let fingerprint: SamsungContinuityAdvertisement.Fingerprint
    private let monotonic: () -> TimeInterval
    private let unixMilliseconds: () -> Int64
    private var policy: NativeSamsungBlePeerPolicy
    private var central: CBCentralManager?
    private var timer: Timer?
    private var started = false
    private var closedReported = false
    private var candidates: [UUID: (CBPeripheral, Candidate)] = [:]
    private var attempts: [NativeSamsungBlePeerLease: Attempt] = [:]
    private var streams: [UUID: Streams] = [:]
    private var currentStream: UUID?
    private var rejected = 0
    private var authorization: FallbackAuthorization = .expectedPhoneSPPServiceAbsent
    private var preferredIdentifier: () -> UUID? = { nil }
    private var excludedIdentifier: (UUID) -> Bool = { _ in false }
    private var selection = NativeSamsungPeerCandidateSelection()
    /// Local routing hint for the selected lease. Never an authenticated identity.
    var selectedPeripheralIdentifier: UUID? {
        guard policy.phase == .channelOpen, let active = policy.active else { return nil }
        return attempts[active]?.peripheral.identifier
    }
    func configureCandidateRouting(preferred: @escaping () -> UUID?, excluded: @escaping (UUID) -> Bool) {
        guard !started else { return }
        preferredIdentifier = preferred; excludedIdentifier = excluded
    }
    // A cancellation is asynchronous. Keep the original manager/delegates alive
    // across caller release and across new controller instances until drained.
    private static var draining: [UUID: NativeSamsungBlePeerCentral] = [:]

    @MainActor private final class Attempt: NSObject, @preconcurrency CBPeripheralDelegate {
        weak var owner: NativeSamsungBlePeerCentral?
        let peripheral: CBPeripheral
        let lease: NativeSamsungBlePeerLease
        init(owner: NativeSamsungBlePeerCentral, peripheral: CBPeripheral, lease: NativeSamsungBlePeerLease) {
            self.owner = owner; self.peripheral = peripheral; self.lease = lease
        }
        func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
            guard peripheral === self.peripheral else {
                channel?.inputStream.close(); channel?.outputStream.close(); return
            }
            guard let owner else { channel?.inputStream.close(); channel?.outputStream.close(); return }
            owner.opened(lease, channel: channel, success: error == nil)
        }
    }
    @MainActor private final class Streams: NSObject, @preconcurrency StreamDelegate {
        weak var owner: NativeSamsungBlePeerCentral?
        let id: UUID
        let lease: NativeSamsungBlePeerLease
        let channel: CBL2CAPChannel
        let input: InputStream
        let output: OutputStream
        var buffer: NativeSamsungBlePeerStreamBuffer
        var closed = false
        init(owner: NativeSamsungBlePeerCentral, lease: NativeSamsungBlePeerLease, channel: CBL2CAPChannel, id: UUID) throws {
            guard let input = channel.inputStream, let output = channel.outputStream else { throw Reason.channelFailed }
            self.input = input; self.output = output
            self.owner = owner; self.lease = lease; self.channel = channel; self.id = id
            buffer = try .init()
        }
        func open() {
            for stream in [input as Stream, output as Stream] {
                stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open()
            }
        }
        func close() {
            guard !closed else { return }; closed = true
            for stream in [input as Stream, output as Stream] {
                stream.delegate = nil; stream.close(); stream.remove(from: .main, forMode: .common)
            }
        }
        func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
            guard !closed, aStream === input || aStream === output else { return }
            guard let owner, owner.policy.owns(lease, stream: id) else { close(); return }
            if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) {
                owner.finish(.streamFailure); return
            }
            do {
                if eventCode.contains(.hasBytesAvailable), aStream === input { try readAvailable() }
                if eventCode.contains(.hasSpaceAvailable), aStream === output { try flush() }
            } catch { owner.finish((error as? Reason) ?? .streamFailure) }
        }
        func readAvailable() throws {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 where input.hasBytesAvailable {
                let n = input.read(&bytes, maxLength: bytes.count)
                guard n >= 0 else { throw Reason.streamFailure }
                if n == 0 { owner?.finish(.disconnected); return }
                try buffer.receive(Data(bytes.prefix(n)))
                owner?.onBytesAvailable?()
                if closed { return }
            }
            if input.hasBytesAvailable {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    do { try self.readAvailable() } catch { self.owner?.finish((error as? Reason) ?? .streamFailure) }
                }
            }
        }
        func flush() throws {
            let before = buffer.pendingWriteBytes
            try buffer.pump(hasSpace: { output.hasSpaceAvailable }) { data in
                data.withUnsafeBytes { raw in
                    guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    return output.write(p, maxLength: raw.count)
                }
            }
            if buffer.pendingWriteBytes == 0 { owner?.onWriteDrained?() }
            if buffer.pendingWriteBytes > 0, buffer.pendingWriteBytes < before, output.hasSpaceAvailable {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    do { try self.flush() } catch { self.owner?.finish((error as? Reason) ?? .streamFailure) }
                }
            }
        }
    }

    init(fingerprint: SamsungContinuityAdvertisement.Fingerprint,
         budgets: NativeSamsungBlePeerPolicy.Budgets = .init(),
         monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         unixMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        self.fingerprint = fingerprint; self.monotonic = monotonic; self.unixMilliseconds = unixMilliseconds
        policy = try .init(budgets: budgets)
        super.init()
    }
    var diagnostics: NativeSamsungBlePeerDiagnostics {
        .init(phase: policy.phase, reason: policy.reason, candidates: candidates.count,
              rejected: rejected, channelsOpened: policy.channelsOpened, authenticated: false)
    }
    func startFallback(authorization: FallbackAuthorization) throws {
        guard !started else { throw Reason.invalidState }; started = true
        self.authorization = authorization
        let effects = try policy.begin(now: monotonic())
        // Retain through bounded discovery even if the caller drops its handle.
        // finish invalidates the timer and breaks this cycle.
        timer = Timer(timeInterval: 0.1, repeats: true) { [self] _ in
            // Main run loop timer; no background CoreBluetooth access.
            MainActor.assumeIsolated {
                do {
                    self.apply(try self.policy.poll(now: self.monotonic()))
                    self.selectCollectedCandidate()
                }
                catch { self.finish(.invalidClock) }
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        apply(effects)
    }
    /// Select an opaque candidate from this bounded scan. It is still UNTRUSTED.
    func connectCandidate(_ token: UUID) throws {
        guard let (peripheral, candidate) = candidates[token], candidate.device == .phone,
              !excludedIdentifier(peripheral.identifier),
              let psm = candidate.capabilities.leCoCPSM else { throw Reason.candidateRejected }
        guard Self.draining[peripheral.identifier] == nil else { throw Reason.peerDraining }
        apply(try policy.connect(peripheral: token, psm: psm, now: monotonic()))
    }
    func send(_ bytes: Data) throws {
        guard let currentStream, let stream = streams[currentStream], policy.owns(stream.lease, stream: currentStream) else { throw Reason.invalidState }
        do { try stream.buffer.enqueue(bytes); try stream.flush() }
        catch { let reason = (error as? Reason) ?? .streamFailure; finish(reason); throw reason }
    }
    func takeReceived(maximum: Int = 4096) -> Data {
        guard let currentStream, let stream = streams[currentStream], policy.owns(stream.lease, stream: currentStream) else { return Data() }
        return stream.buffer.takeReceived(maximum: maximum)
    }
    func close() { finish(.cancelled) }
    private func finish(_ reason: Reason) { apply(policy.stop(reason)) }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if central.state == .unknown || central.state == .resetting { return }
        do { apply(try policy.power(central.state == .poweredOn, now: monotonic())) }
        catch { finish(.invalidClock) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central else { return }
        do { apply(try policy.poll(now: monotonic())) }
        catch { finish(.invalidClock); return }
        guard policy.phase == .discovering,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else { return }
        do {
            let c = try SamsungContinuityAdvertisement.decode(manufacturerData: data, fingerprint: fingerprint, unixMilliseconds: unixMilliseconds())
            guard c.device == .phone, c.capabilities.leCoCPSM != nil,
                  advertisementData[CBAdvertisementDataIsConnectable] as? Bool == true else { rejected &+= 1; return }
            if case .accountCarrierWithPinnedPeerAuthentication = authorization,
               c.capabilities.preferredTransport != .leCoC { rejected &+= 1; return }
            guard !excludedIdentifier(peripheral.identifier) else { rejected &+= 1; return }
            // Identifier used solely as a CB routing/deduplication handle.
            if let existing = candidates.first(where: { $0.value.0 === peripheral })?.key {
                candidates[existing] = (peripheral, c); return
            }
            // Reserve one bounded slot for the preferred route during its grace.
            let preferred = preferredIdentifier()
            let limit = preferred != nil && preferred != peripheral.identifier ? 15 : 16
            guard candidates.count < limit else { rejected &+= 1; return }
            let token = UUID(); candidates[token] = (peripheral, c)
            if let chosen = selection.offer(token: token, identifier: peripheral.identifier, now: monotonic(),
                                             preferred: preferred,
                                             isTemporarilyUnavailable: { Self.draining[$0] != nil },
                                             isExcluded: excludedIdentifier) {
                reportCandidate(chosen)
            }
        } catch { rejected &+= 1 }
    }
    private func selectCollectedCandidate() {
        guard policy.phase == .discovering else { return }
        if let token = selection.poll(now: monotonic(), preferred: preferredIdentifier(),
                                      isTemporarilyUnavailable: { Self.draining[$0] != nil },
                                      isExcluded: excludedIdentifier) {
            reportCandidate(token)
        }
    }
    private func reportCandidate(_ token: UUID) {
        guard policy.phase == .discovering, let candidate = candidates[token]?.1 else { return }
        onCandidate?(token, candidate)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, let a = attempts.values.first(where: { $0.peripheral === peripheral }) else { return }
        do { apply(try policy.connected(a.lease, now: monotonic())) } catch { finish(.invalidClock) }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        terminal(central, peripheral, failed: true)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        terminal(central, peripheral, failed: false)
    }
    private func terminal(_ central: CBCentralManager, _ peripheral: CBPeripheral, failed: Bool) {
        guard central === self.central, let a = attempts.values.first(where: { $0.peripheral === peripheral }) else { return }
        apply(policy.terminal(a.lease, failedToConnect: failed)); prune()
    }
    private func opened(_ lease: NativeSamsungBlePeerLease, channel: CBL2CAPChannel?, success: Bool) {
        // A duplicate SDK callback must not wrap the active channel under a new
        // token and then close its streams as an orphan. Compare object identity.
        if let channel, streams.values.contains(where: { $0.channel === channel }) { return }
        var id: UUID?
        if let channel {
            let token = UUID()
            if let stream = try? Streams(owner: self, lease: lease, channel: channel, id: token) {
                streams[token] = stream; id = token
            } else { channel.inputStream.close(); channel.outputStream.close() }
        }
        do { apply(try policy.opened(lease, stream: id, psm: success ? channel?.psm : nil, now: monotonic())) }
        catch { if let id { streams.removeValue(forKey: id)?.close() }; finish(.invalidClock) }
        prune()
    }
    private func apply(_ effects: [NativeSamsungBlePeerPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .initializeCentral:
                // Only explicit start reaches here; never constructed at app init.
                central = CBCentralManager(delegate: self, queue: .main)
            case .scan:
                guard central?.state == .poweredOn else { continue }
                selection.begin(now: monotonic())
                // Public API cannot filter manufacturer bytes; enforce decoder in
                // didDiscover. No invented Samsung GATT service/characteristic.
                central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .stopScan: central?.stopScan()
            case .connect(let lease):
                guard let p = candidates[lease.peripheral]?.0 else { finish(.candidateRejected); continue }
                let a = Attempt(owner: self, peripheral: p, lease: lease)
                attempts[lease] = a; Self.draining[p.identifier] = self
                p.delegate = a; central?.connect(p)
            case .open(let lease, let psm): attempts[lease]?.peripheral.openL2CAPChannel(psm)
            case .cancel(let lease):
                if let p = attempts[lease]?.peripheral { central?.cancelPeripheralConnection(p) }
            case .closeStream(let id):
                streams.removeValue(forKey: id)?.close()
                if currentStream == id { currentStream = nil }
            case .ready(_, let id):
                currentStream = id; streams[id]?.open(); onUntrustedChannel?()
            }
        }
        if [.closed, .cancelling].contains(policy.phase) {
            timer?.invalidate(); timer = nil
            if !closedReported { closedReported = true; onClosed?(policy.reason ?? .disconnected) }
        }
    }
    private func prune() {
        for (lease, a) in attempts where !policy.isDraining(lease.peripheral) {
            a.peripheral.delegate = nil
            if Self.draining[a.peripheral.identifier] === self { Self.draining.removeValue(forKey: a.peripheral.identifier) }
            attempts.removeValue(forKey: lease)
        }
    }
}
