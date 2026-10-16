import XCTest
import Darwin
@testable import BudsAutoSwitch

final class NativeBudsToolLifecycleTests: XCTestCase {
    @MainActor func testOwnerLossCleanupKeepsPumpingBeforeHelperMainCanReturn() {
        var stopped = false
        Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { _ in
            MainActor.assumeIsolated { stopped = true }
        }
        let started = ProcessInfo.processInfo.systemUptime
        NativeBudsSettingsHelper.drainCleanup { stopped }
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.035)
    }

    @MainActor func testBackpressuredOutputCannotBlockSafetyActorAndReportsFailureOnce() async throws {
        let pipe = Pipe()
        let failed = expectation(description: "Bounded output refuses a stalled reader")
        failed.assertForOverFulfill = true
        let output = try NativeBudsSettingsOutput(fd: pipe.fileHandleForWriting.fileDescriptor) { failed.fulfill() }
        defer { output.close(); try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        for _ in 0..<100 { output.enqueue(Data(repeating: 65, count: 4096)) }
        var timerRan = false
        Task { @MainActor in timerRan = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(timerRan, "Output backpressure must not own MainActor")
        await fulfillment(of: [failed], timeout: 1)
    }

    @MainActor func testAsynchronousOutputKeepsLineOrderWithoutUsingBlockingMainActorWrites() async throws {
        let pipe = Pipe(), failed = expectation(description: "No output failure")
        failed.isInverted = true
        let output = try NativeBudsSettingsOutput(fd: pipe.fileHandleForWriting.fileDescriptor) { failed.fulfill() }
        defer { output.close(); try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL); XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(fd, F_SETFL, flags | O_NONBLOCK), 0)
        XCTAssertTrue(output.enqueue(Data("first\n".utf8)))
        XCTAssertTrue(output.enqueue(Data("second\n".utf8)))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 256)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while data.count < 13 && ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "first\nsecond\n")
        XCTAssertFalse(output.pending)
        await fulfillment(of: [failed], timeout: 0.05)
    }
}
