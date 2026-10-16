import Foundation
import CoreFoundation

/// Injectable effects; fake model tests never construct Bluetooth, audio, cloud
/// or the legacy client. No timer polls or reconnects the radio.
@MainActor struct NativeBudsSettingsEnvironment {
    var now: () -> TimeInterval
    var date: () -> Date
    var sleep: (TimeInterval) async throws -> Void
    var connected: (String) async throws -> Bool
    var handlers: (((SamsungBudsSettingsPacket.Frame) -> Void)?, ((UInt) -> Void)?, ((NativeBudsError) -> Void)?) -> Void
    var open: (String) async throws -> Void
    var send: (Data) throws -> UInt
    var close: () -> Void
    var reset: () -> Void = {}
    var statusTimestamp: () -> (TimeInterval, Date)? = { nil }
    var continuousStatus: () -> Bool = { false }
    var sessionAlive: () -> Bool? = { nil }
    var diagnostics: () -> [String: Any] = { [:] }
    var toolsPermission: () -> Bool = { false }

    static func live(toolsPermission: @escaping () -> Bool = { false }) -> Self {
        let connection = NativeBudsSettingsConnection()
        return Self(now: { NativeSwitchEvidence.now }, date: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) },
            connected: { try await MacAudio.isBluetoothConnected($0) },
            handlers: { connection.handlers($0, $1, $2) },
            open: { try await connection.open($0) },
            send: { try connection.send($0) }, close: { connection.releaseTransaction() },
            reset: { connection.reset() }, statusTimestamp: { connection.observation },
            continuousStatus: { connection.continuous }, sessionAlive: { connection.alive },
            diagnostics: { connection.diagnostics }, toolsPermission: toolsPermission)
    }
}

@MainActor final class NativeBudsSettingsModel {
    typealias Packet = SamsungBudsSettingsPacket

    enum Action: Equatable {
        case refresh, noise(Packet.NoiseMode), equalizer(Int), touch(Bool), mediaControls(Bool)
        case gesture(Packet.Gesture, Bool), setting(Packet.Setting, Int)
        case find(NativeBudsToolsPacket.Target), fitTest
        case customEqualizerRead, customEqualizer([Int]), info

