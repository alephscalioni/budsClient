import Foundation
import Darwin

/// SppNew owns a separate SDK process from SMEP. The parent still owns model,
/// permissions, command/ACK matching, timestamps and the shared operation drain.
@MainActor final class NativeBudsSettingsProcess {
    var onSettingsFrame: ((SamsungBudsSettingsPacket.Frame) -> Void)?
    var onWriteComplete: ((UInt) -> Void)?
    var onFailure: ((NativeBudsError) -> Void)?
    private let helper: URL?
    private let drain: NativeBudsOperationDrain
    private var current: Session?
    private var selectedModel: String?
    func configureModel(_ model: String?) {
        guard selectedModel != model else { return }
        close(); selectedModel = model
    }
    private var retired: [UUID: Session] = [:]
    private var generation: UInt64 = 0
    private var nextWrite: UInt = 0
    private(set) var observationStamp: (TimeInterval, Date)?
    private var frames = 0, bytes = 0, sent = 0, written = 0
    private var events: [[String: Any]] = []
    init(helper: URL? = nil, drain: NativeBudsOperationDrain? = nil) {
        self.helper = helper; self.drain = drain ?? .shared
    }
    deinit {
        let sessions = Array(retired.values) + (current.map { [$0] } ?? [])
        Task { @MainActor in for session in sessions { session.close() } }
    }
    var isOpen: Bool { current?.opened == true && current?.closing == false }
    var diagnostics: [String: Any] {
        ["isolated_spp_new": true, "phase": isOpen ? "open" : (current == nil ? "idle" : "opening"),
         "received_frames": frames, "received_bytes": bytes, "sent_packets": sent,
         "transmitted_packets": written, "pending_writes": current?.writes.count ?? 0,
         "pending_operations": drain.count, "events": events]
    }
    private func record(_ event: String, _ extra: [String: Any] = [:]) {
        var value = extra; value["event"] = event; value["uptime"] = ProcessInfo.processInfo.systemUptime
        events.append(value); if events.count > 16 { events.removeFirst() }
    }
    func open(address: String) async throws {
        if isOpen, current?.address == address { return }
        close()
        let token = generation
        // Await only our retired children. Other owners' unfinished SDK work
        // remains a refusal, never permission to overlap or retry it.
        for session in Array(retired.values) { await session.waitForExit() }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard drain.count == 0 else { throw NativeBudsError(message: "O Bluetooth ainda está concluindo a tentativa anterior.") }
        guard let helper = helper ?? Bundle.main.url(forAuxiliaryExecutable: "BudsGuardHelper") else {
            throw NativeBudsError(message: "O serviço de ajustes não está incluído nesta instalação.")
        }
        frames = 0; bytes = 0; sent = 0; written = 0; events.removeAll(); observationStamp = nil
        let session = Session(address: address, model: selectedModel, owner: self, drain: drain)
        current = session
        do { try await session.open(helper: helper) }
        catch { if current === session { close() }; throw error }
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard current === session, isOpen else {
            throw NativeBudsError(message: session.failure ?? "O serviço de ajustes encerrou durante a abertura.")
        }
        session.accepted = true
    }
    func sendTracked(_ packet: Data) throws -> UInt {
        guard isOpen, let current, current.writes.isEmpty, NativeBudsSettingsWire.permittedWrite(packet), nextWrite < NativeBudsSettingsWire.maximumID else {
            throw NativeBudsError(message: "Comando sem canal de ajustes disponível ou não permitido.")
        }
        nextWrite += 1
        current.writes.insert(nextWrite)
        if let frame = SamsungBudsSettingsPacket.decodeCompleteFrame(packet),
           (frame.command == 0xA6 || frame.command == 0xA0) || (frame.command == 0x9D && Array(frame.payload) == [1]) {
            current.requiresSafetyStop = true
        }
        do { try current.send(["event": "write", "id": nextWrite, "packet": packet.base64EncodedString()]) }
        catch { current.writes.remove(nextWrite); throw error }
        sent += 1; record("tx_queued", ["command": Int(packet[packet.startIndex + 3]), "length": packet.count])
        return nextWrite
    }
    func close() {
        generation &+= 1
        guard let session = current else { return }
        current = nil; retired[session.id] = session
        session.close()
    }
    private func receive(_ value: [String: Any], from session: Session) {
        guard current === session, !session.closing else { return }
        guard let event = value["event"] as? String else { session.fail("Resposta inválida do serviço de ajustes."); return }
        switch event {
        case "opened":
            guard !session.opened else { session.fail("Abertura duplicada do serviço de ajustes."); return }
            session.didOpen(); record("settings_helper_opened")
        case "frame":
            guard let frame = NativeBudsSettingsWire.frame(value),
                  let uptime = NativeBudsSettingsWire.number(value["uptime"]),
                  uptime >= (session.lastFrameAt ?? session.startedAt), uptime <= ProcessInfo.processInfo.systemUptime,
                  let date = NativeBudsSettingsWire.number(value["observed_at"]),
                  date >= session.startedDate - 0.1, date <= Date().timeIntervalSince1970 + 0.1 else {
                session.fail("Estado inválido recebido do serviço de ajustes."); return
            }
            session.lastFrameAt = uptime
            observationStamp = (uptime, Date(timeIntervalSince1970: date))
            frames += 1; bytes += frame.payload.count + 7
            record("rx_frame", ["command": Int(frame.command), "payload_length": frame.payload.count])
            onSettingsFrame?(frame)
        case "written":
            guard let id = NativeBudsSettingsWire.integer(value["id"]), session.writes.remove(id) != nil else {
                session.fail("Confirmação de transmissão fora da sessão atual."); return
            }
            written += 1; onWriteComplete?(id)
        case "error": session.fail(String((value["message"] as? String ?? "Falha no serviço de ajustes.").prefix(512)))
        default: session.fail("Evento de serviço de ajustes inválido.")
        }
    }
    private func ended(_ session: Session) {
        retired.removeValue(forKey: session.id)
        guard current === session else { return }
        current = nil
        if session.accepted { onFailure?(NativeBudsError(message: session.failure ?? "O serviço de ajustes foi encerrado.")) }
    }
    private func failed(_ session: Session, message: String) {
        guard current === session else { session.close(); return }
        current = nil; retired[session.id] = session
        session.close()
        if session.accepted { onFailure?(NativeBudsError(message: message)) }
    }

