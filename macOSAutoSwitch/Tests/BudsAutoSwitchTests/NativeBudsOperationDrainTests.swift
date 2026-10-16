import XCTest
@testable import BudsAutoSwitch

@MainActor private final class WeakSDKTarget {
    weak var value: NSObject?
    init(_ value: NSObject?) { self.value = value }
}

final class NativeBudsOperationDrainTests: XCTestCase {
    @MainActor func testSDKTargetSurvivesOwnerReleaseUntilOrphanCompletion() {
        let drain = NativeBudsOperationDrain()
        var target: NSObject? = NSObject()
        let weakTarget = WeakSDKTarget(target)
        let id = UUID()
        var orphanCleanups = 0
        drain.retain(target!, id: id) { orphanCleanups += 1 }
        target = nil
        XCTAssertNotNil(weakTarget.value, "An async SDK callback target must outlive the transport")
        XCTAssertEqual(drain.count, 1)
        XCTAssertTrue(drain.complete(id, orphaned: true))
        XCTAssertEqual(orphanCleanups, 1)
        XCTAssertNil(weakTarget.value)
        XCTAssertFalse(drain.complete(id, orphaned: true))
        XCTAssertEqual(orphanCleanups, 1)
    }

    @MainActor func testNormalCompletionDoesNotCloseResourcesOwnedByActiveTransport() {
        let drain = NativeBudsOperationDrain()
        let id = UUID()
        var orphanCleanups = 0
        drain.retain(NSObject(), id: id) { orphanCleanups += 1 }
        XCTAssertFalse(drain.complete(UUID(), orphaned: true))
        XCTAssertEqual(drain.count, 1)
        XCTAssertTrue(drain.complete(id, orphaned: false))
        XCTAssertEqual(orphanCleanups, 0)
        XCTAssertEqual(drain.count, 0)
    }
}
