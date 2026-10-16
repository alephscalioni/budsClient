import Foundation
import Darwin

@MainActor enum NativeBudsSettingsHelper {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains(NativeBudsSettingsWire.flag) else { return false }
        guard args.count == 6, args[1] == NativeBudsSettingsWire.flag, args[2] == "--address",
              args[4] == "--owner-pid", let owner = Int32(args[5]), owner > 1, owner == getppid(),
              MacAudio.normalize(args[3]).count == 12 else { exit(64) }
        let session = Session(address: args[3])
        session.start()
        while getppid() == owner && kill(owner, 0) == 0 && !session.done {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        session.stop()
        drainCleanup { session.done }
        return true
    }
    /// Parent death must not return from main while cleanup is only queued.
    static func drainCleanup(until done: () -> Bool) {
        while !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
    }

    @MainActor private final class Session {
        let address: String
        let transport = NativeBudsTransport(configuration: .sppNew)
        var done = false
        private var closing = false
        private var verified = false
        private var observedAt: TimeInterval?
        private var requests: [UInt: UInt] = [:]
        private var lastRequest: UInt = 0
        private var operation: Task<Void, Never>?
        private var input: NativeBudsSettingsPipe?
        private var toolWatchdog = NativeBudsToolsWatchdog()
        private var toolTimer: Task<Void, Never>?
        private var stopWrites: Set<UInt> = []
        private var stopRetry: Task<Void, Never>?
        private var stopRetryPending = false
        private var placements: (SamsungBudsSettingsPacket.Placement, SamsungBudsSettingsPacket.Placement)?
        private var placementAt: TimeInterval?
        private var output: NativeBudsSettingsOutput?
        init(address: String) {
            self.address = address
            output = try? NativeBudsSettingsOutput { [weak self] in Task { @MainActor in self?.stop() } }
        }
        func emit(_ value: [String: Any]) {
            guard let data = try? NativeBudsSettingsWire.encode(value) else { stop(); return }
            if output?.enqueue(data) != true { stop() }
        }
        func start() {
            guard output != nil else { done = true; return }
            transport.onSettingsFrame = { [weak self] frame in
                guard let self, !self.closing else { return }
                if let physical = SamsungBudsSettingsPacket.physicalBuds3Pro(frame) {
                    guard physical else { self.fail("O estado físico identifica outro modelo de Buds."); return }
                    self.verified = true; self.observedAt = ProcessInfo.processInfo.systemUptime
                }
                if let placements = NativeBudsToolsPacket.placements(frame) {
                    self.placements = placements; self.placementAt = ProcessInfo.processInfo.systemUptime
                    if let kind = self.toolWatchdog.kind,
                       (kind == .find && (placements.0 != .idle || placements.1 != .idle))
                        || (kind == .fit && (placements.0 != .wearing || placements.1 != .wearing)) {
                        self.stopTool()
                    }
                } else if self.toolWatchdog.kind != nil, frame.command == 0x60 || frame.command == 0x61 {
                    self.stopTool()
                }
                self.toolWatchdog.observed(frame)
                if self.toolWatchdog.kind == .fit, NativeBudsToolsPacket.fitResult(frame) != nil { self.stopTool() }
                guard !frame.isFragment, [UInt8(0x61), 0x42, 0x77, 0x60, 0x9E, 0xA1, 0xA3, 0x69, 0xB4].contains(frame.command) else { return }
                self.emit(["event": "frame", "command": Int(frame.command), "payload": frame.payload.base64EncodedString(),
                           "uptime": ProcessInfo.processInfo.systemUptime, "observed_at": Date().timeIntervalSince1970])
            }
            transport.onWriteComplete = { [weak self] id in
                guard let self else { return }
                if self.stopWrites.remove(id) != nil { return }
                guard !self.closing, let request = self.requests.removeValue(forKey: id) else { return }
                self.emit(["event": "written", "id": request])
            }
            transport.onWriteFailure = { [weak self] id, error in
                guard let self else { return }
                let safetyStop = self.stopWrites.remove(id) != nil
                if self.closing {
                    if safetyStop { self.retryStop() }
                } else { self.fail(error.message) }
            }
            transport.onFailure = { [weak self] error in self?.fail(error.message) }
            let reader = NativeBudsSettingsPipe { [weak self] batch in
                guard let self, !self.closing else { return }
                guard let batch else { self.stop(); return }
                for value in batch { self.command(value); if self.closing { break } }
            }
            input = reader
            FileHandle.standardInput.readabilityHandler = { handle in reader.append(handle.availableData) }
            operation = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.open(address: self.address)
                    guard !self.closing, !Task.isCancelled else { return }
                    self.emit(["event": "opened"])
                } catch { if !self.closing { self.fail(error.localizedDescription) } }
            }
        }
        private func command(_ value: [String: Any]) {
            guard let event = value["event"] as? String else { fail("Comando de serviço inválido."); return }
            if event == "close" { stop(); return }
            guard event == "write", verified, transport.isOpen, requests.isEmpty,
                  let id = NativeBudsSettingsWire.integer(value["id"]), id > lastRequest,
                  let encoded = value["packet"] as? String, encoded.utf8.count <= 1360,
                  let data = Data(base64Encoded: encoded), NativeBudsSettingsWire.permittedWrite(data),
                  let frame = SamsungBudsSettingsPacket.decodeCompleteFrame(data),
                  frame.command != 0x90 || observedAt.map({ ProcessInfo.processInfo.systemUptime - $0 <= 15 }) == true else {
                fail("Comando sem sessão física válida ou não permitido."); return
            }
            do {
                if NativeBudsToolsPacket.permits(frame) {
                    guard NativeBudsToolsPacket.startAllowed(frame, placements: placements,
                        observedAt: placementAt, now: ProcessInfo.processInfo.systemUptime) else {
                        fail("Posição dos fones não permite iniciar esta ferramenta. Atualize a leitura."); return
                    }
                    if frame.command == 0xA6 || (frame.command == 0x9D && Array(frame.payload) == [1]) {
                        let now = ProcessInfo.processInfo.systemUptime
                        guard toolWatchdog.kind == nil, observedAt.map({ now >= $0 && now - $0 <= 5 }) == true,
                              (try? MacAudio.activity().input) == false else {
                            fail("Termine a ferramenta ou a chamada antes de iniciar outra."); return
                        }
                        // Arm before SDK enqueue; no ACK wait owns this deadline.
                        transport.protectToolCleanupWrites()
                        toolWatchdog.submitted(frame, at: ProcessInfo.processInfo.systemUptime)
                        armToolTimer()
                    } else {
                        if frame.command == 0xA2, toolWatchdog.kind != .find {
                            fail("Seleção de lado sem busca ativa."); return
                        }
                        toolWatchdog.submitted(frame, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
                let sdkID = try transport.sendTracked(data)
                requests[sdkID] = id; lastRequest = id
            } catch { fail(error.localizedDescription) }
        }
        private func fail(_ message: String) {
            guard !closing else { return }
            emit(["event": "error", "message": String(message.prefix(512))]); stop()
        }
        private func armToolTimer() {
            toolTimer?.cancel()
            toolTimer = Task { [weak self] in
                while let self, !self.closing, self.toolWatchdog.kind != nil {
                    if let stop = self.toolWatchdog.due(at: ProcessInfo.processInfo.systemUptime) {
                        self.sendStop(stop)
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
        }
        private func sendStop(_ packet: Data) {
            guard transport.isOpen else { return }
            if let id = try? transport.sendTracked(packet) { stopWrites.insert(id) }
            else { retryStop() }
        }
        private func retryStop() {
            guard !stopRetryPending, transport.isOpen, toolWatchdog.cleanup != nil else { return }
            stopRetryPending = true
            stopRetry = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.stopRetryPending = false
                if let packet = self.toolWatchdog.cleanup { self.sendStop(packet) }
            }
        }
        private func stopTool(force: Bool = false) {
            if let packet = force ? toolWatchdog.cleanup : toolWatchdog.requestStop() { sendStop(packet) }
        }
        func stop() {
            guard !closing else { return }
            closing = true; operation?.cancel(); toolTimer?.cancel(); input?.stop()
            FileHandle.standardInput.readabilityHandler = nil
            let needsToolStop = toolWatchdog.cleanup != nil
            stopTool(force: true)
            if !needsToolStop { transport.close() }
            operation = Task { [weak self] in
                if needsToolStop {
                    // Never cancel a queued stop behind a delayed start SDK
                    // callback. Keep the helper/lease until stop completes or
                    // the physical channel is actually lost; no acoustic
                    // success is inferred from that loss.
                    while (self?.stopWrites.isEmpty == false || self?.stopRetryPending == true) && self?.transport.isOpen == true {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    self?.transport.close()
                    self?.stopRetry?.cancel(); self?.stopRetryPending = false
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while NativeBudsOperationDrain.shared.count > 0 && ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                while self?.output?.pending == true { try? await Task.sleep(for: .milliseconds(10)) }
                self?.output?.close(); self?.done = true
            }
        }
    }
}
