import Foundation

/// The synchronous SDK call and its upstream 1.5-second settle run on one serial
/// worker, never on MainActor. The completion means the worker actually returned;
/// an optional RFCOMM open-complete callback is not an operation completion.
enum NativeBudsSettingsOpenWorker {
    // IOBluetooth can bind device/channel callbacks to the opening thread's
    // run loop. A GCD worker has no persistent run loop after open returns.
    private static let executor = NativeSDKSerialExecutor(name: "Buds.RFCOMM.open")
    static func run<Channel: AnyObject>(
        open: @escaping () -> (Int32, Channel?),
        isOpen: @escaping (Channel) -> Bool,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        completion: @escaping @MainActor (Int32, Channel?) -> Void
    ) {
        executor.submit {
            let (status, channel) = open()
            if let channel {
                let end = now() + 1.5
                // Count also bounds an injected/non-advancing clock.
                for _ in 0..<15 {
                    guard !isOpen(channel) else { break }
                    let remaining = end - now()
                    guard remaining > 0 else { break }
                    sleep(min(0.1, remaining))
                }
            }
            DispatchQueue.main.async { completion(status, channel) }
        }
    }
}

/// A per-attempt callback mailbox. It copies bytes on the SDK thread, preserves
/// order across binding, and bounds both byte and event counts. Cancellation
/// discards all data/ACKs and closes only channels reported by this attempt.
final class NativeBudsSettingsOpenCallbacks<Channel: AnyObject>: @unchecked Sendable {
    enum Event {
        case opened(Channel?, Int32), data(Channel?, Data), closed(Channel?)
        case written(Channel?, UInt, Int32, Int?), overflow
        var channel: Channel? {
            switch self {
            case .opened(let c, _), .data(let c, _), .closed(let c), .written(let c, _, _, _): return c
            case .overflow: return nil
            }
        }
    }
    private let lock = NSLock()
    private var events: [Event] = []
    private var bytes = 0
    private var overrun = false
    private var flushScheduled = false
    private var cancelled = false
    private var handler: (@MainActor (Event) -> Void)?
    private var closed: Set<ObjectIdentifier> = []
    private var closeReceipts: Set<ObjectIdentifier> = []
    private var closeWaiters: [ObjectIdentifier: [@Sendable () -> Void]] = [:]
    private let closeChannel: @MainActor (Channel) -> Void

    init(close: @escaping @MainActor (Channel) -> Void) { closeChannel = close }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    func observedClose(of channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closeReceipts.contains(ObjectIdentifier(channel))
    }
    func whenClosed(_ channel: Channel, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        let id = ObjectIdentifier(channel)
        if closeReceipts.contains(id) {
            lock.unlock(); DispatchQueue.main.async(execute: completion)
        } else {
            closeWaiters[id, default: []].append(completion); lock.unlock()
        }
    }

    func receive(_ event: Event) {
        lock.lock()
        var completions: [@Sendable () -> Void] = []
        // Cancellation retires delivery, not the SDK's close operation. Its
        // exact channel receipt must still settle the retained close lease.
        if case .closed(let channel?) = event, closeReceipts.count < 32 {
            closeReceipts.insert(ObjectIdentifier(channel))
            completions = closeWaiters.removeValue(forKey: ObjectIdentifier(channel)) ?? []
        }
        if cancelled {
            lock.unlock()
            for completion in completions { DispatchQueue.main.async(execute: completion) }
            if case .opened(let channel?, _) = event {
                DispatchQueue.main.async { self.closeOnce(channel) }
            }
            return
        }
        let count: Int
        if case .data(_, let data) = event { count = data.count } else { count = 0 }
        if !overrun {
            if events.count >= 256 || count > 65536 || bytes + count > 262144 {
                overrun = true
                events.append(.overflow)
            } else {
                events.append(event); bytes += count
            }
        }
        let schedule = handler != nil && !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        for completion in completions { DispatchQueue.main.async(execute: completion) }
        if schedule { DispatchQueue.main.async { self.flush() } }
    }

    /// Reject oversized SDK buffers before making a copy.
    func receive(_ channel: Channel?, pointer: UnsafeMutableRawPointer?, count: Int) {
        guard count > 0, let pointer else { return }
        guard count <= 65536 else { receive(.overflow); return }
        receive(.data(channel, Data(bytes: pointer, count: count)))
    }

