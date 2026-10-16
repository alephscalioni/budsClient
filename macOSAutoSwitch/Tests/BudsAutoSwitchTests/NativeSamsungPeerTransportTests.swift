import XCTest
@testable import BudsAutoSwitch

@MainActor private final class PeerFakeClock: NativeSamsungPeerClock {
    final class Timer: NativeSamsungPeerTimer {
        let at: TimeInterval
        var body: (@MainActor () -> Void)?
        init(_ at: TimeInterval, _ body: @escaping @MainActor () -> Void) { self.at = at; self.body = body }
        func cancel() { body = nil }
    }
    var now: TimeInterval = 100
    var timers: [Timer] = []
    func schedule(at: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any NativeSamsungPeerTimer {
        let timer = Timer(at, body); timers.append(timer); return timer
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        for timer in timers.sorted(by: { $0.at < $1.at }) where timer.at <= now {
            let body = timer.body; timer.body = nil; body?()
        }
    }
}
private final class PeerFakeChannel: NativeSamsungPeerChannel {
    var receiver: NativeSamsungPeerOperation?
}
@MainActor private final class PeerFakeEffects: NativeSamsungPeerEffects {
    var pending: [NativeSamsungPeerOperation] = []
    var closed: [any NativeSamsungPeerChannel] = []
    var closeCompletions: [@MainActor (Bool) -> Void] = []
    var holdClose = false
    func start(_ request: NativeSamsungPeerRequest, operation: NativeSamsungPeerOperation) { pending.append(operation) }
    func close(_ channel: any NativeSamsungPeerChannel, completion: @escaping @MainActor (Bool) -> Void) {
        closed.append(channel)
        if holdClose { closeCompletions.append(completion) } else { completion(true) }
    }
    func take() async throws -> NativeSamsungPeerOperation {
        for _ in 0..<1000 {
            if !pending.isEmpty { return pending.removeFirst() }
            await Task.yield()
        }
        XCTFail("Missing fake operation"); throw NativeSamsungPeerFailure.closed
    }
}
@MainActor private final class PeerFixture {
    let clock = PeerFakeClock()
    let effects = PeerFakeEffects()
    let drain = NativeSamsungPeerOperationDrain()
    let peer: NativeSamsungPeerVerifiedAddress
    let local: SamsungPeerAddress
    let roster: SamsungPeerRoster
    var packets: [NativeSamsungPeerUntrustedPacket] = []
    var terminations: [NativeSamsungPeerFailure] = []
    init() throws {
        local = try .init(bytes: Data([2, 0, 0, 0, 0, 1]))
        let phone = try SamsungPeerAddress(bytes: Data([2, 0, 0, 0, 0, 2]))
        roster = try .init(revision: 1, members: [local, phone])
        peer = try .init(hostVerifiedClassicPhone: phone, roster: roster)
    }
    func transport() -> NativeSamsungPeerTransport { .init(effects: effects, clock: clock, drain: drain) }
    func start(_ transport: NativeSamsungPeerTransport, budget: TimeInterval = 15,
               terminated: ((NativeSamsungPeerFailure) -> Void)? = nil) -> Task<Void, Error> {
        Task { @MainActor [self] in
            try await transport.open(peer: peer, openingBudget: budget,
                                     onUntrustedPacket: { [weak self] in self?.packets.append($0) },
                                     onTermination: { [weak self] error in self?.terminations.append(error); terminated?(error) })
        }
    }
    func throughSDP() async throws -> NativeSamsungPeerOperation {
        let acl = try await effects.take()
        guard case .connect(let p) = acl.request else { XCTFail(); throw NativeSamsungPeerFailure.closed }
        XCTAssertEqual(p, peer)
        acl.onReturn(true, nil, NSObject()); acl.onResult(.connected(true))
        let sdp = try await effects.take()
        guard case .discover = sdp.request else { XCTFail(); throw NativeSamsungPeerFailure.closed }
        sdp.onReturn(true, nil, NSObject()); sdp.onResult(.discovered(success: true, recordChannel: 7))
        return try await effects.take()
    }
    func establish(_ task: Task<Void, Error>, mtu: Int = 8) async throws -> PeerFakeChannel {
        let op = try await throughSDP()
        guard case .open(_, let id) = op.request else { XCTFail(); throw NativeSamsungPeerFailure.closed }
        XCTAssertEqual(id, 7)
        let channel = PeerFakeChannel(); channel.receiver = op
        op.onReturn(true, channel, NSObject()); op.onResult(.opened(channel, success: true, mtu: mtu))
        try await task.value; return channel
    }
}

final class NativeSamsungPeerTransportTests: XCTestCase {
    @MainActor private func failure(_ task: Task<Void, Error>, _ expected: NativeSamsungPeerFailure,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, expected, file: file, line: line) }
    }
    @MainActor func testCancelBeforeAnySDKReturnKeepsLeaseUntilLateCallbackAndReturn() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let op = try await f.effects.take()
        t.close(); await failure(task, .closed)
        XCTAssertEqual(f.drain.count, 1)
        op.onResult(.connected(true)) // callback alone does not drain the SDK call
        XCTAssertEqual(f.drain.count, 1); XCTAssertTrue(f.effects.pending.isEmpty)
        op.onReturn(true, nil, NSObject())
        XCTAssertEqual(f.drain.count, 0); XCTAssertEqual(f.terminations, [.closed])
    }
    @MainActor func testActualTaskCancellationIsLeaseScoped() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let op = try await f.effects.take(); task.cancel()
        await failure(task, .cancelled)
        XCTAssertEqual(f.drain.count, 1)
        op.onReturn(true, nil, NSObject()); op.onResult(.connected(true))
        XCTAssertEqual(f.drain.count, 0)
        let second = f.start(t); _ = try await f.establish(second)
        op.onResult(.connected(false))
        XCTAssertTrue(t.isOpen); t.close()
    }
    @MainActor func testNoncooperativeSDKDeadlineDoesNotOverlapNewTransportForSamePeer() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t, budget: 3)
        let op = try await f.effects.take()
        f.clock.advance(3); await failure(task, .openingDeadline)
        let other = f.transport(); let denied = f.start(other)
        await failure(denied, .peerDraining)
        XCTAssertTrue(f.effects.pending.isEmpty); XCTAssertEqual(f.drain.count, 1)
        op.onReturn(true, nil, NSObject())
        XCTAssertEqual(f.drain.count, 1)
        op.onResult(.connected(true)); XCTAssertEqual(f.drain.count, 0)
        let fresh = f.start(other); _ = try await f.establish(fresh); other.close()
    }
    @MainActor func testOneOpeningDeadlineCoversACLSDPAndRFCOMM() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t, budget: 10)
        let acl = try await f.effects.take(); f.clock.advance(4)
        acl.onResult(.connected(true)); acl.onReturn(true, nil, nil)
        let sdp = try await f.effects.take(); f.clock.advance(4)
        sdp.onReturn(true, nil, nil); sdp.onResult(.discovered(success: true, recordChannel: 5))
        let open = try await f.effects.take(); f.clock.advance(2)
        await failure(task, .openingDeadline)
        let ch = PeerFakeChannel()
        open.onResult(.opened(ch, success: true, mtu: 10))
        XCTAssertTrue(f.effects.closed.isEmpty, "Wait for SDK return before closing late open")
        open.onReturn(true, ch, nil)
        XCTAssertEqual(f.effects.closed.count, 1); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testLateCreatedChannelCloseMustReturnBeforeLeaseCanBeReacquired() async throws {
        let f = try PeerFixture(); f.effects.holdClose = true
        let t = f.transport(); let task = f.start(t)
        let open = try await f.throughSDP(); t.close(); await failure(task, .closed)
        let ch = PeerFakeChannel()
        open.onReturn(true, ch, nil); XCTAssertTrue(f.effects.closed.isEmpty)
        open.onResult(.opened(ch, success: true, mtu: 8))
        XCTAssertEqual(f.effects.closed.count, 1); XCTAssertEqual(f.drain.count, 1)
        await failure(f.start(f.transport()), .peerDraining)
        f.effects.closeCompletions.removeFirst()(true)
        XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testMissingServiceRecordNeverGuessesChannel() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let acl = try await f.effects.take(); acl.onReturn(true, nil, nil); acl.onResult(.connected(true))
        let sdp = try await f.effects.take(); sdp.onReturn(true, nil, nil)
        sdp.onResult(.discovered(success: true, recordChannel: nil))
        await failure(task, .serviceUnavailable)
        XCTAssertTrue(f.effects.pending.isEmpty); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testCallbackBeforeReturnDoesNotStartNextStage() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let acl = try await f.effects.take(); acl.onResult(.connected(true))
        XCTAssertTrue(f.effects.pending.isEmpty)
        acl.onReturn(true, nil, nil)
        let sdp = try await f.effects.take(); t.close(); await failure(task, .closed)
        sdp.onReturn(false, nil, nil); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testRejectedSDKReturnNeedsNoCallback() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let acl = try await f.effects.take(); acl.onReturn(false, nil, nil)
        await failure(task, .aclFailed); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testFragmentedAndMultipleDelimitedPacketsRemainUntrusted() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let ch = try await f.establish(task)
        let p = SamsungPeerWire.Packet(handlerID: 0, payload: Data(repeating: 7, count: 140), authType: 1)
        let q = SamsungPeerWire.Packet(handlerID: 1, sequence: 2, payload: Data([3, 4]))
        let frame = try SamsungPeerWire.frame(p); let second = try SamsungPeerWire.frame(q)
        ch.receiver?.onBytes(ch, Data(frame.prefix(1))); XCTAssertTrue(f.packets.isEmpty)
        ch.receiver?.onBytes(ch, Data(frame.dropFirst().prefix(20))); XCTAssertTrue(f.packets.isEmpty)
        ch.receiver?.onBytes(ch, Data(frame.dropFirst(21)) + second)
        XCTAssertEqual(f.packets.map(\.packet), [p, q])
        XCTAssertEqual(f.packets.first?.expectedPeer, f.peer)
        XCTAssertEqual(t.diagnostics.phase, .openUntrusted); t.close()
    }
    @MainActor func testReceiverReentrantCloseStopsRemainingPackets() async throws {
        let f = try PeerFixture(); let t = f.transport()
        var delivered = 0
        let task = Task { @MainActor in
            try await t.open(peer: f.peer, onUntrustedPacket: { _ in delivered += 1; t.close() }, onTermination: { _ in })
        }
        let ch = try await f.establish(task)
        let frame = try SamsungPeerWire.frame(.init(payload: Data([1])))
        ch.receiver?.onBytes(ch, frame + frame)
        XCTAssertEqual(delivered, 1); XCTAssertFalse(t.isOpen); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testMalformedAndOversizedStreamsTerminate() async throws {
        for oversized in [false, true] {
            let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
            let ch = try await f.establish(task)
            ch.receiver?.onBytes(ch, oversized ? Data(count: 65537) : Data(repeating: 255, count: 10))
            XCTAssertEqual(t.diagnostics.failure, oversized ? .receiveLimit : .malformedStream)
            XCTAssertEqual(f.effects.closed.count, 1)
        }
    }
    @MainActor func testMTUChunksNeedExactIDAndCompletionBeforeNextChunk() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let ch = try await f.establish(task, mtu: 3)
        let packet = SamsungPeerWire.Packet(payload: Data([1, 2, 3, 4, 5, 6, 7]))
        let expected = try SamsungPeerWire.frame(packet)
        let sending = Task { @MainActor in try await t.send(packet) }
        var observed = Data()
        var chunkCount = 0
        while observed.count < expected.count {
            let op = try await f.effects.take()
            guard case .write(let actual, let buffer) = op.request else { XCTFail(); return }
            XCTAssertTrue(ch === actual); XCTAssertLessThanOrEqual(buffer.bytes.length, 3)
            observed.append(buffer.bytes as Data); chunkCount += 1
            op.onReturn(true, nil, nil)
            op.onResult(.written(channel: ch, id: op.id + 100, success: true, bytesWritten: buffer.bytes.length))
            op.onResult(.written(channel: PeerFakeChannel(), id: op.id, success: true, bytesWritten: nil))
            XCTAssertTrue(f.effects.pending.isEmpty)
            op.onResult(.written(channel: ch, id: op.id, success: true, bytesWritten: buffer.bytes.length))
            op.onResult(.written(channel: ch, id: op.id, success: false, bytesWritten: 0)) // duplicate
        }
        try await sending.value
        XCTAssertEqual(observed, expected); XCTAssertEqual(t.diagnostics.completedChunks, chunkCount)
        XCTAssertEqual(t.diagnostics.completedPackets, 1); t.close()
    }
    @MainActor func testWriteCallbackBeforeSDKReturnKeepsBufferAndLease() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let ch = try await f.establish(task)
        let sending = Task { @MainActor in try await t.send(.init(payload: Data([1]))) }
        var op: NativeSamsungPeerOperation? = try await f.effects.take()
        let id = op!.id; let returned = op!.onReturn; let completed = op!.onResult
        weak var weakBuffer: NativeSamsungPeerWriteBuffer?
        if case .write(_, let buffer) = op!.request { weakBuffer = buffer }
        op = nil
        t.close(); await failure(sending, .closed)
        XCTAssertNotNil(weakBuffer); XCTAssertEqual(f.drain.count, 1)
        completed(.written(channel: ch, id: id, success: true, bytesWritten: nil))
        XCTAssertNotNil(weakBuffer); XCTAssertEqual(f.drain.count, 1)
        returned(true, nil, nil)
        XCTAssertNil(weakBuffer); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testWriteBudgetIsNotExtendedByMTUProgress() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let ch = try await f.establish(task, mtu: 2)
        let sending = Task { @MainActor in try await t.send(.init(payload: Data(count: 20)), budget: 5) }
        let first = try await f.effects.take(); f.clock.advance(4)
        first.onReturn(true, nil, nil); first.onResult(.written(channel: ch, id: first.id, success: true, bytesWritten: 2))
        let next = try await f.effects.take(); f.clock.advance(1)
        await failure(sending, .writeDeadline); XCTAssertEqual(f.drain.count, 1)
        next.onReturn(true, nil, nil); next.onResult(.written(channel: ch, id: next.id, success: false, bytesWritten: 0))
        XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testShortOrRejectedWriteTerminatesAndDoesNotAdvance() async throws {
        for rejected in [false, true] {
            let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
            let ch = try await f.establish(task, mtu: 2)
            let sending = Task { @MainActor in try await t.send(.init(payload: Data(count: 20))) }
            let write = try await f.effects.take()
            write.onReturn(!rejected, nil, nil)
            if !rejected { write.onResult(.written(channel: ch, id: write.id, success: true, bytesWritten: 1)) }
            await failure(sending, .writeFailed)
            XCTAssertTrue(f.effects.pending.isEmpty); XCTAssertEqual(f.drain.count, 0)
        }
    }
    @MainActor func testStaleReceiveCloseWriteCannotAffectNewSession() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let old = try await f.establish(task); t.close()
        let next = f.start(t); let fresh = try await f.establish(next)
        old.receiver?.onBytes(old, try SamsungPeerWire.frame(.init(payload: Data([8]))))
        old.receiver?.onClosed(old); old.receiver?.onResult(.connected(false))
        XCTAssertTrue(t.isOpen); XCTAssertTrue(f.packets.isEmpty)
        fresh.receiver?.onBytes(fresh, try SamsungPeerWire.frame(.init(payload: Data([9]))))
        XCTAssertEqual(f.packets.count, 1); t.close()
    }
    @MainActor func testOwnerReleaseClosesProfileWithoutCallerCleanup() async throws {
        let f = try PeerFixture(); var t: NativeSamsungPeerTransport? = f.transport()
        let task = f.start(t!); _ = try await f.establish(task)
        weak let weakOwner = t; t = nil
        for _ in 0..<100 { if f.drain.count == 0 { break }; await Task.yield() }
        XCTAssertNil(weakOwner); XCTAssertEqual(f.effects.closed.count, 1); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testCloseMidHandshakeNeverMarksSessionAuthenticated() async throws {
        let f = try PeerFixture()
        let session = try SamsungPeerSession(role: .initiator, accountKey: Data(repeating: 7, count: 32),
                                            localAddress: f.local, roster: f.roster, expectedPeer: f.peer.address,
                                            crypto: SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification))
        _ = try session.start(now: f.clock.now)
        let t = f.transport(); let task = f.start(t, terminated: { _ in session.close() })
        let ch = try await f.establish(task)
        XCTAssertEqual(session.phase, .awaitingInitiateReply)
        ch.receiver?.onClosed(ch)
        XCTAssertEqual(session.phase, .closed); XCTAssertFalse(session.diagnostics.sessionReady)
        XCTAssertEqual(t.diagnostics.phase, .closed)
    }
    @MainActor func testEarlyDataIsBoundedAndHeldUntilOpenCompletes() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let op = try await f.throughSDP(); let ch = PeerFakeChannel(); ch.receiver = op
        let packet = SamsungPeerWire.Packet(payload: Data([1, 2]))
        op.onReturn(true, ch, nil)
        op.onBytes(ch, try SamsungPeerWire.frame(packet))
        XCTAssertTrue(f.packets.isEmpty)
        op.onResult(.opened(ch, success: true, mtu: 8)); try await task.value
        XCTAssertEqual(f.packets.map(\.packet), [packet]); t.close()
    }
    @MainActor func testFailedProfileCloseKeepsPeerOwnershipInsteadOfOverlappingReopen() async throws {
        let f = try PeerFixture(); f.effects.holdClose = true
        let t = f.transport(); let task = f.start(t); _ = try await f.establish(task)
        t.close(); f.effects.closeCompletions.removeFirst()(false)
        XCTAssertEqual(t.diagnostics.failure, .profileCloseFailed)
        XCTAssertEqual(t.diagnostics.pendingOperations, 1)
        XCTAssertEqual(f.drain.count, 1)
        await failure(f.start(f.transport()), .peerDraining)
    }
    @MainActor func testDrainRetainsSDKReceiverAfterTimedOutOwnerIsReleased() async throws {
        let f = try PeerFixture(); var t: NativeSamsungPeerTransport? = f.transport()
        let task = f.start(t!, budget: 1)
        var op: NativeSamsungPeerOperation? = try await f.effects.take()
        let completed = op!.onResult
        var resource: NSObject? = NSObject(); weak let weakResource = resource
        op!.onReturn(true, nil, resource); resource = nil; op = nil
        f.clock.advance(1); await failure(task, .openingDeadline)
        weak let weakOwner = t; t = nil
        XCTAssertNil(weakOwner); XCTAssertNotNil(weakResource); XCTAssertEqual(f.drain.count, 1)
        completed(.connected(true))
        XCTAssertNil(weakResource); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testPreOpenReceiveQueueOverflowFailsAndDrainsLateChannel() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        let op = try await f.throughSDP(); let ch = PeerFakeChannel()
        op.onReturn(true, ch, nil)
        for _ in 0..<5 { op.onBytes(ch, Data(count: 65536)) }
        await failure(task, .receiveLimit)
        XCTAssertEqual(f.drain.count, 1); XCTAssertTrue(f.effects.closed.isEmpty)
        op.onResult(.opened(ch, success: true, mtu: 8))
        XCTAssertEqual(f.effects.closed.count, 1); XCTAssertEqual(f.drain.count, 0)
    }
    @MainActor func testDiagnosticsContainOnlyClosedVocabularyAndCounters() async throws {
        let f = try PeerFixture(); let t = f.transport(); let task = f.start(t)
        _ = try await f.establish(task)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(t.diagnostics)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["phase", "receivedBytes", "receivedPackets", "completedPackets", "completedChunks", "pendingOperations"])
        XCTAssertEqual(object["phase"] as? String, "openUntrusted")
        XCTAssertEqual(String(describing: f.peer), "NativeSamsungPeerVerifiedAddress(redacted)")
        XCTAssertEqual(NativeSamsungPeerTransport.serviceUUID, "3A622E58-C035-4A26-928C-5601DDE7C657")
        t.close()
    }
}
