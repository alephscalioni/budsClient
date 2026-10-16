import Foundation

protocol NativeBudsSDKCloseObserving: AnyObject {
    func observedClose(of channel: AnyObject) -> Bool
    func whenClosed(_ channel: AnyObject, completion: @escaping @Sendable () -> Void)
}

/// SDK close success can precede the actual channel-closed callback. Settings
/// delegates and the shared drain survive until that exact receipt, with a
/// bounded worker wait. A timeout remains unresolved and blocks replacement.
enum NativeBudsSDKCloseCompletion {
    static func finish(status: Int32, wasOpen: Bool, observed: (() -> Bool)?,
                       isOpen: () -> Bool, clearDelegate: () -> Void,
                       sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
                       now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Int32 {
        guard status == 0 || !isOpen() else { return status }
        if wasOpen, let observed {
            let end = now() + 1.5
            for _ in 0..<30 {
                if observed() { break }
                let remaining = end - now()
                guard remaining > 0 else { break }
                sleep(min(0.05, remaining))
            }
            guard observed(), !isOpen() else { return -1 }
        }
        clearDelegate()
        return 0
    }
}

/// Keeps native write buffers and delegates alive through SDK return, then queues
/// profile close behind the write. MainActor deadlines do not depend on the SDK.
@MainActor final class NativeSerialChannelWriter<Channel: AnyObject> {
    typealias Enqueue = (@escaping () -> Void) -> Void
    private final class Lease {
        let channel: Channel
        var retained: AnyObject?
        var writes: [UUID: NativeSDKInvocation] = [:]
        var closing = false
        init(_ channel: Channel, retained: AnyObject?) { self.channel = channel; self.retained = retained }
    }
    private final class Storage {
        let channel: Channel
        let bytes: NSMutableData
        let retained: AnyObject?
        init(_ channel: Channel, data: Data, retained: AnyObject?) {
            self.channel = channel; bytes = NSMutableData(data: data); self.retained = retained
        }
    }
    private let enqueue: Enqueue
    private let write: (Channel, NSMutableData) -> Int32
    private let closeChannel: (Channel) -> Int32
    private let settleClose: ((Channel, @escaping @MainActor () -> Void) -> Void)?
    private let now: () -> TimeInterval
    private let drain: NativeBudsOperationDrain
    private var leases: [ObjectIdentifier: Lease] = [:]
    init(enqueue: @escaping Enqueue, write: @escaping (Channel, NSMutableData) -> Int32,
         close: @escaping (Channel) -> Int32, drain: NativeBudsOperationDrain,
         settleClose: ((Channel, @escaping @MainActor () -> Void) -> Void)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.enqueue = enqueue; self.write = write; closeChannel = close; self.drain = drain; self.now = now
        self.settleClose = settleClose
    }
    @discardableResult func send(_ data: Data, channel: Channel, retaining: AnyObject?, deadline: TimeInterval,
                                completion: @escaping (Int32, Int) -> Void) -> NativeSDKInvocation? {
        let key = ObjectIdentifier(channel)
        let lease = leases[key] ?? Lease(channel, retained: retaining)
        guard !lease.closing, !data.isEmpty, data.count <= Int(UInt16.max), now() < deadline else { return nil }
        leases[key] = lease
        let id = UUID(), invocation = NativeSDKInvocation(deadline: deadline)
        let storage = Storage(channel, data: data, retained: retaining ?? lease.retained)
        lease.writes[id] = invocation
        drain.retain(storage, id: id, orphanCleanup: {})
        let write = write, clock = now, drain = drain
        enqueue {
            let result: Int32 = invocation.claim(at: clock()) ? write(storage.channel, storage.bytes) : -1
            DispatchQueue.main.async { [self, storage] in
                lease.writes.removeValue(forKey: id)
                drain.complete(id, orphaned: false)
                // Timers may have been delayed by unrelated UI work. A late
                // hardware success still cannot confirm this transaction.
                completion(invocation.acceptsCompletion(at: clock()) ? result : -1, storage.bytes.length)
                _ = self // Keep the owner until this exact old result settles.
            }
        }
        return invocation
    }
    func close(_ channel: Channel, retaining: AnyObject? = nil) {
        let key = ObjectIdentifier(channel)
        let lease = leases[key] ?? Lease(channel, retained: retaining)
        guard !lease.closing else { return }
        lease.closing = true; leases[key] = lease
        for invocation in lease.writes.values { invocation.cancel() }
        let id = UUID(), close = closeChannel, drain = drain
        drain.retain(lease, id: id, orphanCleanup: {})
        enqueue {
            let result = close(channel)
            DispatchQueue.main.async { [self] in
                // An uncertain close retains its resource/drain and prevents a
                // replacement open. Never equate waiter cancellation with close.
                let finish: @MainActor () -> Void = { [self] in
                    guard leases[key] === lease else { return }
                    leases.removeValue(forKey: key)
                    drain.complete(id, orphaned: false)
                }
                if result == 0 { finish() }
                else { settleClose?(channel, finish) }
            }
        }
    }
}
