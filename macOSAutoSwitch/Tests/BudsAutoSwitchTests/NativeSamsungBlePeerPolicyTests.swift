import XCTest
@testable import BudsAutoSwitch

final class NativeSamsungBlePeerPolicyTests: XCTestCase {
    typealias P = NativeSamsungBlePeerPolicy
    typealias R = NativeSamsungBlePeerDiagnostics.Reason
    func discovering(_ p: inout P, now: TimeInterval = 0) throws {
        XCTAssertEqual(try p.begin(now: now), [.initializeCentral])
        XCTAssertEqual(try p.power(true, now: now), [.scan])
    }
    func connecting(_ p: inout P, peripheral: UUID = UUID(), now: TimeInterval = 0) throws -> NativeSamsungBlePeerLease {
        try discovering(&p, now: now)
        let effects = try p.connect(peripheral: peripheral, psm: 0x82, now: now)
        guard case .connect(let lease) = effects.last else { throw R.invalidState }
        return lease
    }
    func opening(_ p: inout P, peripheral: UUID = UUID(), now: TimeInterval = 0) throws -> NativeSamsungBlePeerLease {
        let lease = try connecting(&p, peripheral: peripheral, now: now)
        XCTAssertEqual(try p.connected(lease, now: now + 1), [.open(lease, 0x82)])
        return lease
    }
    func testLazyStartAndPowerOnlyScanning() throws {
        var p = try P(); XCTAssertEqual(p.phase, .idle); XCTAssertNil(p.active)
        XCTAssertEqual(try p.begin(now: 0), [.initializeCentral]); XCTAssertEqual(p.phase, .waitingForPower)
        XCTAssertEqual(try p.power(false, now: 1), [.stopScan]); XCTAssertEqual(p.reason, .unavailable)
        try discovering(&p, now: 2)
        XCTAssertEqual(try p.power(true, now: 3), [])
    }
    func testDiscoveryAndPowerDeadlinesAtExactEdge() throws {
        for power in [false, true] {
            var p = try P(); _ = try p.begin(now: 0)
            if power { _ = try p.power(true, now: 0) }
            XCTAssertEqual(try p.poll(now: 14.999), [])
            XCTAssertEqual(try p.poll(now: 15), [.stopScan]); XCTAssertEqual(p.reason, .discoveryDeadline)
        }
        var p = try P(); try discovering(&p)
        XCTAssertEqual(try p.connect(peripheral: UUID(), psm: 0x80, now: 15), [.stopScan])
        XCTAssertNil(p.active)
    }
    func testConnectDeadlineRetainsDrainUntilAcknowledgement() throws {
        var p = try P(); let lease = try connecting(&p)
        XCTAssertEqual(try p.poll(now: 10), [.stopScan, .cancel(lease)])
        XCTAssertTrue(p.isDraining(lease.peripheral)); XCTAssertEqual(p.phase, .cancelling)
        XCTAssertEqual(try p.connected(lease, now: 11), [])
        XCTAssertEqual(p.stop(), [.stopScan]) // no repeated cancellation
        XCTAssertEqual(p.terminal(lease), []); XCTAssertFalse(p.isDraining(lease.peripheral))
        XCTAssertEqual(p.phase, .closed)
    }
    func testConnectedCallbackAtDeadlineCannotOpenChannel() throws {
        var p = try P(); let lease = try connecting(&p)
        XCTAssertEqual(try p.connected(lease, now: 10), [.stopScan, .cancel(lease)])
    }
    func testOpenDeadlineAndLateSuccessCloseOnlyReturnedStreams() throws {
        var p = try P(); let lease = try opening(&p)
        XCTAssertEqual(try p.poll(now: 11), [.stopScan, .cancel(lease)])
        let stream = UUID()
        XCTAssertEqual(try p.opened(lease, stream: stream, psm: 0x82, now: 12), [.closeStream(stream)])
        XCTAssertTrue(p.isDraining(lease.peripheral))
        _ = p.terminal(lease); XCTAssertFalse(p.isDraining(lease.peripheral))
    }
    func testCancelAckBeforePendingOpenStillBlocksSamePeripheral() throws {
        var p = try P(); let lease = try opening(&p)
        _ = p.stop(); _ = p.terminal(lease)
        try discovering(&p, now: 2)
        XCTAssertThrowsError(try p.connect(peripheral: lease.peripheral, psm: 0x80, now: 2)) {
            XCTAssertEqual($0 as? R, .peerDraining)
        }
        let staleStream = UUID()
        XCTAssertEqual(try p.opened(lease, stream: staleStream, psm: 0x82, now: 3), [.closeStream(staleStream)])
        XCTAssertFalse(p.isDraining(lease.peripheral))
        XCTAssertNoThrow(try p.connect(peripheral: lease.peripheral, psm: 0x80, now: 3))
    }
    func testLateOldGenerationCannotCloseOrCancelNewChannel() throws {
        var p = try P(); let old = try opening(&p)
        _ = p.stop(); _ = p.terminal(old)
        let newer = try connecting(&p, now: 2)
        _ = try p.connected(newer, now: 3)
        let currentStream = UUID()
        XCTAssertEqual(try p.opened(newer, stream: currentStream, psm: 0x82, now: 4), [.ready(newer, currentStream)])
        let late = UUID()
        XCTAssertEqual(try p.opened(old, stream: late, psm: 0x82, now: 5), [.closeStream(late)])
        XCTAssertTrue(p.owns(newer, stream: currentStream)); XCTAssertEqual(p.terminal(old), [])
        XCTAssertEqual(try p.connected(old, now: 6), [])
        XCTAssertEqual(p.active, newer); XCTAssertEqual(p.phase, .channelOpen)
    }
    func testStaleInvalidClockNeverMutatesNewGeneration() throws {
        var p = try P(); let old = try opening(&p)
        _ = p.stop(); _ = p.terminal(old)
        let current = try connecting(&p, now: 20)
        XCTAssertEqual(try p.connected(old, now: .nan), [])
        let staleStream = UUID()
        XCTAssertEqual(try p.opened(old, stream: staleStream, psm: 0x82, now: -.infinity), [.closeStream(staleStream)])
        XCTAssertEqual(p.active, current); XCTAssertEqual(p.phase, .connecting); XCTAssertNil(p.reason)
        XCTAssertEqual(try p.connected(current, now: 21), [.open(current, 0x82)])
    }
    func testReconnectionAfterFullyDrainedSamePeripheralHasNewGeneration() throws {
        var p = try P(); let old = try connecting(&p)
        _ = p.stop(); _ = p.terminal(old)
        let new = try connecting(&p, peripheral: old.peripheral, now: 1)
        XCTAssertEqual(new.peripheral, old.peripheral); XCTAssertNotEqual(new.generation, old.generation)
        XCTAssertEqual(p.terminal(old), []); XCTAssertEqual(p.active, new)
    }
    func testOpenCancellationCallbackPermutations() throws {
        for ackFirst in [true, false] {
            var p = try P(); let lease = try opening(&p)
            _ = p.stop()
            if ackFirst { _ = p.terminal(lease) }
            let late = UUID()
            XCTAssertEqual(try p.opened(lease, stream: late, psm: 0x82, now: 2), [.closeStream(late)])
            if !ackFirst { XCTAssertTrue(p.isDraining(lease.peripheral)); _ = p.terminal(lease) }
            XCTAssertFalse(p.isDraining(lease.peripheral)); XCTAssertEqual(p.phase, .closed)
        }
    }
    func testPumpWorkBoundAndLargePartialWritesPreserveOrder() throws {
        var b = try NativeSamsungBlePeerStreamBuffer()
        let bytes = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        try b.enqueue(bytes)
        var written = Data(), calls = 0
        try b.pump(hasSpace: { true }) { offered in
            XCTAssertLessThanOrEqual(offered.count, 4096); calls += 1
            written.append(offered.prefix(1)); return 1
        }
        XCTAssertEqual(calls, 16); XCTAssertEqual(b.pendingWriteBytes, 65_520)
        while b.pendingWriteBytes > 0 {
            try b.pump(hasSpace: { true }) { offered in
                let count = min(137, offered.count); written.append(offered.prefix(count)); return count
            }
        }
        XCTAssertEqual(written, bytes)
    }
    func testUnknownCallbackAndDuplicateCurrentStream() throws {
        var p = try P(); let lease = try opening(&p); let stream = UUID()
        _ = try p.opened(lease, stream: stream, psm: 0x82, now: 2)
        XCTAssertEqual(try p.opened(lease, stream: stream, psm: 0x82, now: 3), [])
        let foreign = NativeSamsungBlePeerLease(generation: 999, peripheral: UUID()), orphan = UUID()
        XCTAssertEqual(try p.opened(foreign, stream: orphan, psm: 0x82, now: 4), [.closeStream(orphan)])
        XCTAssertTrue(p.owns(lease, stream: stream))
        XCTAssertEqual(try p.poll(now: 999), []) // stream has no discovery/open timeout
        XCTAssertEqual(p.stop(), [.stopScan, .closeStream(stream), .cancel(lease)])
        XCTAssertTrue(p.isDraining(lease.peripheral))
    }
    func testNilWrongPSMAndLateAtExactDeadline() throws {
        for mode in 0..<3 {
            var p = try P(); let lease = try opening(&p); let stream = mode == 0 ? nil : UUID()
            let effects = try p.opened(lease, stream: stream, psm: mode == 1 ? 0x81 : 0x82, now: mode == 2 ? 11 : 2)
            XCTAssertEqual(effects, (stream.map { [.closeStream($0)] } ?? []) + [.stopScan, .cancel(lease)])
            XCTAssertEqual(p.reason, mode == 2 ? .channelDeadline : .channelFailed)
        }
    }
    func testTerminalStreamClosesExactlyOwnedChannelAndFailureReason() throws {
        var p = try P(); let lease = try opening(&p); let stream = UUID()
        _ = try p.opened(lease, stream: stream, psm: 0x82, now: 2)
        XCTAssertEqual(p.terminal(lease), [.closeStream(stream)])
        XCTAssertEqual(p.reason, .disconnected); XCTAssertEqual(p.terminal(lease), [])
        let next = try connecting(&p, now: 3)
        XCTAssertEqual(p.terminal(next, failedToConnect: true), [])
        XCTAssertEqual(p.reason, .connectionFailed)
    }
    func testClockAndConfigurationRejections() throws {
        for bad in [Double.nan, .infinity, -1] { var p = try P(); XCTAssertThrowsError(try p.begin(now: bad)) }
        var p = try P(); _ = try p.begin(now: 5)
        XCTAssertThrowsError(try p.poll(now: 4)); XCTAssertEqual(try p.poll(now: 5), [])
        XCTAssertThrowsError(try P(budgets: .init(discovery: 0)))
        XCTAssertThrowsError(try P(budgets: .init(connect: 61)))
        XCTAssertThrowsError(try P(budgets: .init(channel: .nan)))
        var q = try P(); try discovering(&q)
        for bad: UInt16 in [0, 1, 0x7f, 0x100, 0x1001, 0xffff] {
            XCTAssertThrowsError(try q.connect(peripheral: UUID(), psm: bad, now: 0))
        }
    }
    func testWritePartialZeroBackpressureAndOwnership() throws {
        var b = try NativeSamsungBlePeerStreamBuffer(limit: 16)
        var original = Data([1, 2, 3, 4, 5]); try b.enqueue(original); original[0] = 99
        var written = Data(), calls = 0
        try b.pump(hasSpace: { true }) { offered in
            calls += 1
            if calls == 2 { return 0 }
            let n = min(2, offered.count); written.append(offered.prefix(n)); return n
        }
        XCTAssertEqual(written, Data([1, 2])); XCTAssertEqual(b.pendingWriteBytes, 3)
        try b.pump(hasSpace: { false }) { _ in XCTFail(); return 0 }
        XCTAssertEqual(b.pendingWriteBytes, 3)
        try b.pump(hasSpace: { true }) { offered in written.append(offered.prefix(1)); return 1 }
        XCTAssertEqual(written, Data([1, 2, 3, 4, 5])); XCTAssertEqual(b.pendingWriteBytes, 0)
    }
    func testWriteAndReceiveBoundsAndBadWriterResults() throws {
        for bad in [-1, 5] {
            var b = try NativeSamsungBlePeerStreamBuffer(limit: 4); try b.enqueue(Data([1, 2, 3, 4]))
            XCTAssertThrowsError(try b.enqueue(Data([5])))
            XCTAssertEqual(b.pendingWriteBytes, 4)
            XCTAssertThrowsError(try b.pump(hasSpace: { true }, write: { _ in bad }))
        }
        var b = try NativeSamsungBlePeerStreamBuffer(limit: 4)
        try b.receive(Data([1, 2])); try b.receive(Data([3, 4])); XCTAssertThrowsError(try b.receive(Data([5])))
        XCTAssertEqual(b.takeReceived(maximum: 0), Data()); XCTAssertEqual(b.pendingReadBytes, 4)
        XCTAssertEqual(b.takeReceived(maximum: 3), Data([1, 2, 3]))
        XCTAssertEqual(b.takeReceived(), Data([4])); XCTAssertEqual(b.pendingReadBytes, 0)
        XCTAssertThrowsError(try NativeSamsungBlePeerStreamBuffer(limit: 0))
    }
    func testAllProtobufStreamFragmentEdges() throws {
        let packet = SamsungPeerWire.Packet(handlerID: 0, payload: Data(repeating: 0x81, count: 256), authType: 1)
        let frame = try SamsungPeerWire.frame(packet)
        for edge in 0...frame.count {
            var b = try NativeSamsungBlePeerStreamBuffer(), decoder = SamsungPeerWire.FrameDecoder()
            var packets: [SamsungPeerWire.Packet] = []
            try b.receive(Data(frame.prefix(edge)))
            try decoder.append(b.takeReceived(maximum: frame.count)) { packets.append($0) }
            try b.receive(Data(frame.dropFirst(edge)))
            try decoder.append(b.takeReceived(maximum: frame.count)) { packets.append($0) }
            try decoder.finish(); XCTAssertEqual(packets, [packet])
        }
        var b = try NativeSamsungBlePeerStreamBuffer(), decoder = SamsungPeerWire.FrameDecoder()
        var count = 0
        for byte in frame + frame {
            try b.receive(Data([byte])); try decoder.append(b.takeReceived()) { _ in count += 1 }
        }
        XCTAssertEqual(count, 2); try decoder.finish()
    }
    func testPublicJSONOnlyClosedVocabulary() throws {
        let d = NativeSamsungBlePeerDiagnostics(phase: .channelOpen, reason: nil, candidates: 2, rejected: 3, channelsOpened: 1, authenticated: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["phase", "candidates", "rejected", "channelsOpened", "authenticated"]))
        XCTAssertEqual(object["authenticated"] as? Bool, false)
    }
}
