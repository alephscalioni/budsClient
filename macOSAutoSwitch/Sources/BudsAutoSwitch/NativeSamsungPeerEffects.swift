import Foundation

protocol NativeSamsungPeerChannel: AnyObject {}

/// Stable storage is retained in the operation lease through actual SDK return
/// and exact completion evidence, including after cancellation or owner release.
final class NativeSamsungPeerWriteBuffer: @unchecked Sendable {
    let bytes: NSMutableData
    init(_ data: Data) { bytes = NSMutableData(data: data) }
}

enum NativeSamsungPeerRequest {
    case connect(NativeSamsungPeerVerifiedAddress)
    case discover(NativeSamsungPeerVerifiedAddress)
    case open(NativeSamsungPeerVerifiedAddress, UInt8)
    case write(any NativeSamsungPeerChannel, NativeSamsungPeerWriteBuffer)
}

enum NativeSamsungPeerResult {
    case connected(Bool)
    case discovered(success: Bool, recordChannel: UInt8?)
    case opened((any NativeSamsungPeerChannel)?, success: Bool, mtu: Int)
    case written(channel: any NativeSamsungPeerChannel, id: UInt, success: Bool, bytesWritten: Int?)
}

/// The effect must report return and callback separately. A timeout does not
/// cancel a noncooperative SDK call. No SDK invocation may block MainActor.
@MainActor protocol NativeSamsungPeerEffects: AnyObject {
    func start(_ request: NativeSamsungPeerRequest, operation: NativeSamsungPeerOperation)
    /// Completion means close returned, not a phone/baseband disconnection.
    func close(_ channel: any NativeSamsungPeerChannel, completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor final class NativeSamsungPeerOperation {
    nonisolated let invocation: NativeSDKInvocation
    let id: UInt
    let request: NativeSamsungPeerRequest
    var sdkResource: AnyObject?
    var didReturn = false
    var result: NativeSamsungPeerResult?
    var returnedChannel: (any NativeSamsungPeerChannel)?
    let onReturn: (Bool, (any NativeSamsungPeerChannel)?, AnyObject?) -> Void
    let onResult: (NativeSamsungPeerResult) -> Void
    let onBytes: (any NativeSamsungPeerChannel, Data?) -> Void
    let onClosed: (any NativeSamsungPeerChannel) -> Void
    init(id: UInt, request: NativeSamsungPeerRequest, sdkDeadline: TimeInterval = .infinity,
         onReturn: @escaping (Bool, (any NativeSamsungPeerChannel)?, AnyObject?) -> Void,
         onResult: @escaping (NativeSamsungPeerResult) -> Void,
         onBytes: @escaping (any NativeSamsungPeerChannel, Data?) -> Void,
         onClosed: @escaping (any NativeSamsungPeerChannel) -> Void) {
        invocation = NativeSDKInvocation(deadline: sdkDeadline)
        self.id = id; self.request = request; self.onReturn = onReturn
        self.onResult = onResult; self.onBytes = onBytes; self.onClosed = onClosed
    }
}

@MainActor protocol NativeSamsungPeerTimer: AnyObject { func cancel() }
@MainActor protocol NativeSamsungPeerClock: AnyObject {
    var now: TimeInterval { get }
    func schedule(at: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any NativeSamsungPeerTimer
}
@MainActor final class NativeSamsungPeerSystemClock: NativeSamsungPeerClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private final class Timer: NativeSamsungPeerTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel(); task = nil }
        deinit { task?.cancel() }
    }
    func schedule(at: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any NativeSamsungPeerTimer {
        let timer = Timer()
        let delay = max(0, at - now)
        timer.task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }; body()
        }
        return timer
    }
}

/// Separate namespace/leases from headset acquisition. A lease remains held for
/// a noncooperative operation forever if necessary; deadlines bound callers only.
@MainActor final class NativeSamsungPeerOperationDrain {
    static let shared = NativeSamsungPeerOperationDrain()
    private var entries: [NativeSamsungPeerVerifiedAddress: (UUID, AnyObject)] = [:]
    var count: Int { entries.count }
    func acquire(_ peer: NativeSamsungPeerVerifiedAddress, id: UUID, owner: AnyObject) throws {
        guard entries[peer] == nil else { throw NativeSamsungPeerFailure.peerDraining }
        entries[peer] = (id, owner)
    }
    func release(_ peer: NativeSamsungPeerVerifiedAddress, id: UUID) {
        guard entries[peer]?.0 == id else { return }
        entries.removeValue(forKey: peer)
    }
}