        static func parse(_ request: [String: Any]) -> Action? {
            switch request["action"] as? String {
            case "device.refresh": return .refresh
            case "device.custom_eq_read": return .customEqualizerRead
            case "device.custom_eq":
                guard let bands = SamsungBudsCustomEqualizer.parseBands(request["bands"]) else { return nil }
                return .customEqualizer(bands)
            case "device.info": return .info
            case "device.find":
                guard let raw = request["target"] as? String, let target = NativeBudsToolsPacket.Target(rawValue: raw) else { return nil }
                return .find(target)
            case "device.fit_test": return .fitTest
            case "device.noise":
                guard let name = request["mode"] as? String, let mode = Packet.NoiseMode(name: name) else { return nil }
                return .noise(mode)
            case "device.equalizer":
                guard let value = request["preset"] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                      (0...5).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue else { return nil }
                return .equalizer(value.intValue)
            case "device.touch":
                guard let value = request["enabled"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return .touch(value.boolValue)
            case "device.media_controls":
                guard let value = request["enabled"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return .mediaControls(value.boolValue)
            case "device.gesture":
                guard let name = request["gesture"] as? String, let gesture = Packet.Gesture(rawValue: name),
                      let value = request["enabled"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                return .gesture(gesture, value.boolValue)
            case "device.setting":
                guard let key = request["key"] as? String, let setting = Packet.Setting(rawValue: key),
                      let value = request["value"] as? NSNumber else { return nil }
                if setting.isBoolean {
                    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
                    return .setting(setting, value.boolValue ? 1 : 0)
                }
                guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                      value.doubleValue.rounded() == value.doubleValue,
                      (Double(setting.values.lowerBound)...Double(setting.values.upperBound)).contains(value.doubleValue) else { return nil }
                return .setting(setting, value.intValue)
            default: return nil
            }
        }
    }

    private struct Selection: Equatable {
        let address: String
        let name: String
        let model: String?
        let connectionEpoch: UUID?
        var supported: Bool { model == "Buds3Pro" }
        var inspectable: Bool { model == nil || supported }
    }
    private enum Phase { case idle, reading, openingCommand, command, customWrite, customRead, firmwareRead }
    private let environment: NativeBudsSettingsEnvironment
    private var selection: Selection?
    private var blocked = false
    /// With automatic switching active, release SppNew after each completed
    /// transaction. A verified, dated observation survives; the next write still
    /// opens and verifies a new physical session before sending anything.
    var releaseAfterTransaction = false
    private var parked = false
    private var generation: UInt64 = 0
    private var session: UUID?
    private var phase: Phase = .idle
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var responseDeadline: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Error>?
    private var storedReadStatus: Packet.Status?
    private var readStatus: Packet.Status? {
        get { environment.sessionAlive() == false ? nil : storedReadStatus }
        set { storedReadStatus = newValue }
    }
    private var physicalModelVerified = false
    private var settingsObservedDate: Date?
    private var settingsObservedAt: TimeInterval?
    private struct Observation {
        let status: Packet.Status
        let at: TimeInterval
        let date: Date
        var mayHaveChanged: Bool
    }
    private var lastObservation: Observation?
    private var observationRevision: UInt64 = 0
    private var readObservedAt: TimeInterval?
    private var readObservedDate: Date?
    private var expectedCommand: UInt8?
    private var expectedPayload: [UInt8] = []
    private var writeID: UInt?
    private var writeCompleted = false
    private var echoMatched = false
    private var unverifiedEcho = false
    private var noiseFeedback: Packet.NoiseMode?
    private var link: Bool?
    private var linkObservedAt: TimeInterval?
    private var noise: Packet.NoiseMode?
    private var equalizer: Int?
    private var rawEqualizer: UInt8?
    // Only actual replies, published after the corresponding SDK completion.
    // Dated readings survive panel cancellation; peer/connection changes clear
    // them. Neither saved slots nor a zero-filled default is device evidence.
    private var customBands: [Int]?
    private var customObservedDate: Date?
    private var firmwareVersion: String?
    private var firmwareObservedDate: Date?
    private var pendingCurve: SamsungBudsCustomEqualizer.Curve?
    private var pendingVersion: String?
    private var pendingReplyDate: Date?
    private var requestStartedAt: TimeInterval?
    private var customSelectionArmed = false
    private var deviceRequestActive = false
    private var ambientLevel: Int?
    private var touchEnabled: Bool?
    private var mediaControlsEnabled: Bool?
    private var mediaControlsMixed = false
    // Samsung CardNoiseControls rejects another UI change within 1500 ms.
    // Anchor our interval to verified completion, conservatively covering the
    // firmware transition even when short SppNew sessions are reopened quickly.
    private var lastNoiseConfirmation: TimeInterval?
    private var preservedTouch: Packet.TouchControls?
    private var settings: [Packet.Setting: Int] = [:]
    private(set) var busy = false
    private(set) var status = "Selecione os Buds3 Pro para ler os ajustes."
    private(set) var error: String?
    private(set) var batterySnapshot: BudsBatterySnapshot?
    private var leftPlacement: Packet.Placement?
    private var rightPlacement: Packet.Placement?
    private var toolKind: NativeBudsToolsWatchdog.Kind?
    private enum ToolWait { case write, mute([UInt8]), searching, fitResult }
    private var toolWait: ToolWait = .write
    private var findStopped = false
    private var findStopRequested = false
    private var waitIdentity: UUID?
    private var muteMatched = false
    private var pendingFitResult: NativeBudsToolsPacket.FitResult?
    private var pendingFitDate: Date?
    private var fitResult: NativeBudsToolsPacket.FitResult?
    private var fitDate: Date?
    var toolInProgress: Bool { toolKind != nil && busy }

    init(environment: NativeBudsSettingsEnvironment? = nil) {
        self.environment = environment ?? .live()
    }

    deinit {
        operation?.cancel(); deadline?.cancel(); responseDeadline?.cancel()
        waiter?.resume(throwing: CancellationError())
        let environment = environment
        Task { @MainActor in environment.handlers(nil, nil, nil); environment.close(); environment.reset() }
    }

    /// Address/model changes fence all queued callbacks and cancel the owned
    /// RFCOMM session. Canonical paired names use the same identification as the
    /// probe; an explicit different model always wins over a suggestive name.
    func select(address: String, name: String, model: String?, blocked: Bool, connectionEpoch: UUID? = nil) {
        let address = BudsBatterySnapshot.normalize(address)
        let canonical = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let identified = model.flatMap { $0.isEmpty ? nil : $0 }
            ?? (["buds3pro", "galaxybuds3pro"].contains(canonical) ? "Buds3Pro" : nil)
        let next = address.count == 12 ? Selection(address: address, name: name, model: identified, connectionEpoch: connectionEpoch) : nil
        // A presentation-cache model upgrade or renamed paired alias is not a
        // different radio identity. Preserve physically verified state/session.
        let differentDevice = next?.address != selection?.address
            || (next?.model != selection?.model && next?.inspectable == false)
        let changed = differentDevice || next?.connectionEpoch != selection?.connectionEpoch
        let wasBlocked = self.blocked
        if changed {
            cancel()
            fitResult = nil; fitDate = nil
            lastObservation = nil
            clearDeviceReadings()
            lastNoiseConfirmation = nil
            if differentDevice { batterySnapshot = nil }
        } else if blocked && !self.blocked {
            suspend()
        }
        selection = next; self.blocked = blocked
        if blocked { status = "Aguarde o término da alternância e da recuperação de áudio para ajustar os Buds." }
        else if next?.supported != true { status = "Ajustes nativos disponíveis somente para Buds3 Pro identificados." }
        else if changed || wasBlocked { status = "Atualize para ler os ajustes dos Buds3 Pro conectados ao Mac." }
    }

    /// Pure snapshot: reading this every 600 ms never probes or opens Bluetooth.
    var snapshot: [String: Any] {
        let diagnostics = environment.diagnostics()
        let sdkIdle = (diagnostics["pending_operations"] as? Int).map { $0 == 0 } ?? true
        let fresh = linkObservedAt.map { environment.now() >= $0 && environment.now() - $0 <= 30 } == true
        let connected = !parked && environment.sessionAlive() == false ? false : (fresh ? link : nil)
        let alive = parked ? fresh && link == true : environment.sessionAlive() != false
        let canControl = selection?.inspectable == true && physicalModelVerified && alive && !blocked && sdkIdle
        let canStartTool = selection?.inspectable == true && !blocked && !busy && sdkIdle && environment.toolsPermission()
        let readFresh = settingsObservedAt.map { environment.now() >= $0 && environment.now() - $0 <= 30 } == true
        let touchFresh = settingsObservedDate.map {
            let age = environment.date().timeIntervalSince($0)
            return age >= 0 && age <= 15
        } == true
        let canReadDevice = canControl && !busy && deviceStatusFresh
        var message = status
        if !busy, !alive { message = "Canal de ajustes encerrado. Atualize para uma nova leitura." }
        else if !busy, link != nil, !fresh, canControl { message = "Leitura anterior. Atualize para confirmar a conexão e os ajustes." }
        return ["available": true, "busy": busy, "connected": connected.map { $0 as Any } ?? NSNull(),
            "model_verified": physicalModelVerified,
            "read_fresh": readFresh,
            "observation_revision": observationRevision,
            "last_observation": lastObservationFields,
            "transport_diagnostics": diagnostics,
            "can_control": canControl, "can_refresh": selection?.inspectable == true && !blocked && !busy && sdkIdle,
            "can_touch": canControl && preservedTouch != nil && touchFresh,
            "observed_at": settingsObservedDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "noise_mode": (alive ? noise : nil).map { $0.name as Any } ?? NSNull(),
            "equalizer": (alive ? equalizer : nil).map { $0 as Any } ?? NSNull(),
            "equalizer_raw": (alive ? rawEqualizer : nil) as Any? ?? NSNull(),
            "equalizer_enabled": (alive ? rawEqualizer.map { $0 != 0 } : nil) as Any? ?? NSNull(),
            "equalizer_custom": (alive ? rawEqualizer.map { $0 == SamsungBudsCustomEqualizer.customSelection } : nil) as Any? ?? NSNull(),
            "custom_eq_bands": customBands as Any? ?? NSNull(),
            "custom_eq_observed_at": customObservedDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            "can_custom_eq_read": canReadDevice, "can_custom_eq_write": canReadDevice,
            "firmware_version": firmwareVersion as Any? ?? NSNull(),
            "firmware_observed_at": firmwareObservedDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            "can_info": canReadDevice,
            "ambient_level": (alive ? ambientLevel : nil).map { $0 as Any } ?? NSNull(),
            "touch_enabled": (alive ? touchEnabled : nil).map { $0 as Any } ?? NSNull(),
            "media_controls_enabled": (alive ? mediaControlsEnabled : nil).map { $0 as Any } ?? NSNull(),
            "media_controls_mixed": alive && mediaControlsMixed,
            "touch_controls": alive ? preservedTouch?.fields ?? [:] : [:],
            "tools": ["active": toolInProgress, "kind": toolKind?.rawValue as Any? ?? NSNull(),
                // Starting always obtains fresh physical identity and placement.
                // A parked reading must not require a separate refresh click.
                "can_find": canStartTool, "can_fit": canStartTool,
                "left_placement": (alive ? leftPlacement?.name : nil) as Any? ?? NSNull(),
                "right_placement": (alive ? rightPlacement?.name : nil) as Any? ?? NSNull(),
                "fit_result": fitResult?.fields as Any? ?? NSNull(),
                "fit_observed_at": fitDate?.timeIntervalSince1970 as Any? ?? NSNull()],
            "settings": alive ? Dictionary(uniqueKeysWithValues: settings.map { key, value in
                (key.rawValue, key.isBoolean ? (value == 1) as Any : value as Any)
            }) : [:],
            "status": message, "error": error.map { $0 as Any } ?? NSNull()]
    }

    func perform(_ request: [String: Any]) {
        if request["action"] as? String == "device.tools_cancel" {
            if toolKind == .find, toolInProgress, case .searching = toolWait {
                findStopRequested = true; resumeIfReady()
            } else if toolInProgress { cancel() }
            return
        }
        guard let action = Action.parse(request) else {
            if !busy { error = "Comando de ajustes inválido." }
            return
        }
        perform(action)
    }

    func perform(_ action: Action) {
        guard !busy else { return } // One command at a time; never queue stale UI intents.
        guard let selected = selection, selected.inspectable, !blocked else {
            error = "Os ajustes não estão disponíveis para a seleção atual."; return
        }
        if case .equalizer(let preset) = action, !(0...5).contains(preset) {
            error = "Predefinição de equalizador inválida."; return
        }
        if case .setting(let setting, let value) = action, setting.wireValue(value) == nil {
            error = "Valor de ajuste inválido."; return
        }
        if case .customEqualizer(let bands) = action, !SamsungBudsCustomEqualizer.valid(bands) {
            error = "Informe exatamente nove ganhos inteiros entre −10 e +10."; return
        }
        switch action {
        case .find: toolKind = .find
        case .fitTest: toolKind = .fit; fitResult = nil; fitDate = nil
        default: toolKind = nil
        }
        switch action {
        case .customEqualizerRead, .customEqualizer, .info: deviceRequestActive = true
        default: deviceRequestActive = false
        }
        if toolKind != nil, !environment.toolsPermission() {
            toolKind = nil; error = "Aguarde a alternância terminar e encerre a chamada para usar esta ferramenta."; return
        }
        findStopped = false; findStopRequested = false; pendingFitResult = nil; pendingFitDate = nil; muteMatched = false
        generation &+= 1
        let token = generation
        busy = true; error = nil; status = "Confirmando conexão e lendo ajustes…"
        parked = false; physicalModelVerified = false; settingsObservedDate = nil; settingsObservedAt = nil
        clearSettings()
        let sleep = environment.sleep
        // Includes connection checks, both opens, state and ACK waits. Even a
        // noncooperative effect cannot keep the model busy or authorize late work.
        deadline = Task { [weak self] in
            do { try await sleep(self?.toolKind == .find ? NativeBudsToolsPacket.findDuration + 30 : 30) } catch { return }
            self?.abort(token, message: "Tempo limite dos ajustes. A operação não foi confirmada; atualize antes de tentar novamente.")
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // Pace the next transaction before opening its SDK session.
                // Waiting only immediately before write was still rejected by
                // the device. The passing lab sequence waited before reopening;
                // no settings channel is held during this wait.
                if case .noise = action, let last = self.lastNoiseConfirmation {
                    let remaining = last + 1.5 - self.environment.now()
                    if remaining > 0 {
                        self.status = "Aguardando a mudança anterior do controle de ruído…"
                        try await self.environment.sleep(min(remaining, 1.5))
                        try self.check(token)
                    }
                }
                guard try await self.checkLink(token, selected: selected) else {
                    self.finish(token, status: "Buds desconectados do Mac. Conecte pelo Bluetooth e atualize os ajustes.")
                    return
                }
                let readSession = self.beginSession(token, phase: .reading)
                try await self.environment.open(selected.address)
                try self.check(token, session: readSession)
                try await self.wait(token, session: readSession)
                try self.check(token, session: readSession)
                guard let observed = self.readStatus, let observedAt = self.readObservedAt,
                      let observedDate = self.readObservedDate else {
                    throw NativeBudsError(message: "Sem leitura válida dos ajustes.")
                }
                self.apply(observed, selected: selected, at: observedAt, date: observedDate)
                self.closeSession()
                if action != .refresh {
                    // Reject unrepresentable touch controls before opening for a write.
                    _ = try self.command(action, observed: observed)
                    guard try await self.checkLink(token, selected: selected) else {
                        throw NativeBudsError(message: "Buds desconectados antes da alteração. Nenhum ajuste foi confirmado.")
                    }
                    let commandSession = self.beginSession(token, phase: .openingCommand)
                    try await self.environment.open(selected.address)
                    try self.check(token, session: commandSession)
                    // Prefer a newer bootstrap state from this command session.
                    // Never use an old read to overwrite individual touch flags
                    // after a slow connection/open, even if the link is still up.
                    let current = self.readStatus ?? observed
                    let currentAt = self.readObservedAt ?? observedAt
                    // Absolute noise/EQ commands carry their full value. Touch
                    // rewrites gesture fields, so it always needs a recent real
                    // observation even on a retained stream (Claude review Q3).
                    let absolute: Bool
                    switch action {
                    case .touch, .mediaControls, .gesture, .find, .fitTest,
                         .customEqualizerRead, .customEqualizer, .info: absolute = false
                    default: absolute = true
                    }
                    guard self.environment.now() >= currentAt,
                          (self.environment.now() - currentAt <= (self.toolKind == nil ? 15 : 5)
                            || (absolute && self.environment.continuousStatus())) else {
                        throw NativeBudsError(message: "Leitura antiga demais para alterar os ajustes com segurança. Atualize e tente novamente.")
                    }
                    if self.readStatus != nil {
                        self.apply(current, selected: selected, at: currentAt, date: self.readObservedDate ?? observedDate)
                    }
                    let command = try self.command(action, observed: current)
                    if self.toolKind != nil {
                        try await self.runTool(action, token: token, session: commandSession)
                        return
                    }
                    switch action {
                    case .customEqualizerRead, .customEqualizer, .info:
                        try await self.runDeviceRequest(action, token: token, session: commandSession, selected: selected)
                        return
                    default: break
                    }
                    self.expectedCommand = command.0; self.expectedPayload = command.1
                    self.phase = .command
                    // A transmitted command may outlive UI cancellation. Keep
                    // only the preceding actual reading, marked as historical.
                    self.lastObservation?.mayHaveChanged = true
                    self.writeID = try self.environment.send(Packet.frame(command: command.0, payload: command.1))
                    try await self.wait(token, session: commandSession)
                    try self.check(token, session: commandSession)
                    guard self.evidenceReady else {
                        throw NativeBudsError(message: "Estado de ruído divergente da confirmação; atualize para verificar o estado real.")
                    }
                    self.applyConfirmed(action)
                }
                self.finish(token, status: self.confirmedStatus)
            } catch is CancellationError {
                // Cancellation/selection change already invalidated this token.
                if self.active(token) { self.abort(token, message: "Atualização cancelada; ajustes não confirmados.") }
            } catch {
                guard self.active(token) else { return }
                let message = (error as? NativeBudsError)?.message ?? "Não foi possível confirmar os ajustes. Atualize e tente novamente."
                self.abort(token, message: message)
            }
        }
    }

    /// Closes only the model's own transport. No baseband, A2DP or other owner.
    func cancel() { cancel(resetConnection: true) }

    /// Suspend commands during a handoff while retaining this app's observed
    /// SppNew stream. A full peer/address change or app shutdown still resets it.
    func suspend() { cancel(resetConnection: false) }

    /// Physical loss invalidates settings history and the owned session. Actual
    /// same-device charge retains its receive date for historical presentation.
    /// Panel close, temporary blocking and read errors use cancel/suspend and
    /// retain only the dated observation, never write permission.
    func invalidateConnection() {
        cancel()
        lastObservation = nil
        clearDeviceReadings()
    }

    private func cancel(resetConnection: Bool) {
        let wasTool = toolKind != nil
        generation &+= 1
        operation?.cancel(); operation = nil
        deadline?.cancel(); deadline = nil
        closeSession()
        if resetConnection || wasTool { environment.reset() }
        toolKind = nil; pendingFitResult = nil
        deviceRequestActive = false
        busy = false
        parked = false
        physicalModelVerified = false; settingsObservedDate = nil; settingsObservedAt = nil
        clearSettings(); link = nil; linkObservedAt = nil
        error = nil; status = "Atualização cancelada. Atualize para obter uma nova leitura."
    }

    private func active(_ token: UInt64) -> Bool { busy && token == generation }
    private func check(_ token: UInt64, session: UUID? = nil) throws {
        try Task.checkCancellation()
        guard active(token), session == nil || self.session == session else { throw CancellationError() }
        if toolKind != nil && !environment.toolsPermission() {
            throw NativeBudsError(message: "A ferramenta foi interrompida porque a saída ou a chamada mudou.")
        }
    }
    private func checkLink(_ token: UInt64, selected: Selection) async throws -> Bool {
        let connected = try await environment.connected(selected.address)
        try check(token)
        guard selection?.address == selected.address, selection?.inspectable == true, !blocked else { throw CancellationError() }
        link = connected; linkObservedAt = environment.now()
        if !connected { lastObservation = nil; clearDeviceReadings() }
        return connected
    }
    private func beginSession(_ token: UInt64, phase: Phase) -> UUID {
        closeSession()
        let id = UUID(); session = id; self.phase = phase
        readStatus = nil; readObservedAt = nil; readObservedDate = nil
        expectedCommand = nil; expectedPayload = []
        writeID = nil; writeCompleted = false; echoMatched = false; unverifiedEcho = false
        noiseFeedback = nil
        resetDeviceRequest()
        environment.handlers({ [weak self] in self?.received($0, token: token, session: id) },
            { [weak self] in self?.written($0, token: token, session: id) },
            { [weak self] failure in
                guard let self, self.active(token), self.session == id else { return }
                self.abort(token, message: failure.message)
            })
        return id
    }
    private func closeSession() {
        session = nil; phase = .idle
        responseDeadline?.cancel(); responseDeadline = nil
        waitIdentity = nil
        resetDeviceRequest()
        let pending = waiter; waiter = nil
        environment.handlers(nil, nil, nil); environment.close()
        pending?.resume(throwing: CancellationError())
    }
    private var evidenceReady: Bool {
        switch phase {
        case .reading: return readStatus != nil
        case .customWrite: return writeID != nil && writeCompleted
        case .customRead: return writeID != nil && writeCompleted && pendingCurve != nil
        case .firmwareRead: return writeID != nil && writeCompleted && pendingVersion != nil
        case .command:
            if toolKind != nil {
                guard writeID != nil, writeCompleted else { return false }
                switch toolWait {
                case .write: return true
                case .mute: return muteMatched || findStopped
                case .searching: return findStopped || findStopRequested
                case .fitResult: return pendingFitResult != nil
                }
            }
            let feedbackAgrees = noiseFeedback.map { expectedCommand != 0x78 || expectedPayload == [$0.rawValue] } ?? true
            return writeID != nil && writeCompleted && echoMatched && feedbackAgrees
        default: return false
        }
    }
    private func wait(_ token: UInt64, session: UUID, timeout: TimeInterval = 5, failure: String? = nil,
                      stopSearchAtTimeout: Bool = false) async throws {
        try check(token, session: session)
        if evidenceReady { return }
        let sleep = environment.sleep
        let identity = UUID(); waitIdentity = identity
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            waiter = pending
            responseDeadline = Task { [weak self] in
                do { try await sleep(timeout); try Task.checkCancellation() } catch { return }
                guard let self, self.active(token), self.session == session, self.waitIdentity == identity else { return }
                if stopSearchAtTimeout, self.toolKind == .find, case .searching = self.toolWait {
                    self.findStopRequested = true; self.resumeIfReady(); return
                }
                let message = failure ?? (self.phase == .reading
                    ? "Os Buds não forneceram um estado completo válido em cinco segundos."
                    : (self.unverifiedEcho ? "Resposta divergente ou não verificável; a alteração não foi confirmada."
                        : "Sem confirmação do comando e da transmissão em cinco segundos. Atualize para verificar o estado real."))
                self.abort(token, message: message)
            }
        }
    }
    private func resumeIfReady() {
        guard evidenceReady else { return }
        responseDeadline?.cancel(); responseDeadline = nil
        waitIdentity = nil
        let pending = waiter; waiter = nil; pending?.resume()
    }
    private func received(_ frame: Packet.Frame, token: UInt64, session: UUID) {
        guard active(token), self.session == session, !frame.isFragment else { return }
        if deviceRequestActive {
            // The helper delivers its verified bootstrap before open() returns
            // and before sessionAlive becomes true. Only a submitted device
            // request requires an already-open session; bootstrap still checks
            // physical identity below and the caller verifies open completion.
            if phase != .reading && phase != .openingCommand && environment.sessionAlive() == false {
                abort(token, message: "Canal encerrado antes de confirmar a leitura do dispositivo."); return
            }
            if frame.command == 0x61 {
                guard let observed = Packet.status(frame, model: "Buds3Pro"), observed.physicalModelVerified else {
                    abort(token, message: "Modelo físico divergente ou não verificável durante a operação."); return
                }
                // Complete status is identity evidence, never a substitute for
                // the requested custom/firmware reply or the final echo ACK.
                if phase != .reading && phase != .openingCommand {
                    let stamp = environment.statusTimestamp()
                    if let selected = selection {
                        apply(observed, selected: selected, at: stamp?.0 ?? environment.now(), date: stamp?.1 ?? environment.date())
                    }
                    return
                }
            }
        }
        if phase == .reading || phase == .openingCommand {
            if let observed = Packet.status(frame, model: selection?.model ?? (Packet.physicalBuds3Pro(frame) == true ? "Buds3Pro" : "")) {
                let stamp = environment.statusTimestamp()
                readStatus = observed; readObservedAt = stamp?.0 ?? environment.now(); readObservedDate = stamp?.1 ?? environment.date()
                resumeIfReady()
            }
            // Noise-only updates cannot masquerade as a complete settings read.
            return
        }
        if phase == .customRead || phase == .firmwareRead {
            guard let started = requestStartedAt, environment.now().isFinite, environment.now() >= started,
                  environment.date().timeIntervalSince1970.isFinite, environment.date().timeIntervalSince1970 >= 0 else { return }
            if phase == .customRead, let curve = SamsungBudsCustomEqualizer.curve(frame) {
                // Conflicting replies within one exchange cannot pick whichever
                // curve happens to agree with a requested write.
                if let previous = pendingCurve, previous != curve {
                    abort(token, message: "Leituras de equalizador divergentes na mesma solicitação."); return
                }
                if pendingCurve == nil { pendingCurve = curve; pendingReplyDate = environment.date() }
            } else if phase == .firmwareRead, let version = SamsungBudsFirmwareVersion.version(frame) {
                if let previous = pendingVersion, previous != version {
                    abort(token, message: "Versões de firmware divergentes na mesma solicitação."); return
                }
                if pendingVersion == nil { pendingVersion = version; pendingReplyDate = environment.date() }
            }
            resumeIfReady(); return
        }
        guard phase == .command, let command = expectedCommand else { return }
        if toolKind != nil {
            if (frame.command == 0x60 || frame.command == 0x61), NativeBudsToolsPacket.placements(frame) == nil {
                abort(token, message: "Não foi possível confirmar a posição dos fones. Ferramenta interrompida."); return
            }
            if let placement = NativeBudsToolsPacket.placements(frame),
               (toolKind == .find && (placement.0 != .idle || placement.1 != .idle))
                || (toolKind == .fit && (placement.0 != .wearing || placement.1 != .wearing)) {
                abort(token, message: "A posição dos fones mudou. A ferramenta foi interrompida."); return
            }
            if command == 0xA2, NativeBudsToolsPacket.muteConfirmed(frame, parameters: expectedPayload) { muteMatched = true }
            if NativeBudsToolsPacket.stopped(frame) { findStopped = true }
            if command == 0x9D, expectedPayload == [1], let value = NativeBudsToolsPacket.fitResult(frame) {
                pendingFitResult = value; pendingFitDate = environment.date()
            }
            resumeIfReady(); return
        }
        if frame.command == 0x42 {
            if Packet.acknowledges(frame, command: command, payload: expectedPayload)
                || (customSelectionArmed && command == SamsungBudsCustomEqualizer.selectionCommand
                    && expectedPayload == [SamsungBudsCustomEqualizer.customSelection]
                    && SamsungBudsCustomEqualizer.acknowledgesSelection(frame)) { echoMatched = true }
            else if frame.payload.first == command { unverifiedEcho = true }
        } else if let mode = Packet.noiseUpdate(frame), command == 0x78 {
            noiseFeedback = mode
            if expectedPayload != [mode.rawValue] { unverifiedEcho = true }
        }
        // Neither a status notification nor a 0x77 update replaces the echo ACK.
        resumeIfReady()
    }
    private func written(_ id: UInt, token: UInt64, session: UUID) {
        guard active(token), self.session == session,
              phase == .command || phase == .customWrite || phase == .customRead || phase == .firmwareRead,
              id == writeID else { return }
        writeCompleted = true; resumeIfReady()
    }

