import XCTest
@testable import BudsAutoSwitch

final class NativeBudsLinkEventStreamTests: XCTestCase {
    private func readyStream() -> NativeBudsLinkEventStream {
        var stream = NativeBudsLinkEventStream()
        XCTAssertTrue(stream.append(Data("{\"event\":\"ready\",\"uptime\":4}\n".utf8), now: 10).isEmpty)
        XCTAssertTrue(stream.ready)
        return stream
    }
    private func line(_ sequence: Int, _ connected: Bool, _ at: Int) -> Data {
        Data("{\"event\":\"link\",\"sequence\":\(sequence),\"connected\":\(connected),\"uptime\":\(at)}\n".utf8)
    }
    func testSplitAndCoalescedFactsPreserveCapturedOrderAndTime() {
        var stream = readyStream()
        let first = line(1, true, 5)
        XCTAssertTrue(stream.append(Data(first.prefix(9)), now: 10).isEmpty)
        let samples = stream.append(Data(first.dropFirst(9)) + line(2, false, 6) + line(3, true, 6), now: 10)
        XCTAssertEqual(samples, [.init(connected: true, at: 5), .init(connected: false, at: 6), .init(connected: true, at: 6)])
        XCTAssertFalse(stream.failed)
    }
    func testDuplicateRegressingAndFutureFactsStopTheStreamWithoutInventingDisconnection() {
        for bad in [line(1, false, 6), line(2, false, 4), line(2, false, 11)] {
            var stream = readyStream()
            XCTAssertEqual(stream.append(line(1, true, 5), now: 10).count, 1)
            XCTAssertTrue(stream.append(bad, now: 10).isEmpty)
            XCTAssertTrue(stream.failed)
            XCTAssertTrue(stream.append(line(3, false, 7), now: 10).isEmpty)
        }
    }
    func testMalformedBooleanOrderTimeAndUnknownEventsAreRejected() {
        let good = String(decoding: line(1, true, 5), as: UTF8.self)
        for text in [good.replacingOccurrences(of: ":true", with: ":1"),
                     good.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":true"),
                     good.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":1.5"),
                     good.replacingOccurrences(of: "\"uptime\":5", with: "\"uptime\":true"),
                     good.replacingOccurrences(of: "\"link\"", with: "\"other\""), "bad\n"] {
            var stream = readyStream()
            XCTAssertTrue(stream.append(Data(text.utf8), now: 10).isEmpty)
            XCTAssertTrue(stream.failed)
        }
    }
    func testUnterminatedOversizedAndOversizedReadBlocksAreBounded() {
        for size in [4097, 65537] {
            var stream = readyStream()
            XCTAssertTrue(stream.append(Data(repeating: 65, count: size), now: 10).isEmpty)
            XCTAssertTrue(stream.failed)
        }
    }
    func testFactsBeforeReadinessOrDuplicateReadinessCannotBeAccepted() {
        var early = NativeBudsLinkEventStream()
        XCTAssertTrue(early.append(line(1, true, 5), now: 10).isEmpty)
        XCTAssertTrue(early.failed)
        var duplicate = readyStream()
        XCTAssertTrue(duplicate.append(Data("{\"event\":\"ready\",\"uptime\":5}\n".utf8), now: 10).isEmpty)
        XCTAssertTrue(duplicate.failed)
    }

    @MainActor func testBaselineWaitsForReadinessAndFailureCannotBeReopenedByLateReady() async throws {
        let gate = NativeBudsLinkReadiness()
        var started = false, passed = false
        let task = Task {
            started = true
            try await gate.wait()
            passed = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(started); XCTAssertFalse(passed)
        gate.resolve(true)
        try await task.value
        XCTAssertTrue(passed)
        gate.resolve(false); gate.resolve(true)
        do { try await gate.wait(); XCTFail("Retired helper must not resume the baseline") } catch {}
    }

    @MainActor func testCancelledOrExpiredReadinessNeverStartsTheBaseline() async {
        for cancel in [true, false] {
            let gate = NativeBudsLinkReadiness()
            let task = Task { try await gate.wait(sleep: {
                if cancel { try await Task.sleep(for: .seconds(60)) }
            }) }
            for _ in 0..<20 { await Task.yield() }
            if cancel { task.cancel() }
            do { try await task.value; XCTFail("No successful registration") } catch {}
            gate.resolve(true)
            do { try await gate.wait(); XCTFail("Late ready must not revive failure") } catch {}
        }
    }
}
