import Foundation

/// Tracks OS transmit completions, not Samsung protocol acknowledgments.
/// Tokens are never reused by a reset, so late completions cannot clear new work.
struct NativeBudsWriteTracker {
    static let capacity = 32
    static let timeout: TimeInterval = 5
    private var next: UInt = 0
    private var pending: [UInt: TimeInterval] = [:]
    var count: Int { pending.count }
    mutating func enqueue(at now: TimeInterval) -> UInt? {
        guard pending.count < Self.capacity, next != UInt.max else { return nil }
        next += 1
        pending[next] = now
        return next
    }
    @discardableResult mutating func complete(_ token: UInt) -> Bool {
        pending.removeValue(forKey: token) != nil
    }
    func expired(at now: TimeInterval) -> Bool {
        pending.values.contains { now >= $0 && now - $0 >= Self.timeout }
    }
    mutating func reset() { pending.removeAll() }
}
