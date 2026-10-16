import Foundation

/// A queued SDK invocation can be retired before dispatch. Once claimed, its
/// storage must survive until the non-cancellable SDK call actually returns.
final class NativeSDKInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var claimed = false
    private let deadline: TimeInterval
    init(deadline: TimeInterval = .infinity) { self.deadline = deadline }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func claim(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !claimed, now.isFinite, now < deadline else { return false }
        claimed = true
        return true
    }
    func acceptsCompletion(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed && !cancelled && now.isFinite && now < deadline
    }
}

/// SDK callbacks sometimes pump a nested run loop. A single scheduled drain,
/// rather than one perform-selector per job, prevents nested SDK operations.
final class NativeSDKSerialExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var thread: Thread?
    private var jobs: [() -> Void] = []
    private var scheduled = false
    private let name: String
    init(name: String) { self.name = name }
    private final class Drain: NSObject, @unchecked Sendable {
        let executor: NativeSDKSerialExecutor
        init(_ executor: NativeSDKSerialExecutor) { self.executor = executor }
        @objc func run() { executor.run() }
    }
    func submit(_ body: @escaping () -> Void) {
        lock.lock()
        jobs.append(body)
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let worker: Thread
        if let thread { worker = thread }
        else {
            worker = Thread {
                let port = Port()
                RunLoop.current.add(port, forMode: .default)
                while true { autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) } }
            }
            worker.name = name; thread = worker; worker.start()
        }
        lock.unlock()
        Drain(self).perform(#selector(Drain.run), on: worker, with: nil, waitUntilDone: false)
    }
    private func run() {
        while true {
            lock.lock()
            guard !jobs.isEmpty else { scheduled = false; lock.unlock(); return }
            let job = jobs.removeFirst()
            lock.unlock()
            autoreleasepool { job() }
        }
    }
}
