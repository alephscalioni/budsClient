import Foundation

struct NativeBudsPassiveLinkSample {
    enum Origin { case baseline, notification }
    let address: String
    let connected: Bool
    let capturedAt: TimeInterval
    let sequence: UInt64
    let origin: Origin
}

/// Observation only: no pairing, profile opens, routing or settings operations.
/// The first sample is a baseline; notifications carry capture time and order.
@MainActor protocol NativeBudsPassiveLinkObserving: AnyObject {
    func observe(address: String, receive: @escaping (NativeBudsPassiveLinkSample) -> Void) -> (() -> Void)?
}

/// Root retains this object and calls select only when the selected Buds change.
/// Snapshots/settings reads must not call show or manufacture link notifications.
/// NativeSession integration: retain `live(onEvent:onLinkState:)`, forward
/// onEvent to ConnectionHUD.shared.show(event:), and onLinkState to
/// ConnectionHUD.shared.observeLink(address:connected:at:). Call select after
/// selection changes and stop when the session retires. It observes even while
/// automatic switching is disabled and never grants controller ownership.
@MainActor final class NativeBudsConnectionMonitor {
    private let observer: any NativeBudsPassiveLinkObserving
    private let now: () -> TimeInterval
    private let onEvent: (NativeConnectionBannerEvent) -> Void
    private let onLinkState: (String, Bool, TimeInterval) -> Void
    private var cancellation: (() -> Void)?
    private var generation = UUID()
    private var address: String?
    private var name = ""
    private var startedAt: TimeInterval = 0
    private var lastSampleAt: TimeInterval = 0
    private var lastSequence: UInt64?
    private var connected: Bool?

    init(observer: any NativeBudsPassiveLinkObserving,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onEvent: @escaping (NativeConnectionBannerEvent) -> Void,
         onLinkState: @escaping (String, Bool, TimeInterval) -> Void) {
        self.observer = observer; self.now = now; self.onEvent = onEvent; self.onLinkState = onLinkState
    }

    static func live(onEvent: @escaping (NativeConnectionBannerEvent) -> Void,
                     onLinkState: @escaping (String, Bool, TimeInterval) -> Void) -> NativeBudsConnectionMonitor {
        let notifications = NativeBudsLinkNotificationProcess()
        return .init(observer: NativeBudsAsyncPassiveLinkObserver(
            baseline: { try await notifications.baseline(address: $0) },
            notifications: { address, receive in
                notifications.start(address: address, receive: receive)
            }), onEvent: onEvent, onLinkState: onLinkState)
    }

    func select(address value: String, name: String) {
        guard let selected = NativeConnectionBannerPolicy.normalizedAddress(value) else { stop(); return }
        if address == selected { self.name = name; return }
        stop()
        let token = generation
        address = selected; self.name = name; startedAt = now(); lastSampleAt = startedAt
        let cancel = observer.observe(address: selected) { [weak self] sample in
            self?.receive(sample, generation: token)
        }
        guard generation == token else { cancel?(); return }
        cancellation = cancel
        if cancel == nil { stop() }
    }

    func stop() {
        generation = UUID(); address = nil; connected = nil; lastSequence = nil
        let cancel = cancellation; cancellation = nil; cancel?()
    }

    deinit {
        let cancel = cancellation
        Task { @MainActor in cancel?() }
    }

    private func receive(_ sample: NativeBudsPassiveLinkSample, generation token: UUID) {
        guard generation == token, let address,
              NativeConnectionBannerPolicy.normalizedAddress(sample.address) == address,
              sample.capturedAt.isFinite, sample.capturedAt >= startedAt,
              sample.capturedAt >= lastSampleAt, sample.capturedAt <= now(),
              lastSequence.map({ sample.sequence > $0 }) ?? true else { return }
        switch sample.origin {
        case .baseline:
            guard connected == nil else { return } // delayed snapshots never reset a live observation
        case .notification:
            guard connected != nil else { return } // no transition without a baseline
        }
        lastSampleAt = sample.capturedAt; lastSequence = sample.sequence
        let previous = connected
        connected = sample.connected
        guard previous != sample.connected else { return }
        onLinkState(address, sample.connected, sample.capturedAt)
        // A link loss is silent. Only the model can attest a remote handoff.
        guard generation == token, sample.origin == .notification, sample.connected else { return }
        onEvent(.init(address: address, name: name, kind: .directMacConnection, occurredAt: sample.capturedAt))
    }
}

