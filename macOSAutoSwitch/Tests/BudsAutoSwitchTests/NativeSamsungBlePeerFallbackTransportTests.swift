import XCTest
@testable import BudsAutoSwitch

@MainActor private final class BleFallbackClock: NativeSamsungPeerClock {
    final class Token: NativeSamsungPeerTimer {
        let at: TimeInterval; var body: (@MainActor () -> Void)?
        init(_ at: TimeInterval, _ body: @escaping @MainActor () -> Void) { self.at = at; self.body = body }
        func cancel() { body = nil }
    }
    var now: TimeInterval = 100
    var timers: [Token] = []
    func schedule(at: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any NativeSamsungPeerTimer {
        let token = Token(at, body); timers.append(token); return token
    }
    func advance(_ n: TimeInterval) {
        now += n; let due = timers.filter { $0.at <= now }; timers.removeAll { $0.at <= now }
        for token in due { let f = token.body; token.body = nil; f?() }
    }
}
@MainActor private final class BleFallbackClassic: NativeSamsungPeerCoordinatorTransport, NativeSamsungPeerRadioDiagnosticSource, NativeSamsungPeerCandidateRouting {
    var report = NativeSamsungPeerRadioSummary()
    var radioSummary: NativeSamsungPeerRadioSummary { report }
    var error: NativeSamsungPeerFailure?
    var opens = 0, closes = 0, sends = 0
    var budgets: [TimeInterval] = []
    var terminal: ((NativeSamsungPeerFailure) -> Void)?
    var packet: ((NativeSamsungPeerUntrustedPacket) -> Void)?
    var beforeReturn: (() -> Void)?
    var learnedCandidates = 0, rejectedCandidates = 0
    var canRejectCandidate = false
    func expectedPeerAuthenticated() { learnedCandidates += 1 }
    func rejectUnexpectedPeerCandidate() -> Bool {
        guard canRejectCandidate else { return false }
        rejectedCandidates += 1; return true
    }
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {
        opens += 1; budgets.append(openingBudget); terminal = onTermination; packet = onUntrustedPacket; beforeReturn?()
        if let error { onTermination(error); throw error }
    }
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws { sends += 1 }
    func close() { closes += 1 }
}
@MainActor private final class BleFallbackAdapter: NativeSamsungBlePeerFallbackAdapter, NativeSamsungPeerRadioDiagnosticSource {
    var report = NativeSamsungPeerRadioSummary()
    var radioSummary: NativeSamsungPeerRadioSummary { report }
    var onCandidate: ((UUID, SamsungContinuityAdvertisement.Candidate) -> Void)?
    var onUntrustedChannel: (() -> Void)?
    var onBytesAvailable: (() -> Void)?
    var onWriteDrained: (() -> Void)?
    var onClosed: ((NativeSamsungBlePeerDiagnostics.Reason) -> Void)?
    var starts = 0, closes = 0, connections = 0
    var holdOpen = false
    var bytes = Data(), writes: [Data] = []
    var onSend: ((Data) throws -> Void)?
    func startFallback(authorization: NativeSamsungBlePeerCentral.FallbackAuthorization) throws {
        starts += 1; if !holdOpen { onUntrustedChannel?() }
    }
    func connectCandidate(_ token: UUID) throws { connections += 1 }
    func send(_ bytes: Data) throws { writes.append(bytes); try onSend?(bytes) }
    func takeReceived(maximum: Int) -> Data {
        let data = Data(bytes.prefix(maximum)); bytes.removeFirst(data.count); return data
    }
    func close() { closes += 1 }
    func emit(_ bytes: Data) { self.bytes.append(bytes); onBytesAvailable?() }
    func drain() { onWriteDrained?() }
}

extension SamsungCloudCertificateTests {
    @MainActor func testCandidateRoutingForwardsOnlySelectedBLECarrier() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material)
        for useBLE in [false, true] {
            let classic = BleFallbackClassic(), ble = BleFallbackClassic(), clock = BleFallbackClock()
            classic.canRejectCandidate = true; ble.canRejectCandidate = true
            let wrapper = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock,
                strategy: useBLE ? .advertisedLEFirst : .classicFirst, bleFactory: { _ in ble })
            wrapper.configure(material: material)
            wrapper.expectedPeerAuthenticated(); XCTAssertFalse(wrapper.rejectUnexpectedPeerCandidate())
            try await wrapper.open(peer: peer, openingBudget: 5, onUntrustedPacket: { _ in }, onTermination: { _ in })
            wrapper.expectedPeerAuthenticated()
            XCTAssertEqual(wrapper.rejectUnexpectedPeerCandidate(), useBLE)
            XCTAssertEqual(ble.learnedCandidates, useBLE ? 1 : 0)
            XCTAssertEqual(ble.rejectedCandidates, useBLE ? 1 : 0)
            XCTAssertEqual(classic.learnedCandidates, 0); XCTAssertEqual(classic.rejectedCandidates, 0)
            wrapper.close(); XCTAssertFalse(wrapper.rejectUnexpectedPeerCandidate())
        }
    }
    @MainActor private func bleSettle() async { for _ in 0..<150 { await Task.yield() } }
    @MainActor private func blePeer(_ material: C.PeerMaterial) throws -> NativeSamsungPeerVerifiedAddress {
        let own = try NativeSamsungPeerCoordinator.address(material.ownClassicAddress)
        let phone = try NativeSamsungPeerCoordinator.address(material.phones[0].address)
        return try .init(hostVerifiedClassicPhone: phone, roster: .init(revision: Int32(material.revision), members: [own, phone]))
    }
    @MainActor func testBleFallbackHEXFingerprintRedactedAndDefaultMemberwiseCompatibility() throws {
        let material = try coordinatorMaterial()
        XCTAssertEqual(material.accountFingerprint?.bytes, Data([1, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]))
        XCTAssertNotEqual(material.accountFingerprint?.bytes, Data(base64Encoded: "0123456789aBcDeF"))
        let copy = C.PeerMaterial(ownClassicAddress: material.ownClassicAddress, accountKey: material.accountKey,
            revision: material.revision, phones: material.phones, identityMode: material.identityMode)
        XCTAssertNil(copy.accountFingerprint)
        XCTAssertFalse(String(reflecting: material.accountFingerprint!).contains("012345"))
        XCTAssertEqual(Mirror(reflecting: material.accountFingerprint!).children.count, 0)
    }
    @MainActor func testBleFallbackOnlyExactServiceAbsenceAndNoClassicTerminationLeak() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material)
        for reason: NativeSamsungPeerFailure? in [nil, .aclFailed, .sdpFailed, .openingDeadline, .channelFailed, .cancelled, .serviceUnavailable] {
            let classic = BleFallbackClassic(), ble = BleFallbackClassic(), clock = BleFallbackClock()
            classic.error = reason; var factories = 0, terminations = 0
            let wrapper = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, bleFactory: { _ in factories += 1; return ble })
            wrapper.configure(material: material)
            do { try await wrapper.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in terminations += 1 }) }
            catch { XCTAssertNotNil(reason); XCTAssertNotEqual(reason, .serviceUnavailable) }
            XCTAssertEqual(factories, reason == .serviceUnavailable ? 1 : 0)
            if reason == .serviceUnavailable {
                XCTAssertEqual(terminations, 0)
                classic.terminal?(.closed) // retired Classic callback must not close CoC
                XCTAssertEqual(terminations, 0)
                try await wrapper.send(.init(), budget: 5); XCTAssertEqual(ble.sends, 1)
            }
            wrapper.close()
        }
    }
    @MainActor func testBleFallbackMissingFingerprintAndSharedTotalBudget() async throws {
        var material = try coordinatorMaterial(); let peer = try blePeer(material)
        material.accountFingerprint = nil
        let classic = BleFallbackClassic(), clock = BleFallbackClock(); classic.error = .serviceUnavailable
        var factories = 0
        let wrapper = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, bleFactory: { _ in factories += 1; return BleFallbackClassic() })
        wrapper.configure(material: material)
        do { try await wrapper.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .serviceUnavailable) }
        XCTAssertEqual(factories, 0)
        let c2 = BleFallbackClassic(); c2.error = .serviceUnavailable
        c2.beforeReturn = { clock.advance(15) }
        let w2 = NativeSamsungBlePeerFallbackTransport(classic: c2, clock: clock, bleFactory: { _ in factories += 1; return BleFallbackClassic() })
        w2.configure(material: try coordinatorMaterial())
        do { try await w2.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .openingDeadline) }
        XCTAssertEqual(factories, 0)
    }
    @MainActor func testBleFallbackDrainCompletionBusyWriteCloseAndStaleCallbacks() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock(), adapter = BleFallbackAdapter()
        let channel = NativeSamsungBlePeerFallbackChannel(fingerprint: try .init(provisionedBytes: material.accountFingerprint!.bytes), clock: clock, adapterFactory: { adapter })
        var packets: [SamsungPeerWire.Packet] = [], terminations = 0
        try await channel.open(peer: peer, openingBudget: 15, onUntrustedPacket: { packets.append($0.packet) }, onTermination: { _ in terminations += 1 })
        var completed = false
        let write = Task { try await channel.send(.init(payload: Data([1, 2, 3])), budget: 5); completed = true }
        await bleSettle(); XCTAssertFalse(completed); XCTAssertEqual(adapter.writes.count, 1)
        do { try await channel.send(.init(), budget: 5); XCTFail() } catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .busy) }
        adapter.drain(); try await write.value; XCTAssertTrue(completed)
        let packet = SamsungPeerWire.Packet(handlerID: 0, payload: Data(repeating: 7, count: 200), authType: 1)
        for byte in try SamsungPeerWire.frame(packet) { adapter.emit(Data([byte])) }
        XCTAssertEqual(packets, [packet])
        let staleBytes = adapter.onBytesAvailable, staleDrain = adapter.onWriteDrained, staleOpen = adapter.onUntrustedChannel
        channel.close(); staleBytes?(); staleDrain?(); staleOpen?()
        XCTAssertEqual(terminations, 1); XCTAssertEqual(packets.count, 1)
    }
    @MainActor func testBleFallbackSilentDeadlineWriteTimeoutAndPacketBound() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock(), adapter = BleFallbackAdapter()
        adapter.holdOpen = true
        let channel = NativeSamsungBlePeerFallbackChannel(fingerprint: try .init(provisionedBytes: material.accountFingerprint!.bytes), clock: clock, adapterFactory: { adapter })
        let open = Task { try await channel.open(peer: peer, openingBudget: 3, onUntrustedPacket: { _ in }, onTermination: { _ in }) }
        await bleSettle(); clock.advance(3)
        do { try await open.value; XCTFail() } catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .openingDeadline) }
        XCTAssertEqual(adapter.closes, 1)
        let a2 = BleFallbackAdapter(), c2 = NativeSamsungBlePeerFallbackChannel(fingerprint: try .init(provisionedBytes: material.accountFingerprint!.bytes), clock: clock, adapterFactory: { a2 })
        try await c2.open(peer: peer, openingBudget: 3, onUntrustedPacket: { _ in }, onTermination: { _ in })
        do { try await c2.send(.init(payload: Data(repeating: 0, count: 65_536)), budget: 5); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .invalidPacket) }
        XCTAssertEqual(a2.writes.count, 0)
        let write = Task { try await c2.send(.init(), budget: 2) }
        await bleSettle(); clock.advance(2)
        do { try await write.value; XCTFail() } catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .writeDeadline) }
        a2.drain(); XCTAssertEqual(a2.closes, 1)
    }
    @MainActor func testBleFallbackRemainingBudgetAndCancellationFence() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock()
        let classic = BleFallbackClassic(), adapter = BleFallbackAdapter(); adapter.holdOpen = true
        classic.error = .serviceUnavailable; classic.beforeReturn = { clock.advance(12) }
        let wrapper = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, bleFactory: { f in
            NativeSamsungBlePeerFallbackChannel(fingerprint: f, clock: clock, adapterFactory: { adapter })
        })
        wrapper.configure(material: material)
        let open = Task { try await wrapper.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }) }
        await bleSettle(); XCTAssertEqual(adapter.starts, 1)
        let late = adapter.onUntrustedChannel
        clock.advance(3)
        do { try await open.value; XCTFail() } catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .openingDeadline) }
        late?(); XCTAssertEqual(adapter.closes, 1)
        let a2 = BleFallbackAdapter(); a2.holdOpen = true
        let c2 = NativeSamsungBlePeerFallbackChannel(fingerprint: try .init(provisionedBytes: material.accountFingerprint!.bytes), clock: clock, adapterFactory: { a2 })
        let cancelled = Task { try await c2.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }) }
        await bleSettle(); let stale = a2.onUntrustedChannel; cancelled.cancel(); await bleSettle()
        do { try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError || error as? NativeSamsungPeerFailure == .cancelled) }
        stale?(); XCTAssertEqual(a2.closes, 1)
    }
    @MainActor func testLEFirstRequiresConfiguredFingerprintAndNeverPagesClassicFirst() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock()
        let classic = BleFallbackClassic(), ble = BleFallbackClassic(); var created = 0
        let unconfigured = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, strategy: .advertisedLEFirst, bleFactory: { _ in created += 1; return ble })
        do { try await unconfigured.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSamsungPeerFailure, .invalidConfiguration) }
        XCTAssertEqual(classic.opens, 0); XCTAssertEqual(created, 0)
        let configured = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, strategy: .advertisedLEFirst, bleFactory: { _ in created += 1; return ble })
        configured.configure(material: material)
        try await configured.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in })
        XCTAssertEqual(classic.opens, 0); XCTAssertEqual(ble.opens, 1)
        XCTAssertEqual(configured.radioSummary.strategy, .advertisedLEFirst); configured.close()
    }
    @MainActor func testLEFirstDiscoveryFallbackOnlyRemainingBudgetAndFrozenDiagnostics() async throws {
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock()
        for reason: NativeSamsungBlePeerDiagnostics.Reason in [.unavailable, .discoveryDeadline, .channelFailed] {
            let classic = BleFallbackClassic(), ble = BleFallbackClassic(); ble.error = .channelFailed
            ble.report = .init(ble: .init(phase: .closed, reason: reason, candidates: 0, channelsOpened: 0))
            ble.beforeReturn = { clock.advance(2) }
            classic.report = .init(classic: .init(phase: .acl, failure: .openingDeadline, pendingOperations: 1))
            let io = NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, strategy: .advertisedLEFirst, bleFactory: { _ in ble })
            io.configure(material: material)
            do { try await io.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }) }
            catch { XCTAssertEqual(reason, .channelFailed) }
            XCTAssertEqual(classic.opens, reason == .channelFailed ? 0 : 1)
            if reason != .channelFailed { XCTAssertEqual(classic.budgets, [13]) }
            io.close(); let before = io.radioSummary
            classic.report = .init(); ble.report = .init(); io.close()
            XCTAssertEqual(io.radioSummary, before); XCTAssertEqual(before.ble?.reason, reason)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: before.safeValues))
        }
    }
    @MainActor func testLEFirstCoordinatorRetainsTypedRadioAfterFailureAndStop() async throws {
        let material = try coordinatorMaterial(), clock = BleFallbackClock(), io = BleFallbackClassic()
        io.error = .aclFailed
        io.report = .init(strategy: .classicFirst, classic: .init(phase: .acl, failure: .aclFailed, pendingOperations: 1))
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        c.connectSelected(); await bleSettle()
        XCTAssertEqual(c.diagnostics.phase, .failed)
        let before = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c.publicDiagnostics["radio"]), options: [.sortedKeys])
        io.report = .init(); c.stop()
        let after = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c.publicDiagnostics["radio"]), options: [.sortedKeys])
        XCTAssertEqual(before, after)
        let text = String(decoding: after, as: UTF8.self)
        XCTAssertTrue(text.contains("aclFailed")); XCTAssertTrue(text.contains("pendingOperations"))
        XCTAssertFalse(text.contains(material.ownClassicAddress)); XCTAssertFalse(text.contains(material.phones[0].address))
        XCTAssertEqual(c.publicDiagnostics["material_stage"] as? String, "ready")
    }
    @MainActor func testLEFirstCandidateRequiresDecodedCoCContextAndActualPSM() async throws {
        let f = try SamsungContinuityAdvertisement.Fingerprint(provisionedBytes: Data(128...159))
        func hex(_ value: String) -> Data {
            let b = Array(value); return Data(stride(from: 0, to: b.count, by: 2).map { UInt8(String(b[$0...($0+1)]), radix: 16)! })
        }
        let coc = try SamsungContinuityAdvertisement.decode(manufacturerData: hex("7500021841a1b005e4269ebc88654b1dd3bff7db"), fingerprint: f, unixMilliseconds: 3_153_612_345)
        let spp = try SamsungContinuityAdvertisement.decode(manufacturerData: hex("750002187b0161e6884405fbebe3e521100b8af4fa050d442edcc6ae3c2f95a05991"), fingerprint: f, unixMilliseconds: 3_153_612_345)
        XCTAssertEqual(coc.capabilities.leCoCPSM, 0x80); XCTAssertEqual(spp.capabilities.preferredTransport, .spp)
        let material = try coordinatorMaterial(), peer = try blePeer(material), clock = BleFallbackClock(), adapter = BleFallbackAdapter()
        adapter.holdOpen = true
        let channel = NativeSamsungBlePeerFallbackChannel(fingerprint: f, clock: clock, authorization: .accountCarrierWithPinnedPeerAuthentication, adapterFactory: { adapter })
        let open = Task { try await channel.open(peer: peer, openingBudget: 15, onUntrustedPacket: { _ in }, onTermination: { _ in }) }
        await bleSettle(); adapter.onCandidate?(UUID(), spp); XCTAssertEqual(adapter.connections, 0)
        adapter.onCandidate?(UUID(), coc); XCTAssertEqual(adapter.connections, 1)
        adapter.onUntrustedChannel?(); try await open.value; XCTAssertFalse(coc.isAuthenticated); channel.close()
    }
    @MainActor func testBleFallbackCoordinatorRealHandshakeFinalDrainAndWrongPeerFence() async throws {
        let material = try coordinatorMaterial()
        for wrongPeer in [false, true] {
            let clock = BleFallbackClock(), adapter = BleFallbackAdapter(), classic = BleFallbackClassic()
            classic.error = .serviceUnavailable
            let own = try NativeSamsungPeerCoordinator.address(material.ownClassicAddress)
            let remote = try NativeSamsungPeerCoordinator.address(wrongPeer ? "42:34:56:78:9A:BC" : material.phones[0].address)
            let roster = try SamsungPeerRoster(revision: Int32(material.revision), members: [own, remote])
            let responder = try SamsungPeerSession(role: .responder, accountKey: material.accountKey.bytes,
                localAddress: remote, roster: roster, expectedPeer: own, crypto: SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification))
            _ = try responder.start(now: clock.now)
            var decoder = SamsungPeerWire.FrameDecoder(), authWrites = 0, commands = 0, keeps = 0
            adapter.onSend = { data in
                try decoder.append(data) { packet in
                    if packet.handlerID == 0 {
                        authWrites += 1
                        if let reply = try responder.receiveAuthentication(packet, now: clock.now) {
                            for b in try SamsungPeerWire.frame(reply) { adapter.emit(Data([b])) }
                        }
                    } else {
                        let decoded = try responder.receiveCommand(packet)
                        if decoded.handlerID == 100 {
                            XCTAssertEqual(decoded.command, .init(commandID: 3, type: 1, payload: Data([1])))
                            keeps += 1
                        } else { commands += 1 }
                    }
                }
                if authWrites == 1 { adapter.drain() } // hold actual final local drain
            }
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
                NativeSamsungBlePeerFallbackTransport(classic: classic, clock: clock, strategy: .advertisedLEFirst, bleFactory: { f in
                    NativeSamsungBlePeerFallbackChannel(fingerprint: f, clock: clock, adapterFactory: { adapter })
                })
            }, clock: clock, wallNow: { self.now })
            coordinator.connectSelected(); await bleSettle()
            XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertEqual(commands, 0); XCTAssertEqual(keeps, 0)
            if wrongPeer {
                XCTAssertEqual(coordinator.diagnostics.phase, .failed)
                adapter.drain(); await bleSettle(); XCTAssertFalse(coordinator.diagnostics.authenticated)
            } else {
                XCTAssertEqual(authWrites, 2); adapter.drain(); await bleSettle()
                XCTAssertTrue(coordinator.diagnostics.authenticated)
            }
            XCTAssertEqual(commands, 0); XCTAssertEqual(keeps, wrongPeer ? 0 : 1)
            XCTAssertEqual(classic.opens, 0); coordinator.stop()
        }
    }
}
