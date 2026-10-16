import Foundation
import CoreFoundation

/// A bounded, ordered stream of facts, with no device/account identifiers.
struct NativeBudsLinkEventStream {
    struct Sample: Equatable { let connected: Bool; let at: TimeInterval }
    private var buffer = Data()
    private var sequence: UInt64 = 0
    private var lastTime: TimeInterval = 0
    private(set) var ready = false
    private(set) var failed = false
    mutating func append(_ data: Data, now: TimeInterval) -> [Sample] {
        guard !failed, data.count <= 65536 else { failed = true; return [] }
        buffer.append(data)
        var result: [Sample] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            if line.count <= 4096,
               let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               value["event"] as? String == "ready",
               !ready, let time = value["uptime"] as? NSNumber,
               CFGetTypeID(time) != CFBooleanGetTypeID(), time.doubleValue.isFinite,
               time.doubleValue >= 0, time.doubleValue <= now {
                ready = true
                continue
            }
            guard line.count <= 4096,
                  ready,
                  let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  value["event"] as? String == "link",
                  let connected = value["connected"] as? NSNumber, CFGetTypeID(connected) == CFBooleanGetTypeID(),
                  let order = value["sequence"] as? NSNumber, CFGetTypeID(order) != CFBooleanGetTypeID(),
                  order.doubleValue >= 1, order.doubleValue < Double(UInt64.max),
                  order.doubleValue.rounded() == order.doubleValue, order.uint64Value > sequence,
                  let timestamp = value["uptime"] as? NSNumber, CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
                  timestamp.doubleValue.isFinite, timestamp.doubleValue >= lastTime,
                  timestamp.doubleValue >= 0, timestamp.doubleValue <= now else {
                failed = true; buffer.removeAll(); return []
            }
            sequence = order.uint64Value; lastTime = timestamp.doubleValue
            result.append(.init(connected: connected.boolValue, at: lastTime))
        }
        guard buffer.count <= 4096 else { failed = true; buffer.removeAll(); return [] }
        return result
    }
}

private final class NativeBudsLinkPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var stream = NativeBudsLinkEventStream()
    private let receive: @Sendable (Bool, TimeInterval) -> UInt64?
    private let onReady: @Sendable () -> Void
    private let onEnd: @Sendable () -> Void
    init(receive: @escaping @Sendable (Bool, TimeInterval) -> UInt64?,
         onReady: @escaping @Sendable () -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.receive = receive; self.onReady = onReady; self.onEnd = onEnd
    }
    func stop() { lock.lock(); active = false; lock.unlock() }
    func append(_ data: Data) -> Bool {
        lock.lock()
        guard active, !data.isEmpty else { active = false; lock.unlock(); onEnd(); return false }
        let wasReady = stream.ready
        let samples = stream.append(data, now: ProcessInfo.processInfo.systemUptime)
        let valid = !stream.failed
        if !valid { active = false }
        let becameReady = !wasReady && stream.ready && valid
        lock.unlock()
        if becameReady { onReady() }
        if !valid { onEnd() }
        for sample in samples {
            lock.lock(); let deliver = active; lock.unlock()
            guard deliver else { break }
            _ = receive(sample.connected, sample.at)
        }
        return valid
    }
}

/// One baseline waiter per subscription. Startup, cancellation and EOF cannot
/// turn process creation into proof that notifications are registered.
@MainActor final class NativeBudsLinkReadiness {
    private var state: Bool?
    private var waiter: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    func resolve(_ ready: Bool) {
        if state == false { return }
        state = ready
        deadline?.cancel(); deadline = nil
        let continuation = waiter; waiter = nil
        if ready { continuation?.resume() }
        else { continuation?.resume(throwing: CancellationError()) }
    }
    func wait(sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) async throws {
        do { try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let state {
                guard state else { throw CancellationError() }
                return
            }
            guard waiter == nil else { throw CancellationError() }
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                deadline = Task { [weak self] in
                    do { try await sleep(); self?.resolve(false) } catch {}
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { @MainActor [weak self] in self?.resolve(false) } }
        } catch { resolve(false); throw error }
    }
}

@MainActor final class NativeBudsLinkNotificationProcess {
    @MainActor private final class Session {
        let address: String
        let gate = NativeBudsLinkReadiness()
        let process = Process(), pipe = Pipe()
        var reader: NativeBudsLinkPipeReader?
        private(set) var stopped = false
        init(address: String) { self.address = address }
        func run(helper: URL, receive: @escaping @Sendable (Bool, TimeInterval) -> UInt64?) throws {
            let reader = NativeBudsLinkPipeReader(receive: receive, onReady: { [weak self] in
                Task { @MainActor in if self?.stopped == false { self?.gate.resolve(true) } }
            }, onEnd: { [weak self] in Task { @MainActor in self?.stop() } })
            self.reader = reader
            process.executableURL = helper
            process.arguments = [NativeBudsLinkObserverHelper.flag, "--address", address,
                                 "--owner-pid", String(ProcessInfo.processInfo.processIdentifier)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in _ = reader.append(handle.availableData) }
            // On exit discard unread records and retire the session, rather than
            // deliver late facts after an absent/dead observer has been accepted.
            process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.stop() } }
            try process.run()
        }
        func stop() {
            guard !stopped else { return }
            stopped = true; gate.resolve(false)
            reader?.stop(); reader = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
    }
    private var current: Session?
    func start(address: String, receive: @escaping @Sendable (Bool, TimeInterval) -> UInt64?) -> (() -> Void)? {
        current?.stop()
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "BudsGuardHelper") else { current = nil; return nil }
        let session = Session(address: address); current = session
        do { try session.run(helper: helper, receive: receive) }
        catch { session.stop(); current = nil; return nil }
        return { [weak self] in
            session.stop()
            if self?.current === session { self?.current = nil }
        }
    }
    func baseline(address: String) async throws -> Bool {
        guard let session = current, session.address == address else { throw CancellationError() }
        do { try await session.gate.wait() }
        catch { session.stop(); throw error }
        guard current === session, !session.stopped else { throw CancellationError() }
        let connected = try await MacAudio.isBluetoothConnected(address)
        guard current === session, !session.stopped else { throw CancellationError() }
        return connected
    }
}