    @MainActor private final class Session {
        let id = UUID(), address: String, startedAt = ProcessInfo.processInfo.systemUptime
        let startedDate = Date().timeIntervalSince1970
        var lastFrameAt: TimeInterval?
        weak var owner: NativeBudsSettingsProcess?
        let process = Process(), output = Pipe(), input = Pipe()
        let drain: NativeBudsOperationDrain
        let model: String?
        var writes: Set<UInt> = []
        var opened = false, closing = false, exited = false
        var accepted = false
        var requiresSafetyStop = false
        var failure: String?
        private var lease: UUID?
        private var waiter: CheckedContinuation<Void, Error>?
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []
        private var reader: NativeBudsSettingsPipe?
        private var deadline: Task<Void, Never>?
        private var termination: Task<Void, Never>?
        init(address: String, model: String?, owner: NativeBudsSettingsProcess, drain: NativeBudsOperationDrain) {
            self.address = address; self.model = model; self.owner = owner; self.drain = drain
        }
        private func retainLease() {
            guard lease == nil else { return }
            let id = UUID(); lease = id; drain.retain(self, id: id, orphanCleanup: {})
        }
        private func releaseLease() {
            if let lease { drain.complete(lease, orphaned: false); self.lease = nil }
        }
        func open(helper: URL) async throws {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waiter = continuation; retainLease()
                    process.executableURL = helper
                    process.arguments = [NativeBudsSettingsWire.flag, "--address", address, "--owner-pid", String(getpid())]
                        + (model.map { ["--model", $0] } ?? [])
                    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    // A child exiting between the check and write must throw,
                    // never deliver SIGPIPE to the app hosting the audio panel.
                    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    let reader = NativeBudsSettingsPipe { [weak self] batch in
                        guard let self, !self.closing else { return }
                        guard let batch else { self.fail("O serviço de ajustes encerrou a comunicação."); return }
                        for value in batch {
                            guard !self.closing else { break }
                            self.owner?.receive(value, from: self)
                        }
                    }
                    self.reader = reader
                    output.fileHandleForReading.readabilityHandler = { handle in reader.append(handle.availableData) }
                    process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.didExit() } }
                    do { try process.run() }
                    catch { failure = error.localizedDescription; didExit(); return }
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(12)) } catch { return }
                        self?.fail("A abertura do serviço de ajustes excedeu o prazo.")
                    }
                }
            } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        }
        func didOpen() {
            guard !closing else { return }
            opened = true; releaseLease(); deadline?.cancel(); deadline = nil
            let waiter = waiter; self.waiter = nil; waiter?.resume()
        }
        func send(_ value: [String: Any]) throws {
            guard process.isRunning, !closing else { throw CancellationError() }
            try input.fileHandleForWriting.write(contentsOf: NativeBudsSettingsWire.encode(value))
        }
        func fail(_ message: String) {
            guard !closing else { return }
            failure = message
            let waiter = waiter; self.waiter = nil
            waiter?.resume(throwing: NativeBudsError(message: message))
            if let owner { owner.failed(self, message: message) } else { close() }
        }
        func close() {
            guard !closing, !exited else { return }
            // Send while active, then fence all queued frames/completions.
            try? send(["event": "close"])
            closing = true; retainLease(); reader?.stop()
            deadline?.cancel(); deadline = nil
            let waiter = waiter; self.waiter = nil; waiter?.resume(throwing: CancellationError())
            // Tool children own acoustic cleanup. Killing them while a stop is
            // queued can turn a slow start into an orphaned ring. Their real
            // exit retires the shared SDK lease; no replacement radio owner is
            // admitted merely because a timeout elapsed.
            if requiresSafetyStop { return }
            termination = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
                guard let self, !self.exited else { return }
                if self.process.isRunning { self.process.terminate() }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if !self.exited, self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            }
        }
        func waitForExit() async {
            if exited { return }
            await withCheckedContinuation { exitWaiters.append($0) }
        }
        private func didExit() {
            guard !exited else { return }
            exited = true; opened = false; reader?.stop(); reader = nil
            deadline?.cancel(); termination?.cancel()
            output.fileHandleForReading.readabilityHandler = nil; process.terminationHandler = nil
            try? input.fileHandleForWriting.close()
            releaseLease()
            let waiter = waiter; self.waiter = nil
            waiter?.resume(throwing: NativeBudsError(message: failure ?? "O serviço de ajustes foi encerrado."))
            for continuation in exitWaiters { continuation.resume() }; exitWaiters.removeAll()
            owner?.ended(self)
        }
    }
}
