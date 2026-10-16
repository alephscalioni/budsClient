import XCTest
@testable import BudsAutoSwitch

@MainActor final class NativeSerialChannelWriterTests: XCTestCase {
    private final class Channel {}
    private final class Queue {
        var jobs: [() -> Void] = []
        func next() { jobs.removeFirst()() }
    }

    func testLateConfirmedCloseRetiresOnlyItsLeaseAfterWorkerDeadline() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        var settle: (@MainActor () -> Void)?
        let registered = expectation(description: "Awaiting actual close")
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, _ in 0 }, close: { _ in -1 }, drain: drain,
            settleClose: { candidate, completion in
                XCTAssertTrue(candidate === channel)
                settle = completion; registered.fulfill()
            })
        writer.close(channel)
        queue.next()
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(drain.count, 1)
        XCTAssertNil(writer.send(Data([1]), channel: channel, retaining: nil, deadline: .infinity) { _, _ in XCTFail() })
        settle?()
        XCTAssertEqual(drain.count, 0)
        settle?() // Duplicate receipt cannot complete a replacement lease.
        XCTAssertEqual(drain.count, 0)
    }

    func testCancelledQueuedWriteNeverInvokesSDK() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        var calls = 0
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, _ in calls += 1; return 0 }, close: { _ in 0 }, drain: drain, now: { 10 })
        let done = expectation(description: "cancelled result drained")
        let invocation = writer.send(Data([1, 2, 3]), channel: channel, retaining: nil, deadline: 15) { status, _ in
            XCTAssertNotEqual(status, 0); done.fulfill()
        }
        XCTAssertEqual(drain.count, 1)
        invocation?.cancel()
        queue.next()
        XCTAssertEqual(calls, 0)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(drain.count, 0)
    }

    func testLateHardwareSuccessCannotConfirmExpiredWrite() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        var now: TimeInterval = 10
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, bytes in XCTAssertEqual(Data(referencing: bytes), Data([4, 5])); now = 16; return 0 },
            close: { _ in 0 }, drain: drain, now: { now })
        let done = expectation(description: "late result rejected")
        writer.send(Data([4, 5]), channel: channel, retaining: nil, deadline: 15) { status, count in
            XCTAssertNotEqual(status, 0); XCTAssertEqual(count, 2); done.fulfill()
        }
        queue.next()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(drain.count, 0)
    }

    func testToolCleanupStopQueuedBehindSlowStartStillEntersSDKAfterOrdinaryDeadline() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        var now: TimeInterval = 10, sent: [UInt8] = []
        let done = expectation(description: "Both protected SDK invocations settle"); done.expectedFulfillmentCount = 2
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, bytes in
                let command = Data(referencing: bytes)[0]; sent.append(command)
                if command == 0xA6 { now = 40 } // Start returns after the ordinary five-second timeout.
                return 0
            }, close: { _ in 0 }, drain: drain, now: { now })
        writer.send(Data([0xA6]), channel: channel, retaining: nil, deadline: .greatestFiniteMagnitude) { status, _ in
            XCTAssertEqual(status, 0); done.fulfill()
        }
        now = 13 // Independent helper deadline queues stop while start is pending.
        writer.send(Data([0xA1]), channel: channel, retaining: nil, deadline: .greatestFiniteMagnitude) { status, _ in
            XCTAssertEqual(status, 0); done.fulfill()
        }
        queue.next(); queue.next()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(sent, [0xA6, 0xA1]); XCTAssertEqual(drain.count, 0)
    }

    func testCloseDuringRunningWriteRetainsResourcesAndWaitsForReturn() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        var retained: NSObject? = NSObject()
        weak var weakRetained = retained
        var closes = 0
        var writer: NativeSerialChannelWriter<Channel>!
        writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) }, write: { _, bytes in
            writer.close(channel)
            XCTAssertNotNil(weakRetained)
            XCTAssertEqual(closes, 0)
            XCTAssertEqual(Data(referencing: bytes), Data([7, 8, 9]))
            return 0
        }, close: { _ in closes += 1; return 0 }, drain: drain, now: { 10 })
        let done = expectation(description: "retired write result")
        writer.send(Data([7, 8, 9]), channel: channel, retaining: retained, deadline: 15) { status, _ in
            XCTAssertNotEqual(status, 0); done.fulfill()
        }
        retained = nil
        queue.next() // The write requests close while actually executing.
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(drain.count, 2)
        XCTAssertNil(writer.send(Data([10]), channel: channel, retaining: nil, deadline: 15) { _, _ in XCTFail() })
        queue.next() // Only now may the SDK close run.
        await fulfillment(of: [done], timeout: 1)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(drain.count, 0)
        XCTAssertNil(weakRetained)
    }

    func testUncertainCloseKeepsDrainAndRejectsReplacementWrites() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), channel = Channel()
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, _ in XCTFail("must not write after close"); return 0 }, close: { _ in -1 }, drain: drain)
        writer.close(channel)
        queue.next()
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(drain.count, 1)
        XCTAssertNil(writer.send(Data([1]), channel: channel, retaining: nil, deadline: .infinity) { _, _ in XCTFail() })
    }

    func testDifferentChannelsCannotConsumeEachOthersLateResults() async {
        let queue = Queue(), drain = NativeBudsOperationDrain(), old = Channel(), next = Channel()
        let writer = NativeSerialChannelWriter<Channel>(enqueue: { queue.jobs.append($0) },
            write: { _, _ in 0 }, close: { _ in 0 }, drain: drain, now: { 10 })
        let retired = expectation(description: "old write retired"), current = expectation(description: "current write completed")
        writer.send(Data([1]), channel: old, retaining: nil, deadline: 15) { status, _ in
            XCTAssertNotEqual(status, 0); retired.fulfill()
        }
        writer.close(old)
        writer.send(Data([2]), channel: next, retaining: nil, deadline: 15) { status, count in
            XCTAssertEqual(status, 0); XCTAssertEqual(count, 1); current.fulfill()
        }
        while !queue.jobs.isEmpty { queue.next() }
        await fulfillment(of: [retired, current], timeout: 1)
        XCTAssertEqual(drain.count, 0)
    }
}

final class NativeSDKSerialExecutorTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var rows: [String] = []
        func add(_ row: String) { lock.lock(); rows.append(row); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return rows }
    }
    func testNestedRunLoopDoesNotReenterSDKAndMainRemainsAvailable() async {
        let executor = NativeSDKSerialExecutor(name: "Buds.UnitTest.SDK"), log = Log()
        let done = expectation(description: "second SDK job completed")
        executor.submit {
            XCTAssertFalse(Thread.isMainThread)
            log.add("first-start")
            executor.submit { log.add("second"); done.fulfill() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            log.add("first-end")
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(log.snapshot, ["first-start", "first-end", "second"])
    }
    func testInvocationCancellationAndDeadlineFenceSDKEntry() {
        let cancelled = NativeSDKInvocation(deadline: 15)
        cancelled.cancel()
        XCTAssertFalse(cancelled.claim(at: 10))
        let expired = NativeSDKInvocation(deadline: 15)
        XCTAssertFalse(expired.claim(at: 15))
        let running = NativeSDKInvocation(deadline: 15)
        XCTAssertTrue(running.claim(at: 10))
        XCTAssertFalse(running.claim(at: 11))
        running.cancel()
        XCTAssertFalse(running.acceptsCompletion(at: 12))
    }
}
