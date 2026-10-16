import XCTest
@testable import BudsAutoSwitch

@MainActor private final class CandidateClock: NativeSamsungPeerClock {
    final class Timer: NativeSamsungPeerTimer {
        var body: (@MainActor () -> Void)?
        let at: TimeInterval
        init(at: TimeInterval, body: @escaping @MainActor () -> Void) { self.at = at; self.body = body }
        func cancel() { body = nil }
    }
    var now: TimeInterval = 100
    var timers: [Timer] = []
    func schedule(at: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any NativeSamsungPeerTimer {
        let timer = Timer(at: at, body: body); timers.append(timer); return timer
    }
    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = timers.filter { $0.at <= now }; timers.removeAll { $0.at <= now }
        for timer in due { let body = timer.body; timer.body = nil; body?() }
    }
}

@MainActor private final class CandidateAdapter: NativeSamsungBlePeerFallbackAdapter {
    var onCandidate: ((UUID, SamsungContinuityAdvertisement.Candidate) -> Void)?
    var onUntrustedChannel: (() -> Void)?
    var onBytesAvailable: (() -> Void)?
    var onWriteDrained: (() -> Void)?
    var onClosed: ((NativeSamsungBlePeerDiagnostics.Reason) -> Void)?
    var selectedPeripheralIdentifier: UUID?
    var preferred: () -> UUID? = { nil }
    var excluded: (UUID) -> Bool = { _ in false }
    var closes = 0
    var received = Data()
    var writes: [Data] = []
    var onSend: ((Data) throws -> Void)?
    func configureCandidateRouting(preferred: @escaping () -> UUID?, excluded: @escaping (UUID) -> Bool) {
        self.preferred = preferred; self.excluded = excluded
    }
    func startFallback(authorization: NativeSamsungBlePeerCentral.FallbackAuthorization) throws { onUntrustedChannel?() }
    func connectCandidate(_ token: UUID) throws {}
    func send(_ bytes: Data) throws { writes.append(bytes); try onSend?(bytes) }
    func takeReceived(maximum: Int) -> Data {
        let bytes = Data(received.prefix(maximum)); received.removeFirst(bytes.count); return bytes
    }
    func close() { closes += 1; selectedPeripheralIdentifier = nil }
    func emit(_ packet: SamsungPeerWire.Packet) throws {
        received.append(try SamsungPeerWire.frame(packet)); onBytesAvailable?()
    }
}

@MainActor private final class CandidateClassic: NativeSamsungPeerCoordinatorTransport, NativeSamsungPeerCandidateRouting {
    var learned = 0, rejected = 0
    func expectedPeerAuthenticated() { learned += 1 }
    func rejectUnexpectedPeerCandidate() -> Bool { rejected += 1; return true }
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {}
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws {}
    func close() {}
}

