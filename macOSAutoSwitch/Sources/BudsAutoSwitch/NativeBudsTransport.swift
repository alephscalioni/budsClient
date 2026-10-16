import Foundation
@preconcurrency import IOBluetooth

struct NativeBudsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Bounded RFCOMM byte stream, independent of native APIs for offline tests.
struct NativeBudsFrameStream {
    private(set) var buffer = Data()
    private var partialSince: TimeInterval?
    private var discarded = 0
    private(set) var fragmentCount = 0

    mutating func append(_ data: Data, at now: TimeInterval) throws -> [SamsungMdePacket.Frame] {
        guard data.count <= 4096 else { throw NativeBudsError(message: "Bloco Samsung excedeu o limite seguro.") }
        if let partialSince, now - partialSince >= 2 { buffer.removeAll(); self.partialSince = nil }
        guard buffer.count + data.count <= 8192 else { throw NativeBudsError(message: "Fluxo Samsung excedeu o limite seguro.") }
        buffer.append(data)
        var frames: [SamsungMdePacket.Frame] = []
        while !buffer.isEmpty {
            guard buffer.first == 0xFC else { buffer.removeFirst(); discarded += 1; continue }
            guard buffer.count >= 4 else { break }
            let head = Array(buffer.prefix(4))
            let size = Int((UInt16(head[1]) | UInt16(head[2]) << 8) & 0x03FF) + 4
            guard (8...1027).contains(size), head[3] == 1 else { buffer.removeFirst(); discarded += 1; continue }
            guard buffer.count >= size else { break }
            guard let frame = SamsungMdePacket.decodeCompleteFrame(Data(buffer.prefix(size))) else {
                buffer.removeFirst(); discarded += 1; continue
            }
            buffer.removeFirst(size)
            // Fragmented properties cannot be interpreted as a complete notification.
            if !frame.isFragment { frames.append(frame) }
            else { fragmentCount += 1 }
            discarded = 0
            partialSince = nil
        }
        guard discarded <= 32768 else { throw NativeBudsError(message: "Fluxo Samsung sem quadros válidos.") }
        if buffer.isEmpty { partialSince = nil }
        else if partialSince == nil { partialSince = now }
        return frames
    }
}

