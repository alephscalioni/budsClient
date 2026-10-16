import XCTest
@testable import BudsAutoSwitch

final class NativeBudsSettingsProcessTests: XCTestCase {
    @MainActor func testClosingToolChildWaitsForRealCleanupInsteadOfKillingAtNormalSettingsTimeout() async throws {
        let executable = try helper("""
        def emit(x): print(json.dumps(x),flush=True)
        emit({'event':'frame','command':97,'payload':'AQID','uptime':time.monotonic(),'observed_at':time.time()})
        emit({'event':'opened'})
        for line in sys.stdin:
            x=json.loads(line)
            if x['event']=='write': emit({'event':'written','id':x['id']})
            elif x['event']=='close':
                time.sleep(3.1)
                break
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let drain = NativeBudsOperationDrain(), process = NativeBudsSettingsProcess(helper: executable, drain: drain)
        try await process.open(address: "AA:BB:CC:DD:EE:FF")
        _ = try process.sendTracked(SamsungBudsSettingsPacket.frame(command: 0xA6, payload: []))
        process.close()
        XCTAssertGreaterThan(drain.count, 0)
        try await Task.sleep(for: .seconds(2.7))
        XCTAssertGreaterThan(drain.count, 0, "Tool cleanup must survive the ordinary 2.5-second child kill deadline")
        await settle(drain)
    }
    private func helper(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("buds-fake-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("helper")
        try ("#!/usr/bin/env python3\nimport json,sys,time,base64\n" + body).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }
    @MainActor private func settle(_ drain: NativeBudsOperationDrain) async {
        for _ in 0..<250 where drain.count != 0 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(drain.count, 0, "Actual child exit must retire its own operation")
    }
    private let normal = """
    def emit(x): print(json.dumps(x),flush=True)
    def frame(): emit({'event':'frame','command':97,'payload':'AQID','uptime':time.monotonic(),'observed_at':time.time()})
    frame()
    emit({'event':'opened'})
    for line in sys.stdin:
        value=json.loads(line)
        if value['event']=='write': emit({'event':'written','id':value['id']})
        elif value['event']=='close':
            frame()
            emit({'event':'written','id':999})
            break
    """

    @MainActor func testRepeatedProcessesBufferBootstrapAndKeepLateClosingFramesFenced() async throws {
        let executable = try helper(normal)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let drain = NativeBudsOperationDrain(), transport = NativeBudsSettingsProcess(helper: executable, drain: drain)
        var received = 0
        transport.onSettingsFrame = { frame in
            XCTAssertFalse(transport.isOpen, "Bootstrap precedes the opened receipt")
            XCTAssertEqual(frame.command, 97); received += 1
        }
        transport.onFailure = { error in XCTFail(error.message) }
        for attempt in 1...3 {
            try await transport.open(address: "AA:BB:CC:DD:EE:FF")
            XCTAssertTrue(transport.isOpen); XCTAssertEqual(received, attempt)
            transport.close()
            await settle(drain)
            XCTAssertFalse(transport.isOpen); XCTAssertEqual(received, attempt)
        }
    }

    @MainActor func testWriteCompletionUsesOnlyTheCurrentRequestAndRejectsUnrelatedCommands() async throws {
        let executable = try helper(normal)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let drain = NativeBudsOperationDrain(), transport = NativeBudsSettingsProcess(helper: executable, drain: drain)
        transport.onFailure = { error in XCTFail(error.message) }
        try await transport.open(address: "AA:BB:CC:DD:EE:FF")
        let completed = expectation(description: "Mock SDK write completed, no Bluetooth")
        var id: UInt = 0
        transport.onWriteComplete = { value in XCTAssertEqual(value, id); completed.fulfill() }
        XCTAssertThrowsError(try transport.sendTracked(SamsungBudsSettingsPacket.frame(command: 0x88, payload: [1, 1, 34])))
        id = try transport.sendTracked(SamsungBudsSettingsPacket.frame(command: 0x78, payload: [0]))
        await fulfillment(of: [completed], timeout: 2)
        transport.close(); await settle(drain)
    }

    @MainActor func testCancellationDuringOpenRetainsDrainUntilActualChildExit() async throws {
        let executable = try helper("import signal\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\ntime.sleep(10)\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let drain = NativeBudsOperationDrain(), transport = NativeBudsSettingsProcess(helper: executable, drain: drain)
        let opening = Task { try await transport.open(address: "AA:BB:CC:DD:EE:FF") }
        for _ in 0..<100 where drain.count == 0 { await Task.yield() }
        XCTAssertEqual(drain.count, 1)
        transport.close()
        do { try await opening.value; XCTFail("Cancelled open cannot become ready") } catch {}
        XCTAssertFalse(transport.isOpen); XCTAssertEqual(drain.count, 1)
        await settle(drain)
    }

    func testWireBoundsNumbersAndWriteAllowlist() throws {
        XCTAssertNil(NativeBudsSettingsWire.integer(true))
        XCTAssertNil(NativeBudsSettingsWire.integer(-1))
        XCTAssertNil(NativeBudsSettingsWire.integer(1.5))
        XCTAssertNil(NativeBudsSettingsWire.integer(NSNumber(value: 9_007_199_254_740_992 as UInt64)))
        XCTAssertNil(NativeBudsSettingsWire.number(true))
        XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x61, payload: [])))
        XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x78, payload: [99])))
        XCTAssertTrue(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x78, payload: [0])))
        var lines = NativeBudsSettingsWire.Lines()
        let data = try NativeBudsSettingsWire.encode(["event": "close"])
        XCTAssertTrue(try lines.append(Data(data.prefix(3))).isEmpty)
        XCTAssertEqual(try lines.append(Data(data.dropFirst(3))).first?["event"] as? String, "close")
        XCTAssertThrowsError(try lines.append(Data(repeating: 65, count: 4097)))
        XCTAssertNil(NativeBudsSettingsWire.frame(["command": 242, "payload": ""]))
    }
    @MainActor func testLaunchFailureAndEarlyEOFAreReportedThroughOpenOnly() async throws {
        let executable = try helper("sys.exit(1)\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        for path in [executable, executable.deletingLastPathComponent().appendingPathComponent("missing")] {
            let drain = NativeBudsOperationDrain(), transport = NativeBudsSettingsProcess(helper: path, drain: drain)
            transport.onFailure = { _ in XCTFail("Opening failure must use its awaiting caller only") }
            do { try await transport.open(address: "AA:BB:CC:DD:EE:FF"); XCTFail("Expected opening failure") } catch {}
            await settle(drain)
            XCTAssertFalse(transport.isOpen)
        }
    }
    @MainActor func testUnexpectedExitAfterOpenReportsFailureOnce() async throws {
        let executable = try helper("print(json.dumps({'event':'opened'}),flush=True)\ntime.sleep(0.2)\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let drain = NativeBudsOperationDrain(), transport = NativeBudsSettingsProcess(helper: executable, drain: drain)
        let failed = expectation(description: "Ended active session")
        failed.assertForOverFulfill = true
        transport.onFailure = { _ in failed.fulfill() }
        try await transport.open(address: "AA:BB:CC:DD:EE:FF")
        await fulfillment(of: [failed], timeout: 2)
        await settle(drain)
        XCTAssertFalse(transport.isOpen)
    }
}
