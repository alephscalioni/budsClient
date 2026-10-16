import Foundation

/// Retains SDK callback targets independently of controller/transport lifetime.
/// Completing an orphan runs its resource cleanup exactly once; ordinary
/// completion leaves an active channel under its transport's ownership.
@MainActor final class NativeBudsOperationDrain {
    static let shared = NativeBudsOperationDrain()
    private struct Entry {
        let resource: AnyObject
        let orphanCleanup: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    var count: Int { entries.count }
    func retain(_ resource: AnyObject, id: UUID, orphanCleanup: @escaping () -> Void) {
        precondition(entries[id] == nil)
        entries[id] = Entry(resource: resource, orphanCleanup: orphanCleanup)
    }
    @discardableResult func complete(_ id: UUID, orphaned: Bool) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        if orphaned { entry.orphanCleanup() }
        return true
    }
}
