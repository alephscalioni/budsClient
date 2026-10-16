import Foundation

/// Pure, physical-session-scoped evidence. A cached bootstrap keeps its original
/// battery observation date even when a verified individual setting changes.
struct NativeBudsSettingsEvidence {
    typealias Packet = SamsungBudsSettingsPacket
    struct Observation {
        var frame: Packet.Frame
        let monotonic: TimeInterval
        let date: Date
    }
    private struct Write {
        let owner: UUID
        let command: UInt8
        let payload: [UInt8]
        var id: UInt?
        var completed = false
        var acknowledged = false
        var noiseFeedback: Packet.NoiseMode?
    }
    private(set) var generation = UUID()
    private(set) var observation: Observation?
    private var write: Write?

    mutating func reset() {
        generation = UUID(); observation = nil; write = nil
    }
    mutating func release() { write = nil }
    mutating func arm(_ frame: Packet.Frame, owner: UUID) -> Bool {
        // Use the ACK validator as the closed command/payload whitelist.
        let ack = Packet.Frame(command: 0x42, payload: Data([frame.command]) + frame.payload, isFragment: false)
        guard !frame.isFragment, write == nil,
              observation.map({ Packet.physicalBuds3Pro($0.frame) == true }) == true,
              (Packet.acknowledges(ack, command: frame.command, payload: Array(frame.payload))
               || (frame.command == SamsungBudsCustomEqualizer.selectionCommand
                   && frame.payload == Data([SamsungBudsCustomEqualizer.customSelection])
                   && SamsungBudsCustomEqualizer.acknowledgesSelection(ack))) else { return false }
        if frame.command == 0x90 {
            guard let observed = observation.flatMap({ Packet.status($0.frame, model: "Buds3Pro") }),
                  let touch = observed.touchControls else { return false }
            let parameters = Array(frame.payload)
            guard touch.payload(enabled: parameters[0] == 1) == parameters
                || touch.mediaPayload(enabled: parameters[1] == 1) == parameters
                || touch.admitsIndividualUpdate(parameters) else { return false }
        }
        if let setting = Packet.Setting.forCommand(frame.command) {
            guard observation.flatMap({ Packet.status($0.frame, model: "Buds3Pro") })?.settings[setting] != nil else { return false }
        }
        write = Write(owner: owner, command: frame.command, payload: Array(frame.payload))
        return true
    }
    mutating func track(_ id: UInt, owner: UUID) {
        guard write?.owner == owner else { return }
        write?.id = id
    }
    mutating func written(_ id: UInt, generation: UUID, owner: UUID) {
        guard self.generation == generation, write?.owner == owner, write?.id == id else { return }
        write?.completed = true
        mergeIfVerified()
    }
    mutating func receive(_ frame: Packet.Frame, at now: TimeInterval, date: Date, generation: UUID, owner: UUID?) {
        guard self.generation == generation, !frame.isFragment else { return }
        if frame.command == 0x61 {
            guard Packet.status(frame, model: "Buds3Pro") != nil else {
                observation = nil; write = nil; return
            }
            observation = Observation(frame: frame, monotonic: now, date: date)
        } else if let noise = Packet.noiseUpdate(frame) {
            mutate { $0[12] = noise.rawValue }
            if write?.command == 0x78 { write?.noiseFeedback = noise }
        } else if let pending = write, pending.owner == owner,
                  (Packet.acknowledges(frame, command: pending.command, payload: pending.payload)
                   || (pending.command == SamsungBudsCustomEqualizer.selectionCommand
                       && pending.payload == [SamsungBudsCustomEqualizer.customSelection]
                       && SamsungBudsCustomEqualizer.acknowledgesSelection(frame))) {
            write?.acknowledged = true
        }
        mergeIfVerified()
    }
    private mutating func mutate(_ update: (inout [UInt8]) -> Void) {
        guard var observed = observation else { return }
        var bytes = Array(observed.frame.payload)
        update(&bytes)
        observed.frame = Packet.Frame(command: 0x61, payload: Data(bytes), isFragment: false)
        observation = observed
    }
    private mutating func mergeIfVerified() {
        guard let pending = write, pending.id != nil, pending.completed, pending.acknowledged,
              pending.noiseFeedback.map({ pending.command != 0x78 || pending.payload == [$0.rawValue] }) ?? true else { return }
        switch pending.command {
        case 0x78: mutate { $0[12] = pending.payload[0] }
        case 0x86: mutate { $0[9] = pending.payload[0] }
        case 0x90: mutate { bytes in
            // Every admitted operation preserves unrelated fields. Reconstruct
            // the exact echoed flags without renewing the observation date.
            let masks: [UInt8] = [0x80, 0x08, 0x04, 0x02, 0x01, 0x10, 0x20, 0x40]
            bytes[10] = zip(pending.payload.prefix(8), masks).reduce(UInt8(0)) { $0 | ($1.0 == 1 ? $1.1 : 0) }
        }
        default:
            if let setting = Packet.Setting.forCommand(pending.command),
               let current = observation, Packet.status(current.frame, model: "Buds3Pro")?.settings[setting] != nil {
                mutate { $0[setting.statusOffset] = pending.payload[0] }
            }
        }
        write = nil
    }
}

/// Injectable physical effects. Tests never construct IOBluetooth or touch audio.
@MainActor struct NativeBudsSettingsConnectionEffects {
    typealias Packet = SamsungBudsSettingsPacket
    var bind: (@escaping (Packet.Frame) -> Void, @escaping (UInt) -> Void, @escaping (NativeBudsError) -> Void) -> Void
    var open: (String) async throws -> Void
    var isOpen: () -> Bool
    var send: (Data) throws -> UInt
    var close: () -> Void
    var now: () -> TimeInterval = { NativeSwitchEvidence.now }
    var date: () -> Date = { Date() }
    var diagnostics: () -> [String: Any] = { [:] }