    private func resetDeviceRequest() {
        pendingCurve = nil; pendingVersion = nil; pendingReplyDate = nil
        requestStartedAt = nil; customSelectionArmed = false
    }
    private func clearDeviceReadings() {
        customBands = nil; customObservedDate = nil
        firmwareVersion = nil; firmwareObservedDate = nil
    }
    private var deviceStatusFresh: Bool {
        guard physicalModelVerified, let at = settingsObservedAt, let date = settingsObservedDate else { return false }
        let now = environment.now(), wallNow = environment.date().timeIntervalSince1970
        let wallDate = date.timeIntervalSince1970
        return at.isFinite && at >= 0 && now.isFinite && now >= at && now - at <= 15
            && wallDate.isFinite && wallDate >= 0 && wallNow.isFinite && wallNow >= wallDate && wallNow - wallDate <= 15
    }
    private func checkDeviceRequest(_ token: UInt64, session: UUID, selected: Selection) throws {
        try check(token, session: session)
        guard selection?.address == selected.address, selection?.connectionEpoch == selected.connectionEpoch,
              selection?.inspectable == true, !blocked, environment.sessionAlive() != false,
              deviceStatusFresh,
              requestStartedAt.map({ environment.now() >= $0 && environment.now() - $0 <= 5 }) ?? true else {
            throw NativeBudsError(message: "Leitura física antiga, canal encerrado ou seleção alterada. Atualize antes de tentar novamente.")
        }
    }
    private func requestDevice(_ phase: Phase, command: UInt8, payload: [UInt8],
                               token: UInt64, session: UUID, selected: Selection) async throws {
        try checkDeviceRequest(token, session: session, selected: selected)
        resetDeviceRequest()
        self.phase = phase; expectedCommand = command; expectedPayload = payload
        writeID = nil; writeCompleted = false; echoMatched = false; unverifiedEcho = false
        requestStartedAt = environment.now()
        writeID = try environment.send(Packet.frame(command: command, payload: payload))
        try await wait(token, session: session,
            failure: "Sem resposta válida e conclusão da transmissão. A operação não foi confirmada.")
        try checkDeviceRequest(token, session: session, selected: selected)
    }
    private func publishCurve() throws -> [Int] {
        guard let curve = pendingCurve, let date = pendingReplyDate, writeID != nil, writeCompleted else {
            throw NativeBudsError(message: "Sem leitura real e confirmada da curva personalizada.")
        }
        customBands = curve.bands; customObservedDate = date
        return curve.bands
    }
    private func runDeviceRequest(_ action: Action, token: UInt64, session: UUID, selected: Selection) async throws {
        try checkDeviceRequest(token, session: session, selected: selected)
        switch action {
        case .customEqualizerRead:
            status = "Lendo a curva personalizada dos Buds…"
            try await requestDevice(.customRead, command: SamsungBudsCustomEqualizer.readCommand, payload: [],
                token: token, session: session, selected: selected)
            _ = try publishCurve()
            finish(token, status: "Curva personalizada lida dos Buds.")
        case .info:
            status = "Lendo a versão de firmware dos Buds…"
            try await requestDevice(.firmwareRead, command: SamsungBudsFirmwareVersion.command, payload: [],
                token: token, session: session, selected: selected)
            guard let version = pendingVersion, let date = pendingReplyDate else {
                throw NativeBudsError(message: "Sem resposta válida da versão de firmware.")
            }
            firmwareVersion = version; firmwareObservedDate = date
            finish(token, status: "Versão de firmware lida dos Buds.")
        case .customEqualizer(let bands):
            guard let payload = SamsungBudsCustomEqualizer.writePayload(bands) else {
                throw NativeBudsError(message: "Curva personalizada inválida.")
            }
            status = "Enviando e verificando a curva personalizada…"
            // A transmitted curve can invalidate the previous curve even if
            // cancellation prevents its readback. Do not retain it as current.
            customBands = nil; customObservedDate = nil
            lastObservation?.mayHaveChanged = true
            try await requestDevice(.customWrite, command: SamsungBudsCustomEqualizer.writeCommand, payload: payload,
                token: token, session: session, selected: selected)
            try await requestDevice(.customRead, command: SamsungBudsCustomEqualizer.readCommand, payload: [],
                token: token, session: session, selected: selected)
            guard try publishCurve() == bands else {
                throw NativeBudsError(message: "A curva lida dos Buds diverge da solicitada. O preset personalizado não foi selecionado.")
            }
            try checkDeviceRequest(token, session: session, selected: selected)
            // Reuse the settings command/echo path; allow only the one custom
            // wire value, armed by this exchange's actual matching readback.
            phase = .command; customSelectionArmed = true
            expectedCommand = SamsungBudsCustomEqualizer.selectionCommand
            expectedPayload = [SamsungBudsCustomEqualizer.customSelection]
            writeID = nil; writeCompleted = false; echoMatched = false; unverifiedEcho = false
            requestStartedAt = environment.now()
            writeID = try environment.send(SamsungBudsCustomEqualizer.selectionRequest)
            try await wait(token, session: session)
            try checkDeviceRequest(token, session: session, selected: selected)
            guard evidenceReady else { throw NativeBudsError(message: "Preset personalizado sem confirmação verificável.") }
            applyConfirmed(action)
            finish(token, status: "Curva personalizada verificada por leitura e seleção confirmada pelos Buds.")
        default: throw NativeBudsError(message: "Solicitação de dispositivo inválida.")
        }
    }
    private func sendTool(_ command: UInt8, _ payload: [UInt8], waitingFor evidence: ToolWait,
                          token: UInt64, session: UUID, timeout: TimeInterval = 5,
                          failure: String) async throws {
        try check(token, session: session)
        phase = .command; toolWait = evidence
        expectedCommand = command; expectedPayload = payload
        writeID = nil; writeCompleted = false; muteMatched = false
        writeID = try environment.send(Packet.frame(command: command, payload: payload))
        try await wait(token, session: session, timeout: timeout, failure: failure)
        try check(token, session: session)
    }
    private func runTool(_ action: Action, token: UInt64, session: UUID) async throws {
        switch action {
        case .find(let target):
            findStopped = false
            let started = environment.now()
            try await sendTool(0xA6, [], waitingFor: .write, token: token, session: session,
                failure: "A transmissão da busca não foi confirmada. Parada solicitada.")
            status = "Procurando os Buds…"
            // Samsung starts the search before applying per-side mute. A
            // pre-start mute is not evidence that A6 will preserve that side.
            if target != .both && !findStopped {
                try await sendTool(0xA2, target.mute, waitingFor: .mute(target.mute), token: token, session: session,
                    failure: "Não foi possível confirmar o lado da busca. Parada solicitada.")
            }
            let remaining = started + NativeBudsToolsPacket.findDuration - environment.now()
            self.toolWait = .searching
            if remaining > 0 && !findStopped {
                try await wait(token, session: session, timeout: remaining, stopSearchAtTimeout: true)
            }
            try check(token, session: session)
            // Both original apps send A1 without requiring an A1 notification
            // in return. Only a received event may claim a device-side stop.
            try await sendTool(0xA1, [], waitingFor: .write, token: token, session: session,
                failure: "Não foi possível transmitir a parada da busca. Verifique os fones.")
            finish(token, status: findStopped ? "Busca encerrada pelos Buds." : "Parada da busca enviada.")
        case .fitTest:
            status = "Medindo a vedação. Mantenha os dois fones nos ouvidos…"
            try await sendTool(0x9D, [1], waitingFor: .fitResult, token: token, session: session, timeout: 8,
                failure: "Os Buds não enviaram o resultado da vedação em oito segundos. Teste cancelado; tente novamente.")
            guard let result = pendingFitResult, let date = pendingFitDate else { throw CancellationError() }
            try await sendTool(0x9D, [0], waitingFor: .write, token: token, session: session,
                failure: "Resultado recebido, mas a transmissão de encerramento não foi confirmada.")
            fitResult = result; fitDate = date
            finish(token, status: "Teste de vedação concluído. Confira o resultado de cada lado.")
        default: throw NativeBudsError(message: "Ferramenta inválida.")
        }
    }
    private func command(_ action: Action, observed: Packet.Status) throws -> (UInt8, [UInt8]) {
        guard observed.physicalModelVerified else {
            throw NativeBudsError(message: "Modelo físico não confirmado pelo estado dos Buds. Nenhuma alteração foi enviada.")
        }
        switch action {
        case .noise(let mode): return (0x78, [mode.rawValue])
        case .equalizer(let preset): return (0x86, [UInt8(preset + 1)])
        case .customEqualizerRead: return (SamsungBudsCustomEqualizer.readCommand, [])
        case .customEqualizer(let bands):
            guard let payload = SamsungBudsCustomEqualizer.writePayload(bands) else {
                throw NativeBudsError(message: "Curva personalizada inválida.")
            }
            return (SamsungBudsCustomEqualizer.writeCommand, payload)
        case .info: return (SamsungBudsFirmwareVersion.command, [])
        case .touch(let enabled):
            guard let controls = observed.touchControls else {
                throw NativeBudsError(message: "Alteração de toque desativada: não é possível preservar todos os controles observados.")
            }
            return (0x90, controls.payload(enabled: enabled))
        case .mediaControls(let enabled):
            guard let controls = observed.touchControls else {
                throw NativeBudsError(message: "Não é possível preservar todos os controles de gestos observados.")
            }
            return (0x90, controls.mediaPayload(enabled: enabled))
        case .gesture(let gesture, let enabled):
            guard let controls = observed.touchControls else {
                throw NativeBudsError(message: "Atualize a leitura para preservar os outros gestos dos Buds.")
            }
            return (0x90, controls.payload(changing: gesture, enabled: enabled))
        case .find:
            guard observed.bothOutside else { throw NativeBudsError(message: "Retire os dois fones dos ouvidos antes de iniciar a busca sonora.") }
            return (0xA6, [])
        case .fitTest:
            guard observed.wearingBoth else { throw NativeBudsError(message: "Coloque os dois fones nos ouvidos para testar a vedação.") }
            return (0x9D, [1])
        case .setting(let setting, let value):
            guard observed.settings[setting] != nil, let wire = setting.wireValue(value) else {
                throw NativeBudsError(message: "Este ajuste não foi identificado no estado atual dos Buds.")
            }
            return (setting.command, [wire])
        case .refresh: throw NativeBudsError(message: "Atualização não é um comando de escrita.")
        }
    }
    private func apply(_ observed: Packet.Status, selected: Selection, at: TimeInterval, date: Date) {
        physicalModelVerified = observed.physicalModelVerified; settingsObservedDate = date; settingsObservedAt = at
        noise = observed.noise; equalizer = observed.equalizer; rawEqualizer = observed.rawEqualizer
        ambientLevel = observed.ambientLevel; touchEnabled = observed.touchEnabled; preservedTouch = observed.touchControls
        leftPlacement = observed.leftPlacement; rightPlacement = observed.rightPlacement
        mediaControlsEnabled = observed.touchControls?.mediaEnabled
        mediaControlsMixed = observed.touchControls != nil && mediaControlsEnabled == nil
        settings = observed.settings
        batterySnapshot = BudsBatterySnapshot(address: selected.address, name: selected.name,
            model: "Buds3Pro", icon: nil, left: observed.left, right: observed.right,
            casePercent: observed.casePercent, observedAt: date.timeIntervalSince1970)
        // A replayed bootstrap is not a newly observed success. It must not
        // replenish the host's bounded read-retry budget or refresh its date.
        if observed.physicalModelVerified, at.isFinite, at >= 0, at <= environment.now(),
           date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
           lastObservation.map({ at > $0.at }) ?? true {
            observationRevision &+= 1
            lastObservation = Observation(status: observed, at: at, date: date, mayHaveChanged: false)
        }
    }
    private var lastObservationFields: [String: Any] {
        guard let observation = lastObservation else { return [:] }
        let state = observation.status
        return ["model_verified": true, "observed_at": observation.date.timeIntervalSince1970,
            "settings_may_have_changed": observation.mayHaveChanged,
            "noise_mode": state.noise.map { $0.name as Any } ?? NSNull(),
            "equalizer": state.equalizer.map { $0 as Any } ?? NSNull(),
            "equalizer_raw": state.rawEqualizer,
            "equalizer_enabled": state.rawEqualizer != 0,
            "equalizer_custom": state.rawEqualizer == SamsungBudsCustomEqualizer.customSelection,
            "ambient_level": state.ambientLevel,
            "touch_enabled": state.touchEnabled,
            "media_controls_enabled": state.touchControls?.mediaEnabled.map { $0 as Any } ?? NSNull(),
            "media_controls_mixed": state.touchControls != nil && state.touchControls?.mediaEnabled == nil,
            "touch_controls": state.touchControls?.fields ?? [:],
            "settings": Dictionary(uniqueKeysWithValues: state.settings.map { key, value in
                (key.rawValue, key.isBoolean ? (value == 1) as Any : value as Any)
            })]
    }
    private func applyConfirmed(_ action: Action) {
        switch action {
        case .noise(let mode): noise = mode; lastNoiseConfirmation = environment.now()
        case .equalizer(let preset): equalizer = preset; rawEqualizer = UInt8(preset + 1)
        case .customEqualizer: equalizer = nil; rawEqualizer = SamsungBudsCustomEqualizer.customSelection
        case .touch(let enabled):
            touchEnabled = enabled
            if let controls = preservedTouch { preservedTouch = controls.replacing(with: controls.payload(enabled: enabled)) }
        case .mediaControls(let enabled):
            if let controls = preservedTouch { preservedTouch = controls.replacing(with: controls.mediaPayload(enabled: enabled)) }
            mediaControlsEnabled = enabled; mediaControlsMixed = false
        case .gesture(let gesture, let enabled):
            if let controls = preservedTouch {
                preservedTouch = controls.replacing(with: controls.payload(changing: gesture, enabled: enabled))
                mediaControlsEnabled = preservedTouch?.mediaEnabled
                mediaControlsMixed = preservedTouch != nil && mediaControlsEnabled == nil
            }
        case .setting(let setting, let value): settings[setting] = value
        case .refresh, .find, .fitTest, .customEqualizerRead, .info: break
        }
    }
    private var confirmedStatus: String {
        var parts = ["Ajustes observados no canal Samsung."]
        if rawEqualizer == 0 { parts.append("Equalizador desligado (som normal).") }
        else if rawEqualizer == SamsungBudsCustomEqualizer.customSelection { parts.append("Equalizador personalizado ativo.") }
        else if let rawEqualizer, rawEqualizer > 7 { parts.append("Predefinição de equalizador não suportada; sem seleção.") }
        if noise == nil { parts.append("Modo de ruído desconhecido.") }
        if preservedTouch == nil { parts.append("Alteração de toque desativada: controles adicionais não verificáveis.") }
        return parts.joined(separator: " ")
    }
    private func clearSettings() {
        noise = nil; equalizer = nil; rawEqualizer = nil; ambientLevel = nil; touchEnabled = nil; preservedTouch = nil
        mediaControlsEnabled = nil; mediaControlsMixed = false; settings = [:]
        leftPlacement = nil; rightPlacement = nil
    }
    private func finish(_ token: UInt64, status: String) {
        guard active(token) else { return }
        let wasTool = toolKind != nil
        closeSession(); deadline?.cancel(); deadline = nil; operation = nil
        if releaseAfterTransaction || wasTool {
            parked = physicalModelVerified && link == true
            environment.reset()
        }
        toolKind = nil; pendingFitResult = nil
        deviceRequestActive = false
        busy = false; self.status = status
    }
    private func abort(_ token: UInt64, message: String) {
        guard active(token) else { return }
        cancel()
        status = "Ajustes não confirmados. Atualize para ler o estado real."
        error = message
    }
}
