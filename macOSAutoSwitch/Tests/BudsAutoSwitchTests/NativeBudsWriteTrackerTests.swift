import XCTest
@testable import BudsAutoSwitch

final class NativeBudsWriteTrackerTests: XCTestCase {
    func testQueueIsBoundedAndOnlyKnownCompletionFreesCapacity() throws {
        var queue = NativeBudsWriteTracker()
        let ids = try (0..<32).map { _ in try XCTUnwrap(queue.enqueue(at: 1)) }
        XCTAssertEqual(Set(ids).count, 32)
        XCTAssertNil(queue.enqueue(at: 1))
        XCTAssertFalse(queue.complete(0))
        XCTAssertNil(queue.enqueue(at: 1))
        XCTAssertTrue(queue.complete(ids[7]))
        XCTAssertNotNil(queue.enqueue(at: 2))
        XCTAssertFalse(queue.complete(ids[7]), "Duplicate completion cannot clear another packet")
    }
    func testOldestUncompletedWriteOwnsDeadline() throws {
        var queue = NativeBudsWriteTracker()
        let first = try XCTUnwrap(queue.enqueue(at: 10))
        let second = try XCTUnwrap(queue.enqueue(at: 12))
        XCTAssertFalse(queue.expired(at: 9))
        XCTAssertFalse(queue.expired(at: 14.99))
        XCTAssertTrue(queue.expired(at: 15))
        queue.complete(first)
        XCTAssertFalse(queue.expired(at: 15))
        XCTAssertTrue(queue.expired(at: 17))
        queue.complete(second)
        XCTAssertFalse(queue.expired(at: 1000))
    }
    func testResetInvalidatesOldTokensWithoutReusingThem() throws {
        var queue = NativeBudsWriteTracker()
        let old = try XCTUnwrap(queue.enqueue(at: 0))
        queue.reset()
        let new = try XCTUnwrap(queue.enqueue(at: 1))
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(queue.complete(old))
        XCTAssertEqual(queue.count, 1)
        XCTAssertTrue(queue.complete(new))
    }
}