    @MainActor func bind(_ handler: @escaping @MainActor (Event) -> Void) {
        lock.lock(); self.handler = handler; lock.unlock()
        flush()
    }
    @MainActor private func flush() {
        lock.lock()
        flushScheduled = false
        guard !cancelled, let handler else { lock.unlock(); return }
        let batch = events; events.removeAll(); bytes = 0
        lock.unlock()
        for event in batch {
            lock.lock(); let active = !cancelled; lock.unlock()
            guard active else { return }
            handler(event)
        }
    }
    @MainActor func closeOnce(_ channel: Channel) {
        guard closed.insert(ObjectIdentifier(channel)).inserted else { return }
        closeChannel(channel)
    }
    @MainActor func cancel() {
        lock.lock()
        cancelled = true; handler = nil
        let batch = events; events.removeAll(); bytes = 0
        lock.unlock()
        for event in batch {
            if case .opened(let channel?, _) = event { closeOnce(channel) }
        }
    }
}

/// A user deadline cancels the waiter, not the SDK. The drain retains this object
/// (including its delegate) until the real callback or synchronous worker return.
@MainActor private final class NativeBudsSettingsOpenPending<Value> {
    let id = UUID()
    var resource: AnyObject?
    private var waiter: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?
    private var completed = false
    private let drain: NativeBudsOperationDrain
    private let late: (Value) -> Void
    init(drain: NativeBudsOperationDrain, late: @escaping (Value) -> Void) {
        self.drain = drain; self.late = late
    }
    func wait(seconds: TimeInterval, sleep: @escaping (TimeInterval) async throws -> Void,
              start: (@escaping (Value) -> Void) -> AnyObject?) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            drain.retain(self, id: id, orphanCleanup: {})
            timer = Task { [weak self] in
                do { try await sleep(seconds) } catch { return }
                self?.cancel(NativeBudsError(message: "A abertura do serviço Samsung excedeu o prazo de espera."))
            }
            let started = start { [self] in finish($0) }
            if !completed { resource = started }
        }
    }
    private func finish(_ value: Value) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        drain.complete(id, orphaned: false)
        resource = nil
        let continuation = waiter; waiter = nil
        if let continuation { continuation.resume(returning: value) }
        else { late(value) }
    }
    func cancel(_ error: Error = CancellationError()) {
        timer?.cancel(); timer = nil
        let continuation = waiter; waiter = nil
        continuation?.resume(throwing: error)
    }
}

/// Injectable SDK boundary used by the real transport and hardware-free tests.
/// There is deliberately no baseband, audio, pairing or device-close capability.
@MainActor struct NativeBudsSettingsOpenEffects<Channel: AnyObject> {
    typealias Callbacks = NativeBudsSettingsOpenCallbacks<Channel>
    var connected: () async throws -> Bool
    var serviceChannel: () -> UInt8?
    var discover: (@escaping (Int32) -> Void) -> AnyObject?
    var open: (UInt8, Callbacks, @escaping (Int32, Channel?) -> Void) -> AnyObject?
    var isOpen: (Channel) -> Bool
    var close: (Channel) -> Void
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var refreshServiceBeforeOpen = false
}

