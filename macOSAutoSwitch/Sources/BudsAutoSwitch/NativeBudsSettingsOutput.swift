import Foundation
import Darwin

/// Bounded, nonblocking pipe output on its own queue. A stalled parent cannot
/// block MainActor's tool watchdog or EOF cleanup. No raw bytes enter logs.
final class NativeBudsSettingsOutput: @unchecked Sendable {
    private final class Descriptor: @unchecked Sendable {
        let value: Int32
        private let lock = NSLock()
        private var closed = false
        init(_ value: Int32) { self.value = value }
        func close() { lock.lock(); defer { lock.unlock() }; if !closed { closed = true; Darwin.close(value) } }
        deinit { close() }
    }
    private let descriptor: Descriptor
    private let queue = DispatchQueue(label: "Buds.settings.output")
    private let lock = NSLock()
    private var active = true
    private var allocated = 0
    private let onFailure: @Sendable () -> Void
    init(fd: Int32 = STDOUT_FILENO, onFailure: @escaping @Sendable () -> Void) throws {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw NativeBudsError(message: "Pipe de saída indisponível.") }
        descriptor = Descriptor(duplicate); self.onFailure = onFailure
        let flags = fcntl(duplicate, F_GETFL)
        guard flags >= 0, fcntl(duplicate, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(duplicate, F_SETNOSIGPIPE, 1) == 0 else {
            descriptor.close(); throw NativeBudsError(message: "Pipe não bloqueante indisponível.")
        }
    }
    deinit { close() }
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return allocated > 0 }
    @discardableResult func enqueue(_ data: Data) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        guard data.count <= 4096, allocated + data.count <= 65536 else {
            active = false; lock.unlock(); onFailure(); return false
        }
        allocated += data.count; lock.unlock()
        queue.async { [self] in
            let success = write(data)
            lock.lock(); allocated -= data.count
            let failed = !success && active
            if failed { active = false }
            lock.unlock()
            if failed { onFailure() }
        }
        return true
    }
    private func write(_ data: Data) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                lock.lock(); let enabled = active; lock.unlock()
                guard enabled else { return false }
                let count = Darwin.write(descriptor.value, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK),
                      ProcessInfo.processInfo.systemUptime < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.005) // Background queue only; never the safety actor.
            }
            return true
        }
    }
    func close() {
        lock.lock(); active = false; lock.unlock()
        let descriptor = descriptor
        queue.async { descriptor.close() }
    }
}