    static func live() -> Self {
        let transport = NativeBudsSettingsProcess()
        return Self(bind: { transport.onSettingsFrame = $0; transport.onWriteComplete = $1; transport.onFailure = $2 },
            open: { try await transport.open(address: $0) }, isOpen: { transport.isOpen },
            send: { try transport.sendTracked($0) }, close: { transport.close() },
            now: { transport.observationStamp?.0 ?? NativeSwitchEvidence.now },
            date: { transport.observationStamp?.1 ?? Date() },
            diagnostics: { transport.diagnostics })
    }
}

/// One retained SppNew stream per selected peer. Only listener ownership changes
/// between transactions. A cancelled/failed operation resets the physical session.
@MainActor final class NativeBudsSettingsConnection {
    private let effects: NativeBudsSettingsConnectionEffects
    private var address: String?
    private var evidence = NativeBudsSettingsEvidence()
    private var replayDate: (TimeInterval, Date)?
    private var attempted = false
    private var opening: UUID?
    private var owner = UUID()
    private var frame: ((SamsungBudsSettingsPacket.Frame) -> Void)?
    private var written: ((UInt) -> Void)?
    private var failed: ((NativeBudsError) -> Void)?

    init(effects: NativeBudsSettingsConnectionEffects? = nil) {
        self.effects = effects ?? .live()
    }
    deinit {
        let effects = effects
        Task { @MainActor in effects.close() }
    }
    private func invalidateClosed() {
        if attempted && opening == nil && !effects.isOpen() { evidence.reset(); replayDate = nil }
    }
    var alive: Bool? { invalidateClosed(); return attempted ? effects.isOpen() : nil }
    var continuous: Bool { invalidateClosed(); return effects.isOpen() && evidence.observation != nil }
    var observation: (TimeInterval, Date)? { replayDate }
    var diagnostics: [String: Any] { effects.diagnostics() }
    func handlers(_ frame: ((SamsungBudsSettingsPacket.Frame) -> Void)?, _ written: ((UInt) -> Void)?, _ failed: ((NativeBudsError) -> Void)?) {
        evidence.release(); owner = UUID()
        self.frame = frame; self.written = written; self.failed = failed
    }
    func open(_ address: String) async throws {
        let normalized = BudsBatterySnapshot.normalize(address)
        if self.address == normalized, effects.isOpen() {
            if let observed = evidence.observation {
                replayDate = (observed.monotonic, observed.date)
                frame?(observed.frame)
                replayDate = nil
            }
            return // No fabricated request or reopen if bootstrap has not arrived.
        }
        evidence.reset(); replayDate = nil
        self.address = normalized; attempted = true
        let generation = evidence.generation
        effects.bind({ [weak self] value in
            guard let self, self.evidence.generation == generation else { return }
            if SamsungBudsSettingsPacket.physicalBuds3Pro(value) == false {
                self.evidence.reset(); self.effects.close()
                self.failed?(NativeBudsError(message: "O estado físico identifica outro modelo de Buds. Ajustes bloqueados."))
                return
            }
            self.evidence.receive(value, at: self.effects.now(), date: self.effects.date(), generation: generation, owner: self.owner)
            self.frame?(value)
        }, { [weak self] id in
            guard let self, self.evidence.generation == generation else { return }
            self.evidence.written(id, generation: generation, owner: self.owner)
            self.written?(id)
        }, { [weak self] error in
            guard let self, self.evidence.generation == generation else { return }
            self.evidence.reset(); self.replayDate = nil
            self.failed?(error)
        })
        opening = generation
        defer { if opening == generation { opening = nil } }
        do { try await effects.open(address) }
        catch {
            if evidence.generation == generation { evidence.reset(); replayDate = nil }
            throw error
        }
    }
    func send(_ bytes: Data) throws -> UInt {
        guard effects.isOpen(), let packet = SamsungBudsSettingsPacket.decodeCompleteFrame(bytes),
              let observed = evidence.observation else {
            throw NativeBudsError(message: "Comando sem sessão física observada.")
        }
        let typedDeviceRequest = (packet.command != SamsungBudsCustomEqualizer.selectionCommand
            && SamsungBudsCustomEqualizer.permits(packet)) || SamsungBudsFirmwareVersion.permits(packet)
        if NativeBudsToolsPacket.permits(packet) || typedDeviceRequest {
            guard SamsungBudsSettingsPacket.physicalBuds3Pro(observed.frame) == true else {
                throw NativeBudsError(message: "Ferramenta indisponível sem modelo físico confirmado.")
            }
            // These operations have typed results/readback in the model, not
            // ordinary setting echoes. The custom selector separately uses the
            // exact ACK+SDK evidence path so retained status preserves its value.
            return try effects.send(bytes)
        }
        guard evidence.arm(packet, owner: owner) else {
            throw NativeBudsError(message: "Comando de ajustes sem sessão observada ou já em andamento.")
        }
        do {
            let id = try effects.send(bytes)
            evidence.track(id, owner: owner)
            return id
        } catch { evidence.release(); throw error }
    }
    func releaseTransaction() { handlers(nil, nil, nil) }
    func reset() {
        handlers(nil, nil, nil); evidence.reset(); replayDate = nil; address = nil; attempted = false; opening = nil
        effects.close()
    }
}