/// Owns only one exact selected service stream (SppNew or SMEP). Cache failure can refresh once, but
/// neither timeout nor cancellation authorizes a retry over unfinished SDK work.
@MainActor final class NativeBudsSettingsOpen<Channel: AnyObject> {
    typealias Effects = NativeBudsSettingsOpenEffects<Channel>
    typealias Callbacks = Effects.Callbacks
    private let effects: Effects
    private let drain: NativeBudsOperationDrain
    private var generation: UInt64 = 0
    private var cancelPending: (() -> Void)?
    private var callbacks: Callbacks?
    private var channelResource: AnyObject?
    private(set) var channel: Channel?
    private(set) var plan = NativeBudsOpeningPolicy()
    private(set) var lastStatus: Int32?
    private(set) var selectedChannel: UInt8?
    var bound: ((Channel) -> Void)?
    var event: ((Callbacks.Event) -> Void)?
    var progress: ((String, Int32?) -> Void)?
    init(effects: Effects, drain: NativeBudsOperationDrain? = nil) {
        self.effects = effects; self.drain = drain ?? .shared
    }
    func cancel() {
        generation &+= 1
        cancelPending?(); cancelPending = nil
        callbacks?.cancel()
        if let channel { callbacks?.closeOnce(channel) }
        channel = nil; callbacks = nil; channelResource = nil
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func checkLink(_ token: UInt64) async throws {
        let connected = try await effects.connected()
        try check(token)
        guard connected else { throw NativeBudsError(message: "Conecte os Buds ao Mac antes de atualizar os ajustes.") }
        guard drain.count == 0 else {
            throw NativeBudsError(message: "O Bluetooth ainda está concluindo a tentativa anterior. Aguardando antes de reconectar.")
        }
    }
    func open() async throws {
        cancel()
        let token = generation
        try await withTaskCancellationHandler {
            do {
                try check(token)
                // The macOS SDK may return a stale channel object even when isOpen
                // succeeds. Production settings sessions follow upstream's fresh
                // SDP query before every open; tests can also exercise cache fallback.
                plan.begin(cachedChannel: effects.refreshServiceBeforeOpen ? nil : effects.serviceChannel(),
                           bluetoothConnected: true)
                var action = plan.serviceAction
                while true {
                    try await checkLink(token)
                    switch action {
                    case .queryService:
                        progress?("settings_sdp_started", nil)
                        let pending = NativeBudsSettingsOpenPending<Int32>(drain: drain, late: { _ in })
                        cancelPending = { pending.cancel() }
                        let status = try await pending.wait(seconds: 4, sleep: effects.sleep, start: effects.discover)
                        if generation == token { cancelPending = nil }
                        try await checkLink(token)
                        lastStatus = status
                        progress?("settings_sdp_completed", status)
                        action = plan.discoveryCompleted(channel: status == 0 ? effects.serviceChannel() : nil)
                    case .openChannel(let id):
                        // The exact service record may have changed during the link check.
                        guard effects.serviceChannel() == id else {
                            action = plan.channelCompleted(success: false) ?? .fail; continue
                        }
                        selectedChannel = id
                        progress?("settings_rfcomm_started", nil)
                        let mailbox = Callbacks(close: effects.close)
                        callbacks = mailbox
                        let pending = NativeBudsSettingsOpenPending<(Int32, Channel?)>(drain: drain) { result in
                            mailbox.cancel()
                            if let channel = result.1 { mailbox.closeOnce(channel) }
                        }
                        cancelPending = { pending.cancel() }
                        let result = try await pending.wait(seconds: 8, sleep: effects.sleep) { done in
                            let resource = effects.open(id, mailbox) { done(($0, $1)) }
                            channelResource = resource
                            return resource
                        }
                        if generation == token { cancelPending = nil }
                        // Own the result before an awaited link recheck so cancellation
                        // cannot strand a returned channel between worker and binding.
                        if generation != token {
                            mailbox.cancel()
                            if let channel = result.1 { mailbox.closeOnce(channel) }
                            throw CancellationError()
                        }
                        channel = result.1
                        lastStatus = result.0
                        progress?("settings_rfcomm_returned", result.0)
                        try await checkLink(token)
                        if let channel, effects.isOpen(channel) {
                            _ = plan.channelCompleted(success: true)
                            bound?(channel)
                            try check(token)
                            mailbox.bind { [weak self, weak channel] value in
                                guard let self, let channel, self.generation == token,
                                      value.channel == nil || value.channel === channel else { return }
                                // Worker return/isOpen is authoritative, not this optional callback.
                                if case .opened = value { return }
                                self.event?(value)
                            }
                            try check(token)
                            return
                        }
                        mailbox.cancel()
                        if let channel { mailbox.closeOnce(channel) }
                        channel = nil; callbacks = nil; channelResource = nil
                        action = plan.channelCompleted(success: false) ?? .fail
                    case .fail:
                        throw NativeBudsError(message: "Não foi possível abrir o serviço Samsung selecionado nos Buds.")
                    }
                }
            } catch {
                if generation == token { _ = plan.timedOut(); cancel() }
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.cancel()
            }
        }
    }
}