final class NativeSamsungPeerCandidateRoutingTests: XCTestCase {
    private func address(_ last: UInt8) throws -> SamsungPeerAddress { try .init(bytes: Data([2, 3, 4, 5, 6, last])) }
    private func peer(_ last: UInt8 = 7) throws -> NativeSamsungPeerVerifiedAddress {
        let address = try address(last)
        return try .init(hostVerifiedClassicPhone: address, roster: .init(revision: 1, members: [address]))
    }
    @MainActor private func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor private func channel(_ adapter: CandidateAdapter, _ clock: CandidateClock,
                                    _ cache: NativeSamsungPeerCandidateCache? = nil) throws -> NativeSamsungBlePeerFallbackChannel {
        .init(fingerprint: try .init(provisionedBytes: Data(128...159)), clock: clock, candidateCache: cache,
              authorization: .accountCarrierWithPinnedPeerAuthentication, adapterFactory: { adapter })
    }
    @MainActor func testTargetScopedExclusionsAndIndependentTTL() throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now })
        let a = try address(7), b = try address(8), route = UUID(), good = UUID()
        XCTAssertTrue(cache.rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: a, routingIdentifier: route))
        XCTAssertTrue(cache.isExcluded(route, expectedSamsungPeerAddress: a))
        XCTAssertFalse(cache.isExcluded(route, expectedSamsungPeerAddress: b))
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: a))
        XCTAssertFalse(cache.rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: a, routingIdentifier: route))
        clock.advance(30)
        cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: a, routingIdentifier: good)
        cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: b, routingIdentifier: route)
        clock.advance(29.999)
        XCTAssertTrue(cache.isExcluded(route, expectedSamsungPeerAddress: a))
        clock.advance(0.001)
        XCTAssertFalse(cache.isExcluded(route, expectedSamsungPeerAddress: a))
        XCTAssertEqual(cache.preferredIdentifier(expectedSamsungPeerAddress: a), good)
        XCTAssertEqual(cache.preferredIdentifier(expectedSamsungPeerAddress: b), route)
        clock.advance(30)
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: a))
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: b))
    }
    @MainActor func testSixteenRoutesPerTargetAndSixteenTargets() throws {
        let cache = NativeSamsungPeerCandidateCache(monotonic: { 100 }), a = try address(7)
        let routes = (0..<17).map { _ in UUID() }
        for route in routes { XCTAssertTrue(cache.rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: a, routingIdentifier: route)) }
        XCTAssertFalse(cache.isExcluded(routes[0], expectedSamsungPeerAddress: a))
        for route in routes.dropFirst() { XCTAssertTrue(cache.isExcluded(route, expectedSamsungPeerAddress: a)) }
        let good = UUID(); cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: a, routingIdentifier: good)
        XCTAssertFalse(cache.isExcluded(routes[1], expectedSamsungPeerAddress: a))
        XCTAssertEqual(cache.preferredIdentifier(expectedSamsungPeerAddress: a), good)
        for n in UInt8(8)...23 { cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: try address(n), routingIdentifier: good) }
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: a))
        for n in UInt8(8)...23 { XCTAssertEqual(cache.preferredIdentifier(expectedSamsungPeerAddress: try address(n)), good) }
    }
    @MainActor func testClockRegressionAndNonfiniteTimeDiscardHints() throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now })
        let a = try address(7), route = UUID()
        cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: a, routingIdentifier: route)
        clock.now -= 1; XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: a))
        cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: a, routingIdentifier: route)
        clock.now = .nan; XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: a))
        XCTAssertFalse(cache.rejectUnexpectedPeerCandidate(expectedSamsungPeerAddress: a, routingIdentifier: route))
    }
    func testPreferredGraceCollectsFallbackAndSelectsOnlyOne() {
        let hint = UUID(), route = UUID(), token = UUID()
        var scan = NativeSamsungPeerCandidateSelection(); scan.begin(now: 10)
        XCTAssertNil(scan.offer(token: token, identifier: route, now: 10.1, preferred: hint, isExcluded: { _ in false }))
        XCTAssertNil(scan.poll(now: 10.999, preferred: hint, isExcluded: { _ in false }))
        XCTAssertEqual(scan.poll(now: 11, preferred: hint, isExcluded: { _ in false }), token)
        XCTAssertNil(scan.offer(token: UUID(), identifier: hint, now: 11.1, preferred: hint, isExcluded: { _ in false }))
    }
    func testPreferredWinsWithinGraceAndExcludedNeverSelected() {
        let hint = UUID(), wrong = UUID(), fallback = UUID(), hintToken = UUID()
        var scan = NativeSamsungPeerCandidateSelection(); scan.begin(now: 10)
        XCTAssertNil(scan.offer(token: UUID(), identifier: wrong, now: 10, preferred: hint, isExcluded: { $0 == wrong }))
        XCTAssertNil(scan.offer(token: UUID(), identifier: fallback, now: 10.2, preferred: hint, isExcluded: { $0 == wrong }))
        XCTAssertEqual(scan.offer(token: hintToken, identifier: hint, now: 10.9, preferred: hint, isExcluded: { $0 == wrong }), hintToken)
        var cold = NativeSamsungPeerCandidateSelection(); cold.begin(now: 10)
        XCTAssertNil(cold.offer(token: UUID(), identifier: wrong, now: 10, preferred: nil, isExcluded: { $0 == wrong }))
        XCTAssertEqual(cold.offer(token: hintToken, identifier: fallback, now: 10, preferred: nil, isExcluded: { $0 == wrong }), hintToken)
    }
    func testFullFallbackCollectionStillAdmitsPreferredDuringGrace() {
        let hint = UUID(), token = UUID()
        var scan = NativeSamsungPeerCandidateSelection(); scan.begin(now: 10)
        for _ in 0..<20 {
            XCTAssertNil(scan.offer(token: UUID(), identifier: UUID(), now: 10.2, preferred: hint, isExcluded: { _ in false }))
        }
        XCTAssertEqual(scan.offer(token: token, identifier: hint, now: 10.9, preferred: hint, isExcluded: { _ in false }), token)
    }
    @MainActor func testChannelLearnsOnlyHostAuthenticatedMappingAndCacheSurvivesFactory() async throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now }), expected = try peer()
        let route = UUID(), first = CandidateAdapter(); first.selectedPeripheralIdentifier = route
        let io = try channel(first, clock, cache)
        io.expectedPeerAuthenticated() // no open channel
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address))
        try await io.open(peer: expected, openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
        XCTAssertNil(first.preferred()) // scan/open alone is never learning
        io.expectedPeerAuthenticated()
        XCTAssertEqual(first.preferred(), route)
        XCTAssertFalse(io.rejectUnexpectedPeerCandidate()) // cannot flip the authenticated decision
        io.close()
        let second = CandidateAdapter(); second.selectedPeripheralIdentifier = route
        let next = try channel(second, clock, cache)
        try await next.open(peer: expected, openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
        XCTAssertEqual(second.preferred(), route)
        let stale = second.onBytesAvailable
        XCTAssertTrue(next.rejectUnexpectedPeerCandidate())
        XCTAssertEqual(second.closes, 1); XCTAssertTrue(second.excluded(route))
        XCTAssertNil(second.preferred()); stale?()
        XCTAssertFalse(next.rejectUnexpectedPeerCandidate()); next.expectedPeerAuthenticated()
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address))
        let other = CandidateAdapter(), otherChannel = try channel(other, clock, cache)
        try await otherChannel.open(peer: try peer(8), openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
        XCTAssertFalse(other.excluded(route)); otherChannel.close()
    }
    @MainActor func testUnavailableMappingNilCacheAndClassicNeverRetry() async throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now }), expected = try peer()
        for hasCache in [false, true] {
            let adapter = CandidateAdapter(); if !hasCache { adapter.selectedPeripheralIdentifier = UUID() }
            let io = try channel(adapter, clock, hasCache ? cache : nil)
            try await io.open(peer: expected, openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
            XCTAssertFalse(io.rejectUnexpectedPeerCandidate()); io.expectedPeerAuthenticated()
            XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address)); io.close()
        }
        let classic = CandidateClassic(), wrapper = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, candidateCache: cache)
        XCTAssertFalse(wrapper.rejectUnexpectedPeerCandidate())
        try await wrapper.open(peer: expected, openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
        wrapper.expectedPeerAuthenticated(); XCTAssertFalse(wrapper.rejectUnexpectedPeerCandidate())
        XCTAssertEqual(classic.learned, 0); XCTAssertEqual(classic.rejected, 0); wrapper.close()
    }
    @MainActor func testWrongPreferredStillFailsRealGCMExpectedPinAndClosesWithoutCommands() async throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now })
        let own = try address(6), expected = try peer(), wrong = try address(8), route = UUID()
        // A prior success is only a preference. It cannot authenticate this session.
        cache.expectedPeerAuthenticated(expectedSamsungPeerAddress: expected.address, routingIdentifier: route)
        let roster = try SamsungPeerRoster(revision: 1, members: [own, expected.address, wrong])
        let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification), key = Data(repeating: 3, count: 32)
        let host = try SamsungPeerSession(role: .initiator, accountKey: key, localAddress: own, roster: roster, expectedPeer: expected.address, crypto: crypto)
        let remote = try SamsungPeerSession(role: .responder, accountKey: key, localAddress: wrong, roster: roster, expectedPeer: own, crypto: crypto)
        _ = try remote.start(now: clock.now)
        let adapter = CandidateAdapter(); adapter.selectedPeripheralIdentifier = route
        let io = try channel(adapter, clock, cache)
        var failure: SamsungPeerDiagnostics.Failure?, commands = 0
        try await io.open(peer: expected, openingBudget: 5, onUntrustedPacket: { packet in
            do { _ = try host.receiveAuthentication(packet.packet, now: clock.now) }
            catch { failure = error as? SamsungPeerDiagnostics.Failure }
        }, onTermination: { _ in })
        XCTAssertEqual(adapter.preferred(), route)
        var decoder = SamsungPeerWire.FrameDecoder()
        adapter.onSend = { bytes in
            try decoder.append(bytes) { packet in
                if packet.handlerID != 0 { commands += 1 }
                if let reply = try remote.receiveAuthentication(packet, now: clock.now) { try adapter.emit(reply) }
            }
        }
        let initial = try XCTUnwrap(host.start(now: clock.now))
        var completed = false
        let write = Task { try await io.send(initial, budget: 5); completed = true }
        await settle()
        XCTAssertFalse(completed) // actual adapter drain remains required
        XCTAssertEqual(failure, .unexpectedAddress); XCTAssertFalse(host.diagnostics.sessionReady)
        XCTAssertFalse(adapter.excluded(route)) // only the host rejection records exclusion
        let staleDrain = adapter.onWriteDrained
        XCTAssertTrue(io.rejectUnexpectedPeerCandidate())
        do { try await write.value; XCTFail("rejected channel write must fail") }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .closed) }
        staleDrain?(); XCTAssertFalse(completed); XCTAssertEqual(adapter.closes, 1)
        XCTAssertTrue(cache.isExcluded(route, expectedSamsungPeerAddress: expected.address))
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address))
        XCTAssertEqual(commands, 0)
    }
    @MainActor func testRealExpectedPeerLearnsOnlyAfterFinalWriteDrainAndHostConfirmation() async throws {
        let clock = CandidateClock(), cache = NativeSamsungPeerCandidateCache(monotonic: { clock.now })
        let own = try address(6), expected = try peer(), route = UUID()
        let roster = try SamsungPeerRoster(revision: 1, members: [own, expected.address])
        let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification), key = Data(repeating: 3, count: 32)
        let host = try SamsungPeerSession(role: .initiator, accountKey: key, localAddress: own, roster: roster, expectedPeer: expected.address, crypto: crypto)
        let remote = try SamsungPeerSession(role: .responder, accountKey: key, localAddress: expected.address, roster: roster, expectedPeer: own, crypto: crypto)
        _ = try remote.start(now: clock.now)
        let adapter = CandidateAdapter(); adapter.selectedPeripheralIdentifier = route
        let io = try channel(adapter, clock, cache)
        var finalReply: SamsungPeerWire.Packet?, receiveError: Error?, commands = 0
        try await io.open(peer: expected, openingBudget: 5, onUntrustedPacket: { packet in
            do { finalReply = try host.receiveAuthentication(packet.packet, now: clock.now) }
            catch { receiveError = error }
        }, onTermination: { _ in })
        var decoder = SamsungPeerWire.FrameDecoder()
        adapter.onSend = { bytes in
            try decoder.append(bytes) { packet in
                if packet.handlerID != 0 { commands += 1 }
                if let reply = try remote.receiveAuthentication(packet, now: clock.now) { try adapter.emit(reply) }
            }
            if adapter.writes.count == 1 { adapter.onWriteDrained?() }
        }
        try await io.send(try XCTUnwrap(host.start(now: clock.now)), budget: 5)
        XCTAssertNil(receiveError)
        let final = try XCTUnwrap(finalReply)
        var completed = false
        let write = Task { try await io.send(final, budget: 5); completed = true }
        await settle()
        XCTAssertFalse(completed); XCTAssertFalse(host.diagnostics.sessionReady)
        XCTAssertTrue(remote.diagnostics.sessionReady)
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address))
        adapter.onWriteDrained?(); try await write.value
        XCTAssertNil(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address))
        try host.confirmFinalReplySent(now: clock.now)
        XCTAssertTrue(host.diagnostics.sessionReady)
        io.expectedPeerAuthenticated()
        XCTAssertEqual(cache.preferredIdentifier(expectedSamsungPeerAddress: expected.address), route)
        XCTAssertEqual(commands, 0); io.close()
    }
}