/// One fresh, passive async read per subscription. The injectable notification
/// source and baseline let tests exercise the live delivery path without radio IO.
@MainActor final class NativeBudsAsyncPassiveLinkObserver: NativeBudsPassiveLinkObserving {
    typealias Receipt = @Sendable (Bool, TimeInterval) -> UInt64?
    private let baseline: (String) async throws -> Bool
    private let notifications: (String, @escaping Receipt) -> (() -> Void)?
    private let now: () -> TimeInterval

    init(baseline: @escaping (String) async throws -> Bool,
         notifications: @escaping (String, @escaping Receipt) -> (() -> Void)?,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.baseline = baseline; self.notifications = notifications; self.now = now
    }

    func observe(address: String, receive: @escaping (NativeBudsPassiveLinkSample) -> Void) -> (() -> Void)? {
        let delivery = NativeBudsPassiveLinkDelivery(address: address, startedAt: now(), receive: receive)
        guard let cancel = notifications(address, { delivery.notification(connected: $0, at: $1) }) else {
            delivery.stop(); return nil
        }
        delivery.start(read: baseline)
        return { delivery.stop(); cancel() }
    }
}

/// Captures notification order before MainActor delivery. No mutable Bluetooth
/// properties are read: connect/disconnect notification semantics are the facts.
private final class NativeBudsPassiveLinkInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var sequence: UInt64 = 0
    private var lastCaptureAt: TimeInterval
    private var pending: [NativeBudsPassiveLinkSample] = []
    private let address: String

    init(address: String, startedAt: TimeInterval) { self.address = address; lastCaptureAt = startedAt }

    func capture(connected: Bool, at time: TimeInterval) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard active, time.isFinite, time >= lastCaptureAt else { return nil }
        lastCaptureAt = time; sequence += 1
        pending.append(.init(address: address, connected: connected, capturedAt: time,
                             sequence: sequence, origin: .notification))
        return sequence
    }

    func drain() -> [NativeBudsPassiveLinkSample] {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending.removeAll(keepingCapacity: true); return result
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false; pending.removeAll()
    }
}

@MainActor private final class NativeBudsPassiveLinkDelivery {
    private nonisolated let inbox: NativeBudsPassiveLinkInbox
    private let address: String
    private let startedAt: TimeInterval
    private let receive: (NativeBudsPassiveLinkSample) -> Void
    private var baselineTask: Task<Void, Never>?
    private var active = true
    private var baselineReady = false
    private var hasBaseline = false

    init(address: String, startedAt: TimeInterval, receive: @escaping (NativeBudsPassiveLinkSample) -> Void) {
        self.address = address; self.startedAt = startedAt; self.receive = receive
        inbox = .init(address: address, startedAt: startedAt)
    }

    func start(read: @escaping (String) async throws -> Bool) {
        let address = address
        baselineTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let connected = try? await read(address)
            guard !Task.isCancelled, let self, self.active else { return }
            self.baselineReady = true
            // A query spanning a notification cannot locate the link change
            // within the startup snapshot. Absorb all already-captured facts
            // into a silent baseline; the newest notification overrides a stale
            // query result. Later notifications are genuine observable edges.
            let pending = self.inbox.drain()
            if let latest = pending.last {
                self.emitBaseline(connected: latest.connected, at: latest.capturedAt, sequence: latest.sequence)
            } else if let connected {
                self.emitBaseline(connected: connected, at: self.startedAt, sequence: 0)
            }
            // Failed reads stay unknown until the first notification can seed
            // a silent baseline. Failure must never fabricate "disconnected".
        }
    }

    nonisolated func notification(connected: Bool, at time: TimeInterval) -> UInt64? {
        guard let sequence = inbox.capture(connected: connected, at: time) else { return nil }
        Task { @MainActor [weak self] in self?.deliverNotifications() }
        return sequence
    }

    private func emitBaseline(connected: Bool, at time: TimeInterval, sequence: UInt64) {
        hasBaseline = true
        receive(.init(address: address, connected: connected, capturedAt: time, sequence: sequence, origin: .baseline))
    }

    private func deliverNotifications() {
        guard active, baselineReady else { return }
        for sample in inbox.drain() {
            guard active else { return } // receive may synchronously cancel/reselect
            if hasBaseline { receive(sample) }
            else { emitBaseline(connected: sample.connected, at: sample.capturedAt, sequence: sample.sequence) }
        }
    }

    func stop() {
        active = false; inbox.stop(); baselineTask?.cancel(); baselineTask = nil
    }
}