/// Owns one RFCOMM profile. Never closes the device/baseband or the A2DP link.
@MainActor final class NativeBudsTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum Configuration: Equatable {
        case smep, sppNew
        case settings(SamsungBudsModelProfile)
        var settingsProfile: SamsungBudsModelProfile? {
            if case .settings(let profile) = self { return profile }; return nil
        }
        var isSettings: Bool { self != .smep }
        var serviceUUID: String {
            switch self {
            case .smep: return "F8620674-A1ED-41AB-A8B9-DE9AD655729D"
            case .sppNew: return SamsungBudsSettingsPacket.serviceUUID
            case .settings(let profile): return profile.serviceUUID
            }
        }
        var commandOffset: Int { self == .smep ? 4 : 3 }
        func acceptsPacket(_ packet: Data) -> Bool {
            switch self {
            case .smep: return SamsungMdePacket.decodeCompleteFrame(packet) != nil
            case .sppNew, .settings:
                guard let frame = SamsungBudsSettingsPacket.decodeCompleteFrame(packet, profile: settingsProfile) else { return false }
                return !frame.isFragment
            }
        }
    }
    static let serviceUUID = Configuration.smep.serviceUUID
    let configuration: Configuration
    var onFrame: ((SamsungMdePacket.Frame) -> Void)?
    var onSettingsFrame: ((SamsungBudsSettingsPacket.Frame) -> Void)?
    /// OS transmit completion, never a Samsung acknowledgement.
    var onWriteComplete: ((UInt) -> Void)?
    var onWriteFailure: ((UInt, NativeBudsError) -> Void)?
    var onFailure: ((NativeBudsError) -> Void)?
    var isOpen: Bool { channel?.isOpen() == true && plan.phase == .open && opening == nil }
    private var channel: IOBluetoothRFCOMMChannel?
    private var device: IOBluetoothDevice?
    private var settingsOpening: NativeBudsSettingsOpen<IOBluetoothRFCOMMChannel>?
    private var receiver: Receiver?
    private var opening: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var stage: UInt64 = 0
    private var plan = NativeBudsOpeningPolicy()
    private var stream = NativeBudsFrameStream()
    private var settingsStream = SamsungBudsSettingsPacket.Stream()
    private var selectedChannel: UInt8?
    private var channelAttemptCount = 0
    private var lastStatus: IOReturn?
    private var connectionCallbacks = 0
    private var discoveryCallbacks = 0
    private var channelCallbacks = 0
    private var receivedFrames = 0
    private var receivedFragments = 0
    private var receivedBytes = 0
    private var sentPackets = 0
    private var transmittedPackets = 0
    private var writes = NativeBudsWriteTracker()
    private var pendingPayloads: [UInt: NSMutableData] = [:]
    private var writeInvocations: [UInt: NativeSDKInvocation] = [:]
    private var writeWatchdog: Task<Void, Never>?
    private var preservesToolCleanupWrites = false
    private var lastFailurePhase: String?
    private var events: [[String: Any]] = []
    private final class PendingOperation {
        let receiver: Receiver
        let device: IOBluetoothDevice
        let kind: String
        let startedAt = NativeSwitchEvidence.now
        var channel: IOBluetoothRFCOMMChannel?
        init(receiver: Receiver, device: IOBluetoothDevice, kind: String) {
            self.receiver = receiver; self.device = device; self.kind = kind
        }
    }
    // The SDK exposes no cancellation primitive for async baseband/SDP. Keep
    // targets alive and drain their callbacks, rather than equating a generation
    // fence with OS cancellation or overlapping a new session with old work.
    private var pendingOperations: [UInt64: PendingOperation] = [:]

    init(configuration: Configuration = .smep) {
        self.configuration = configuration
        settingsStream = SamsungBudsSettingsPacket.Stream(profile: configuration.settingsProfile)
        super.init()
    }

    /// Strictly transport metadata: no peer addresses, packet payloads or account data.
    var diagnostics: [String: Any] {
        var value: [String: Any] = ["phase": plan.phase.rawValue,
            "channel_attempts": channelAttemptCount, "bluetooth_callbacks": connectionCallbacks,
            "discovery_callbacks": discoveryCallbacks, "channel_callbacks": channelCallbacks,
            "received_frames": receivedFrames, "received_fragments": receivedFragments,
            "received_bytes": receivedBytes, "sent_packets": sentPackets,
            "transmitted_packets": transmittedPackets, "pending_writes": writes.count,
            "pending_operations": NativeBudsOperationDrain.shared.count,
            "pending_details": pendingOperations.values.map {
                ["kind": $0.kind, "age_seconds": Int(max(0, NativeSwitchEvidence.now - $0.startedAt))] as [String: Any]
            }, "events": events]
        if let settingsOpening {
            value["phase"] = settingsOpening.plan.phase.rawValue
            value["channel_attempts"] = settingsOpening.plan.channelAttempts
            value["channel"] = settingsOpening.selectedChannel.map { Int($0) }
            value["last_status"] = settingsOpening.lastStatus.map { Int($0) }
        }
        if let selectedChannel { value["channel"] = Int(selectedChannel) }
        if let lastStatus { value["last_status"] = Int(lastStatus) }
        if let lastFailurePhase { value["last_failure_phase"] = lastFailurePhase }
        return value
    }

    private func record(_ kind: String, _ fields: [String: Any] = [:]) {
        var event = fields
        event["event"] = kind
        event["uptime"] = NativeSwitchEvidence.now
        events.append(event)
        if events.count > 16 { events.removeFirst(events.count - 16) }
    }

    deinit {
        deadline?.cancel()
        writeWatchdog?.cancel()
        let settings = settingsOpening
        let closing = settings == nil ? channel : nil
        if let settings { Task { @MainActor in settings.cancel() } }
        let retained = receiver
        for invocation in writeInvocations.values { invocation.cancel() }
        if let closing { Task { @MainActor in
            NativeBudsSDKWriter.close(closing)
            _ = retained
        } }
        opening?.resume(throwing: CancellationError())
    }

    func open(address: String) async throws {
        close()
        try Task.checkCancellation()
        guard NativeBudsOperationDrain.shared.count == 0 else {
            throw NativeBudsError(message: "O Bluetooth ainda está concluindo a tentativa anterior. Aguardando antes de reconectar.")
        }
        guard MacAudio.normalize(address).count == 12,
              let paired = IOBluetoothDevice(addressString: address), paired.isPaired(),
              MacAudio.normalize(paired.addressString ?? "") == MacAudio.normalize(address)
        else { throw NativeBudsError(message: "Os Buds selecionados não estão pareados com o Mac.") }
        let token = generation
        if configuration.isSettings {
            do { try await openSettings(paired, address: address, token: token) }
            catch {
                if generation == token { close() }
                throw error
            }
            return
        }
        // The live test showed isConnected()==false for both retained paired
        // objects while system_profiler reported the Buds connected. Issuing a
        // redundant async baseband open then waited for a callback indefinitely.
        let connected = try await MacAudio.isBluetoothConnected(address)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        device = paired
        plan.begin(cachedChannel: serviceChannel(paired), bluetoothConnected: connected)
        selectedChannel = nil; channelAttemptCount = 0; lastStatus = nil; lastFailurePhase = nil
        connectionCallbacks = 0; discoveryCallbacks = 0; channelCallbacks = 0
        events.removeAll()
        record("link_observed", ["connected": connected])
        receivedFrames = 0; receivedFragments = 0; receivedBytes = 0; sentPackets = 0; transmittedPackets = 0
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                opening = continuation
                if plan.phase == .bluetooth { connectBluetooth(token) }
                else {
                    apply(plan.serviceAction, token: token,
                          failure: "O serviço Samsung não está disponível no pareamento.")
                }
            }
        } onCancel: {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.close()
            }
        }
        try Task.checkCancellation()
    }

    private func openSettings(_ device: IOBluetoothDevice, address: String, token: UInt64) async throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        selectedChannel = nil; channelAttemptCount = 0; lastStatus = nil; lastFailurePhase = nil
        connectionCallbacks = 0; discoveryCallbacks = 0; channelCallbacks = 0
        receivedFrames = 0; receivedFragments = 0; receivedBytes = 0
        sentPackets = 0; transmittedPackets = 0; events.removeAll()
        let session = NativeBudsSettingsOpen(effects: NativeBudsSettingsOpenSDK.effects(device: device, address: address, uuid: uuid))
        settingsOpening = session
        let operation = stage
        session.progress = { [weak self] name, status in
            guard let self, self.current(token, operation) else { return }
            var fields: [String: Any] = ["main_thread": Thread.isMainThread]
            if let status { fields["status"] = Int(status) }
            self.record(name, fields)
        }
        session.bound = { [weak self, weak session] incoming in
            guard let self, self.current(token, operation), let id = session?.selectedChannel else { return }
            self.channel = incoming
            self.plan.begin(cachedChannel: id, bluetoothConnected: true)
            _ = self.plan.channelCompleted(success: true)
            self.record("rfcomm_sync_bound", ["profile": "spp_new"])
        }
        session.event = { [weak self] event in
            guard let self, self.current(token, operation) else { return }
            switch event {
            case .data(let channel, let bytes): self.received(channel, token: token, operation: operation, bytes: bytes)
            case .closed(let channel): self.closed(channel, token: token, operation: operation)
            case .written(let channel, let id, let status, let count):
                self.written(channel, token: token, operation: operation, id: id, status: status, bytesWritten: count)
            case .overflow: self.fail(NativeBudsError(message: "Fluxo SppNew excedeu o limite seguro."))
            case .opened: break
            }
        }
        try await session.open()
    }

    func send(_ packet: Data) throws {
        _ = try sendTracked(packet)
    }

    /// Only the isolated settings helper opts in. Its own tool watchdog queues
    /// the stop; a local write timeout must not cancel that queued invocation.
    func protectToolCleanupWrites() {
        guard configuration.isSettings, isOpen else { return }
        preservesToolCleanupWrites = true
        writeWatchdog?.cancel(); writeWatchdog = nil
    }

    @discardableResult func sendTracked(_ submittedPacket: Data) throws -> UInt {
        guard isOpen, let channel else { throw NativeBudsError(message: "O canal Samsung está fechado.") }
        let packet: Data
        if configuration.settingsProfile?.legacyFraming == true,
           let frame = SamsungBudsSettingsPacket.decodeCompleteFrame(submittedPacket) {
            packet = SamsungBudsSettingsPacket.frame(command: frame.command, payload: Array(frame.payload), profile: configuration.settingsProfile)
        } else { packet = submittedPacket }
        let minimum = configuration == .smep ? 8 : 7
        guard packet.count >= minimum, packet.count <= 1027 else { throw NativeBudsError(message: "Pacote Samsung fora do limite seguro.") }
        guard configuration.acceptsPacket(packet) else {
            throw NativeBudsError(message: "Pacote incompatível com o perfil Samsung selecionado.")
        }
        guard packet.count <= Int(channel.getMTU()), let id = writes.enqueue(at: NativeSwitchEvidence.now) else {
            throw NativeBudsError(message: "A transmissão Samsung está ocupada ou o pacote excede o MTU.")
        }
        // On macOS 27 writeAsync internally dispatches a blocking stream write
        // to main. Run writeSync on our non-reentrant SDK worker instead; its
        // return is local hardware completion, never a Samsung acknowledgment.
        let bytes = NSMutableData(data: packet)
        pendingPayloads[id] = bytes
        let token = generation, operation = stage
        guard let invocation = NativeBudsSDKWriter.send(packet, channel: channel,
            deadline: preservesToolCleanupWrites ? .greatestFiniteMagnitude : NativeSwitchEvidence.now + NativeBudsWriteTracker.timeout,
            completion: { [weak self] status, count in
                self?.written(channel, token: token, operation: operation, id: id, status: status, bytesWritten: count)
            }) else {
            writes.complete(id); pendingPayloads.removeValue(forKey: id)
            throw NativeBudsError(message: "O canal Samsung ainda está encerrando uma transmissão anterior.")
        }
        writeInvocations[id] = invocation
        sentPackets += 1
        record("tx_queued", ["command": Int(packet[packet.startIndex + configuration.commandOffset]), "length": packet.count])
        watchWrites()
        return id
    }

    func close() {
        generation &+= 1; stage &+= 1
        deadline?.cancel(); deadline = nil
        writeWatchdog?.cancel(); writeWatchdog = nil
        let continuation = opening; opening = nil
        if let settingsOpening {
            settingsOpening.cancel(); self.settingsOpening = nil
            channel = nil // The service owner already closed only its own stream.
        } else { releaseChannel() }
        for invocation in writeInvocations.values { invocation.cancel() }
        writeInvocations.removeAll()
        writes.reset(); pendingPayloads.removeAll()
        preservesToolCleanupWrites = false
        receiver = nil; device = nil
        if plan.phase != .failed { plan = NativeBudsOpeningPolicy() }
        stream = NativeBudsFrameStream()
        settingsStream = SamsungBudsSettingsPacket.Stream(profile: configuration.settingsProfile)
        continuation?.resume(throwing: CancellationError())
    }

    private func releaseChannel() {
        let old = channel; channel = nil
        // Pending opens keep their receiver until completion so a late-created
        // channel can be closed. Established channels can detach immediately.
        if let old { NativeBudsSDKWriter.close(old) }
    }
    private var uuid: IOBluetoothSDPUUID {
        let hex = configuration.serviceUUID.replacingOccurrences(of: "-", with: "")
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return IOBluetoothSDPUUID(data: Data(bytes))
    }
    private func serviceChannel(_ device: IOBluetoothDevice) -> UInt8? {
        var id: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: uuid),
              record.getRFCOMMChannelID(&id) == kIOReturnSuccess, (1...30).contains(id) else { return nil }
        return id
    }

    /// Every operation gets its own deadline and callback identity. Late SDP or
    /// channel callbacks cannot affect a fallback, cancellation or reopened session.
    private func beginStage(_ token: UInt64) -> Receiver {
        deadline?.cancel(); stage &+= 1
        let operation = stage
        let receiver = Receiver(owner: self, generation: token, stage: operation)
        self.receiver = receiver
        if let device {
            let pending = PendingOperation(receiver: receiver, device: device, kind: plan.phase.rawValue)
            pendingOperations[operation] = pending
            NativeBudsOperationDrain.shared.retain(pending, id: receiver.drainID) {
                if let late = pending.channel { NativeBudsSDKWriter.close(late) }
            }
        }
        let seconds = plan.timeout
        record("operation_started", ["kind": plan.phase.rawValue])
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.current(token, operation), self.opening != nil else { return }
            let failedPhase = self.plan.phase.rawValue
            self.record("operation_timeout", ["kind": failedPhase])
            self.lastFailurePhase = failedPhase
            let action = self.plan.timedOut()
            self.apply(action, token: token,
                failure: "A etapa \(self.phaseLabel(failedPhase)) não confirmou a conexão em \(Int(seconds)) segundos.")
        }
        return receiver
    }
    private func current(_ token: UInt64, _ operation: UInt64) -> Bool {
        generation == token && stage == operation
    }
    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "bluetooth": return "Bluetooth"
        case "discovery": return "de descoberta do serviço Samsung"
        default: return "do canal Samsung"
        }
    }
    private func apply(_ action: NativeBudsOpeningPolicy.Action, token: UInt64, failure: String) {
        guard generation == token, opening != nil else { return }
        switch action {
        case .queryService:
            if configuration.isSettings { fail(NativeBudsError(message: failure)) }
            else { queryService(token) }
        case .openChannel(let id): openChannel(id, token: token)
        case .fail: fail(NativeBudsError(message: failure))
        }
    }
    private func connectBluetooth(_ token: UInt64) {
        guard configuration == .smep else {
            fail(NativeBudsError(message: "Ajustes não podem iniciar uma conexão Bluetooth.")); return
        }
        guard generation == token, opening != nil, let device else { return }
        let receiver = beginStage(token)
        let status = device.openConnection(receiver, withPageTimeout: 12800, authenticationRequired: true)
        lastStatus = status
        if status != kIOReturnSuccess {
            settleOperation(stage)
            let connected = device.isConnected()
            apply(plan.bluetoothCompleted(success: connected), token: token,
                  failure: "Não foi possível conectar os Buds por Bluetooth (código \(status)).")
        }
    }
    private func connected(_ token: UInt64, operation: UInt64, status: IOReturn) {
        guard current(token, operation), opening != nil, plan.phase == .bluetooth else { return }
        connectionCallbacks += 1; lastStatus = status
        apply(plan.bluetoothCompleted(success: status == kIOReturnSuccess), token: token,
              failure: "A conexão Bluetooth dos Buds falhou (código \(status)).")
    }
    private func queryService(_ token: UInt64) {
        guard generation == token, opening != nil, let device else { return }
        let receiver = beginStage(token)
        let status = device.performSDPQuery(receiver, uuids: [uuid])
        lastStatus = status
        if status != kIOReturnSuccess {
            settleOperation(stage)
            lastFailurePhase = "discovery"
            apply(plan.discoveryCompleted(channel: nil), token: token,
                  failure: "O serviço Samsung não respondeu e não há canal no pareamento (código \(status)).")
        }
    }
    private func queried(_ token: UInt64, operation: UInt64, status: IOReturn) {
        guard current(token, operation), opening != nil, plan.phase == .discovery else { return }
        discoveryCallbacks += 1; lastStatus = status
        let id = status == kIOReturnSuccess ? device.flatMap(serviceChannel) : nil
        apply(plan.discoveryCompleted(channel: id), token: token,
              failure: "Serviço Samsung SMEP indisponível nos Buds (código \(status)).")
    }
    private func openChannel(_ id: UInt8, token: UInt64) {
        guard generation == token, opening != nil, let device else { return }
        releaseChannel()
        selectedChannel = id
        channelAttemptCount += 1
        let receiver = beginStage(token)
        let status = device.openRFCOMMChannelAsync(&channel, withChannelID: id, delegate: receiver)
        pendingOperations[stage]?.channel = channel
        lastStatus = status
        if status != kIOReturnSuccess {
            settleOperation(stage)
            lastFailurePhase = "channel"
            let action = plan.channelCompleted(success: false) ?? .fail
            apply(action, token: token, failure: "Não foi possível abrir o canal Samsung (código \(status)).")
        }
    }
    private func opened(_ incoming: IOBluetoothRFCOMMChannel?, token: UInt64, operation: UInt64, status: IOReturn) {
        guard current(token, operation), opening != nil, plan.phase == .channel else {
            // An old open-complete can already be queued when Stop/fallback
            // detaches its delegate. Do not leave that late channel alive.
            if let incoming, incoming !== channel { NativeBudsSDKWriter.close(incoming) }
            return
        }
        guard let incoming, incoming === channel else { return }
        channelCallbacks += 1; lastStatus = status
        if let action = plan.channelCompleted(success: status == kIOReturnSuccess && incoming.isOpen()) {
            lastFailurePhase = "channel"
            apply(action, token: token, failure: "A abertura do canal Samsung falhou (código \(status)).")
        } else {
            deadline?.cancel(); deadline = nil
            let continuation = opening; opening = nil
            continuation?.resume()
        }
    }
    private func fail(_ error: NativeBudsError, physicalClose: Bool = false) {
        if plan.phase != .failed { lastFailurePhase = plan.phase.rawValue }
        if preservesToolCleanupWrites, !physicalClose, isOpen {
            onFailure?(error)
            return
        }
        let continuation = opening; opening = nil
        close()
        if let continuation { continuation.resume(throwing: error) }
        else { onFailure?(error) }
    }

    private func settleOperation(_ operation: UInt64) {
        guard let completed = pendingOperations.removeValue(forKey: operation) else { return }
        NativeBudsOperationDrain.shared.complete(completed.receiver.drainID, orphaned: false)
        if let late = completed.channel, late !== channel {
            NativeBudsSDKWriter.close(late)
        }
    }

    private func watchWrites() {
        guard !preservesToolCleanupWrites, writeWatchdog == nil else { return }
        let token = generation, operation = stage
        writeWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.current(token, operation), self.isOpen else { return }
                if self.writes.expired(at: NativeSwitchEvidence.now) {
                    self.fail(NativeBudsError(message: "A transmissão no canal Samsung não terminou em cinco segundos.")); return
                }
                if self.writes.count == 0 { self.writeWatchdog = nil; return }
            }
        }
    }
    private func written(_ incoming: IOBluetoothRFCOMMChannel?, token: UInt64, operation: UInt64, id: UInt, status: IOReturn, bytesWritten: Int? = nil) {
        guard current(token, operation), let incoming, incoming === channel, writes.complete(id) else { return }
        writeInvocations.removeValue(forKey: id)
        let payload = pendingPayloads.removeValue(forKey: id)
        let expected = payload?.length
        var event: [String: Any] = ["status": Int(status)]
        if let payload, payload.length > configuration.commandOffset {
            event["command"] = Int(payload.bytes.load(fromByteOffset: configuration.commandOffset, as: UInt8.self))
        }
        record("tx_completed", event)
        lastStatus = status
        guard status == kIOReturnSuccess, bytesWritten == nil || bytesWritten == expected else {
            let error = NativeBudsError(message: "A transmissão no canal Samsung falhou (código \(status)).")
            if preservesToolCleanupWrites, let onWriteFailure { onWriteFailure(id, error) }
            else { fail(error) }
            return
        }
        transmittedPackets += 1
        onWriteComplete?(id)
    }

    private func received(_ incoming: IOBluetoothRFCOMMChannel?, token: UInt64, operation: UInt64, bytes: Data?) {
        guard current(token, operation), let incoming, incoming === channel, isOpen else { return }
        guard let bytes else { fail(NativeBudsError(message: "Bloco Samsung excedeu o limite seguro.")); return }
        receivedBytes += bytes.count
        do {
            for offset in stride(from: 0, to: bytes.count, by: 4096) {
                let chunk = Data(bytes[offset..<min(offset + 4096, bytes.count)])
                if configuration.isSettings {
                    let frames = try settingsStream.append(chunk, at: NativeSwitchEvidence.now)
                    receivedFragments = settingsStream.fragmentCount
                    for frame in frames {
                        guard current(token, operation), isOpen else { return }
                        receivedFrames += 1
                        record("rx_frame", ["command": Int(frame.command), "payload_length": frame.payload.count])
                        onSettingsFrame?(frame)
                    }
                    continue
                }
                let frames = try stream.append(chunk, at: NativeSwitchEvidence.now)
                receivedFragments = stream.fragmentCount
                for frame in frames {
                    guard current(token, operation), isOpen else { return }
                    receivedFrames += 1
                    record("rx_frame", SamsungMdePacket.diagnosticSummary(frame))
                    onFrame?(frame)
                }
            }
        } catch { fail(NativeBudsError(message: "Fluxo Samsung inválido; canal encerrado.")) }
    }
    private func closed(_ incoming: IOBluetoothRFCOMMChannel?, token: UInt64, operation: UInt64) {
        guard current(token, operation), let incoming, incoming === channel else { return }
        if opening != nil, plan.phase == .channel {
            let action = plan.channelCompleted(success: false) ?? .fail
            apply(action, token: token, failure: "O canal Samsung fechou durante a abertura.")
        } else { fail(NativeBudsError(message: "A conexão de controle Samsung foi interrompida."), physicalClose: true) }
    }

    // Compatibility delegate entry points for direct callback tests. Production
    // uses the operation-bound receiver below, never these unscoped callbacks.
    nonisolated func rfcommChannelClosed(_ incoming: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closed(incoming, token: self.generation, operation: self.stage)
        }
    }

    /// Serialize callback delivery on the main queue, including callbacks invoked
    /// synchronously by IOBluetooth. Out parameters are assigned before handling
    /// open-complete, and data chunks cannot race ahead via unstructured Tasks.
    // Immutable operation identity; pending byte counters are locked, and owner
    // methods are accessed only from the main queue. IOBluetooth predates Sendable.
    private final class Receiver: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
        weak var owner: NativeBudsTransport?
        let generation: UInt64
        let stage: UInt64
        let drainID = UUID()
        private let deliveryLock = NSLock()
        private var pendingBytes = 0
        private var queueOverrun = false
        init(owner: NativeBudsTransport, generation: UInt64, stage: UInt64) {
            self.owner = owner; self.generation = generation; self.stage = stage
        }
        private func deliver(_ body: @escaping @MainActor () -> Void) {
            deliveryLock.lock()
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            deliveryLock.unlock()
        }
        @MainActor private func settle() {
            NativeBudsOperationDrain.shared.complete(drainID, orphaned: owner == nil)
            owner?.settleOperation(stage)
        }
        @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            deliver { [self] in
                settle()
                owner?.connected(generation, operation: stage, status: status)
            }
        }
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            deliver { [self] in
                settle()
                owner?.queried(generation, operation: stage, status: status)
            }
        }
        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
            deliver { [self] in
                settle()
                if let owner { owner.opened(channel, token: generation, operation: stage, status: status) }
                else if let channel { NativeBudsSDKWriter.close(channel) }
            }
        }
        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
            guard let pointer, count > 0 else { return }
            // A callback may contain several complete frames. Keep a bounded copy;
            // the assembler processes it in small chunks without dropping valid batches.
            deliveryLock.lock()
            guard count <= 65536, pendingBytes <= 262144 - count else {
                if !queueOverrun {
                    queueOverrun = true
                    DispatchQueue.main.async { [self] in
                        owner?.received(channel, token: generation, operation: stage, bytes: nil)
                    }
                }
                deliveryLock.unlock(); return
            }
            let bytes = Data(bytes: pointer, count: count)
            pendingBytes += count
            DispatchQueue.main.async { [self] in
                defer { deliveryLock.lock(); pendingBytes -= count; deliveryLock.unlock() }
                owner?.received(channel, token: generation, operation: stage, bytes: bytes)
            }
            deliveryLock.unlock()
        }
        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
            deliver { [self] in
                settle()
                owner?.closed(channel, token: generation, operation: stage)
            }
        }
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
            let id = UInt(bitPattern: refcon)
            deliver { [self] in owner?.written(channel, token: generation, operation: stage, id: id, status: status) }
        }
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn, bytesWritten: Int) {
            let id = UInt(bitPattern: refcon)
            deliver { [self] in owner?.written(channel, token: generation, operation: stage, id: id, status: status, bytesWritten: bytesWritten) }
        }
    }
}


