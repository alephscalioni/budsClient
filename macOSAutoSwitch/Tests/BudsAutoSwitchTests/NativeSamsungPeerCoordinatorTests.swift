import XCTest
@testable import BudsAutoSwitch

@MainActor private final class CoordinatorClock: NativeSamsungPeerClock {
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
        let due = timers.filter { $0.at <= now }; timers.removeAll { $0.at <= now }
        for timer in due { let action = timer.body; timer.body = nil; action?() }
    }
}
@MainActor private final class CoordinatorFakeTransport: NativeSamsungPeerCoordinatorTransport, NativeSamsungPeerCandidateRouting {
    let material: SamsungCloudCertificate.PeerMaterial
    let clock: CoordinatorClock
    let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification)
    var responder: SamsungPeerSession?
    var receive: ((NativeSamsungPeerUntrustedPacket) -> Void)?
    var terminal: ((NativeSamsungPeerFailure) -> Void)?
    var peer: NativeSamsungPeerVerifiedAddress?
    var opened = 0
    var closed = 0
    var packets: [SamsungPeerWire.Packet] = []
    var commands: [SamsungPeerBudsSwitch] = []
    var keepCommands: [SamsungPeerWire.Command] = []
    var keepAck = true
    var remoteKeepsConnection = false
    var holdKeep = false
    var failKeep = false
    var keepGate: CheckedContinuation<Void, Never>?
    var holdFinal = false
    var holdFinalCompletion = false
    var finalCompletionGate: CheckedContinuation<Void, Never>?
    var holdCommand = false
    var commandGate: CheckedContinuation<Void, Never>?
    var finalGate: CheckedContinuation<Void, Never>?
    var holdOpen = false
    var openGate: CheckedContinuation<Void, Never>?
    var silent = false
    var ack = true
    var wrongPhone = false
    var claimedPhoneAddress: SamsungPeerAddress?
    var canRejectUnexpected = false
    var rejectedCandidates = 0
    var rejectEmitsClose = false
    var learnedExpectedCandidates = 0
    func expectedPeerAuthenticated() { learnedExpectedCandidates += 1 }
    func rejectUnexpectedPeerCandidate() -> Bool {
        guard canRejectUnexpected else { return false }
        rejectedCandidates += 1
        if rejectEmitsClose { terminal?(.closed) }
        return true
    }
    var activeWrites = 0
    var maxWrites = 0
    var lastAuthReply: SamsungPeerWire.Packet?
    init(_ material: SamsungCloudCertificate.PeerMaterial, clock: CoordinatorClock) { self.material = material; self.clock = clock }
    func open(peer: NativeSamsungPeerVerifiedAddress, openingBudget: TimeInterval,
              onUntrustedPacket: @escaping (NativeSamsungPeerUntrustedPacket) -> Void,
              onTermination: @escaping (NativeSamsungPeerFailure) -> Void) async throws {
        XCTAssertEqual(openingBudget, 15)
        opened += 1; self.peer = peer; receive = onUntrustedPacket; terminal = onTermination
        if holdOpen { await withCheckedContinuation { openGate = $0 } }
        let own = try NativeSamsungPeerCoordinator.address(material.ownClassicAddress)
        let phone = wrongPhone ? try NativeSamsungPeerCoordinator.address("42:34:56:78:9A:BC") : (claimedPhoneAddress ?? peer.address)
        let roster = try SamsungPeerRoster(revision: Int32(material.revision), members: [own, phone])
        responder = try SamsungPeerSession(role: .responder, accountKey: material.accountKey.bytes,
            localAddress: phone, roster: roster, expectedPeer: own, crypto: crypto)
        _ = try responder?.start(now: clock.now)
    }
    func send(_ packet: SamsungPeerWire.Packet, budget: TimeInterval) async throws {
        XCTAssertEqual(budget, 5)
        activeWrites += 1; maxWrites = max(maxWrites, activeWrites)
        defer { activeWrites -= 1 }
        packets.append(packet)
        if silent { return }
        let responder = try XCTUnwrap(responder)
        if packet.handlerID == 0 {
            if packets.count == 2, holdFinal { await withCheckedContinuation { finalGate = $0 } }
            if let reply = try responder.receiveAuthentication(packet, now: clock.now) {
                lastAuthReply = reply; emit(reply)
            }
            if packets.count == 2, holdFinalCompletion {
                await withCheckedContinuation { finalCompletionGate = $0 }
            }
        } else {
            if packet.handlerID == 100, failKeep { throw NativeSamsungPeerFailure.closed }
            if packet.handlerID == 100, holdKeep { await withCheckedContinuation { keepGate = $0 } }
            if packet.handlerID == 1, holdCommand { await withCheckedContinuation { commandGate = $0 } }
            let received = try responder.receiveCommand(packet)
            if received.handlerID == 100, received.command.commandID == 3 {
                keepCommands.append(received.command)
                if keepAck, received.command.type == 1 {
                    remoteKeepsConnection = received.command.payload == Data([1])
                    emit(try responder.encodeCommand(.init(commandID: 3, type: 2, payload: Data()), handlerID: 100))
                }
                return
            }
            let command = try SamsungPeerBudsSwitch.decode(handlerID: received.handlerID, command: received.command)
            commands.append(command)
            if ack, case .request(_, let address, _) = command {
                emit(try responder.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: address).command(), handlerID: 1))
            }
        }
    }
    func emit(_ packet: SamsungPeerWire.Packet) { if let peer { receive?(.init(expectedPeer: peer, packet: packet)) } }
    func close() { closed += 1; responder?.close() }
    func releaseFinal() { let gate = finalGate; finalGate = nil; gate?.resume() }
    func releaseOpen() { let gate = openGate; openGate = nil; gate?.resume() }
    func releaseFinalCompletion() { let gate = finalCompletionGate; finalCompletionGate = nil; gate?.resume() }
    func releaseCommand() { holdCommand = false; let gate = commandGate; commandGate = nil; gate?.resume() }
    func request(_ address: SamsungPeerAddress, id: UInt16? = nil, reason: SamsungPeerBudsSwitch.Reason = .media) throws {
        let responder = try XCTUnwrap(responder)
        emit(try responder.encodeCommand(SamsungPeerBudsSwitch.request(advertisingID: id ?? address.advertisingID,
            address: address, reason: reason).command(), handlerID: 1))
    }
    var responses: [SamsungPeerBudsSwitch] {
        commands.filter { if case .response = $0 { return true }; return false }
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testConnectionKeepIsEncryptedOnlyAfterFinalAuthAndBeforeBudsRequest() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinal = true
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        XCTAssertNotNil(io.finalGate); XCTAssertTrue(io.keepCommands.isEmpty)
        XCTAssertFalse(c.diagnostics.keepRequestSent)
        io.releaseFinal(); await settleCoordinator()
        XCTAssertEqual(io.packets.map(\.handlerID), [0, 0, 100, 1])
        XCTAssertEqual(io.keepCommands, [.init(commandID: 3, type: 1, payload: Data([1]))])
        XCTAssertEqual(try io.keepCommands[0].encoded(), Data([0x08, 0x03, 0x10, 0x01, 0x1a, 0x01, 0x01]))
        XCTAssertTrue(c.diagnostics.keepRequestSent); XCTAssertTrue(c.diagnostics.keepAcknowledged)
        XCTAssertTrue(c.diagnostics.remoteACK); XCTAssertEqual(io.maxWrites, 1)
        XCTAssertFalse(io.packets[2].payload == Data([1]), "the keep body uses the authenticated session cipher")
        c.stop(); await settleCoordinator()
        XCTAssertFalse(c.diagnostics.keepRequestSent); XCTAssertFalse(c.diagnostics.keepAcknowledged)
    }

    @MainActor func testRemoteIdleAlarmCannotRetireKeptSessionOrCreateAnotherAcquisition() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        var hints = 0; c.onRemoteReady = { _, _ in hints += 1 }
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        // Recovered Android alarm closes an unkept Bluetooth connection after20s.
        _ = clock.schedule(at: clock.now + 20) { if !io.remoteKeepsConnection { io.terminal?(.closed) } }
        clock.advance(90); await settleCoordinator()
        XCTAssertTrue(c.diagnostics.authenticated); XCTAssertEqual(io.opened, 1)
        XCTAssertEqual(io.keepCommands.count, 1); XCTAssertEqual(io.commands.count, 1)
        let peer = try XCTUnwrap(io.responder)
        io.emit(try peer.encodeCommand(.init(commandID: 10, type: 3, payload: Data()), handlerID: 1))
        await settleCoordinator(); XCTAssertEqual(hints, 1)
        c.lostMac(); await settleCoordinator(); clock.advance(90); await settleCoordinator()
        XCTAssertEqual(io.keepCommands.count, 1); XCTAssertEqual(io.commands.count, 1)
        c.stop(); await settleCoordinator()
    }

    @MainActor func testKeepReplyNeverGrantsBudsAckOrReturnIntentAndMalformedFormsAreIgnored() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.keepAck = false; io.ack = false
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        var hints = 0; c.onRemoteReady = { _, _ in hints += 1 }
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        let peer = try XCTUnwrap(io.responder)
        for command in [SamsungPeerWire.Command(commandID: 3, type: 2, payload: Data([1])),
                        .init(commandID: 3, type: 1, payload: Data()),
                        .init(commandID: 3, type: 1, payload: Data([2])),
                        .init(commandID: 3, type: 3, payload: Data())] {
            io.emit(try peer.encodeCommand(command, handlerID: 100))
        }
        await settleCoordinator(); XCTAssertFalse(c.diagnostics.keepAcknowledged)
        XCTAssertEqual(c.diagnostics.ignoredCommands, 4); XCTAssertEqual(io.keepCommands.count, 1)
        io.emit(try peer.encodeCommand(.init(commandID: 3, type: 2, payload: Data()), handlerID: 100))
        io.emit(try peer.encodeCommand(.init(commandID: 10, type: 3, payload: Data()), handlerID: 1))
        await settleCoordinator()
        XCTAssertTrue(c.diagnostics.keepAcknowledged); XCTAssertFalse(c.diagnostics.remoteACK)
        XCTAssertEqual(hints, 0); XCTAssertEqual(c.diagnostics.switchResponsesSent, 0)
        c.stop(); await settleCoordinator()
    }

    @MainActor func testPeerKeepChangesReceiveOneSerializedResponseEachWithoutAudioRequests() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.connectSelected(); await settleCoordinator()
        let peer = try XCTUnwrap(io.responder)
        // false is the initial peer flag: only true and the later false change it.
        for value: UInt8 in [0, 1, 1, 0, 0] {
            io.emit(try peer.encodeCommand(.init(commandID: 3, type: 1, payload: Data([value])), handlerID: 100))
        }
        await settleCoordinator()
        XCTAssertEqual(io.keepCommands.filter { $0.type == 2 },
                       Array(repeating: .init(commandID: 3, type: 2, payload: Data()), count: 2))
        XCTAssertEqual(c.diagnostics.keepResponsesSent, 2)
        XCTAssertTrue(io.commands.isEmpty); XCTAssertEqual(io.maxWrites, 1)
        XCTAssertEqual(c.diagnostics.incomingSwitchRequests, 0)
        c.stop(); await settleCoordinator()
    }

    @MainActor func testStopDuringAcceptedKeepWriteCannotSubmitLateBudsRequest() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdKeep = true
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertNotNil(io.keepGate); XCTAssertTrue(io.commands.isEmpty)
        c.stop(); let gate = io.keepGate; io.keepGate = nil; gate?.resume()
        await settleCoordinator(); clock.advance(90); await settleCoordinator()
        XCTAssertTrue(io.commands.isEmpty); XCTAssertEqual(c.diagnostics.phase, .closed)
        XCTAssertFalse(c.diagnostics.keepAcknowledged); XCTAssertEqual(io.opened, 1)
    }

    @MainActor func testRepeatedAcquisitionsReuseOneKeepLeaseWithoutPeriodicCommands() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.start(); await settleCoordinator()
        for _ in 0..<3 {
            c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
            c.lostMac(); await settleCoordinator()
        }
        XCTAssertEqual(io.commands.count, 3); XCTAssertEqual(io.keepCommands.count, 1)
        clock.advance(120); await settleCoordinator()
        XCTAssertEqual(io.commands.count, 3); XCTAssertEqual(io.keepCommands.count, 1)
        XCTAssertEqual(io.opened, 1); c.stop(); await settleCoordinator()
    }

    @MainActor func testFailedKeepWriteCannotSubmitBudsRequestOrLeaveFalseLease() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.failKeep = true
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(c.diagnostics.phase, .failed); XCTAssertTrue(io.commands.isEmpty)
        XCTAssertFalse(c.diagnostics.keepRequestSent); XCTAssertFalse(c.diagnostics.keepAcknowledged)
        clock.advance(90); await settleCoordinator(); XCTAssertEqual(io.opened, 1)
        c.stop(); await settleCoordinator()
    }

    @MainActor func testNewAuthenticatedConnectionRenewsKeepWithoutAutomaticAcquisitionRetry() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let c = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        c.start(); c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(io.keepCommands.count, 1)
        io.terminal?(.closed); await settleCoordinator()
        XCTAssertFalse(c.diagnostics.keepRequestSent); XCTAssertFalse(c.diagnostics.keepAcknowledged)
        clock.advance(90); await settleCoordinator(); XCTAssertEqual(io.opened, 1)
        c.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        for _ in 0..<3 { await settleCoordinator() }
        XCTAssertEqual(io.opened, 2); XCTAssertEqual(io.keepCommands.count, 2)
        XCTAssertEqual(io.commands.count, 2); XCTAssertTrue(c.diagnostics.keepAcknowledged)
        c.stop(); await settleCoordinator()
    }

    @MainActor func testReadyHintsRequireCurrentAuthenticatedAckedAcquisitionAndDeduplicate() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        var hints: [(UUID, String)] = []
        coordinator.onRemoteReady = { hints.append(($0, $1)) }
        coordinator.connectSelected(); await settleCoordinator()
        let responder = try XCTUnwrap(io.responder)
        func ready(type: Int32 = 3, payload: Data = Data()) throws {
            io.emit(try responder.encodeCommand(.init(commandID: 10, type: type, payload: payload), handlerID: 1))
        }
        try ready(); await settleCoordinator(); XCTAssertTrue(hints.isEmpty)
        let epoch = UUID(), address = "AA:BB:CC:DD:EE:FE"
        io.ack = false
        coordinator.acquiredMac(epoch: epoch, budsAddress: address); await settleCoordinator()
        try ready(); await settleCoordinator(); XCTAssertTrue(hints.isEmpty, "Acquisition READY before ACK is not return intent")
        let buds = try NativeSamsungPeerCoordinator.address(address)
        io.emit(try responder.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: buds).command(), handlerID: 1))
        await settleCoordinator()
        try ready(type: 1); try ready(payload: Data([1])); await settleCoordinator()
        XCTAssertTrue(hints.isEmpty)
        try ready(); try ready(); await settleCoordinator()
        XCTAssertEqual(hints.count, 1); XCTAssertEqual(hints.first?.0, epoch); XCTAssertEqual(hints.first?.1, address)
        coordinator.lostMac(); try ready(); await settleCoordinator(); XCTAssertEqual(hints.count, 1)
        let next = UUID(); io.ack = true
        coordinator.acquiredMac(epoch: next, budsAddress: address); await settleCoordinator()
        try ready(); await settleCoordinator(); XCTAssertEqual(hints.count, 2); XCTAssertEqual(hints.last?.0, next)
        XCTAssertEqual(coordinator.diagnostics.correlatedReadyEvents, 2)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testOtherKnownAccountPhonesAreRejectedBeforeSelectedPhoneGetsAnyCommand() async throws {
        let material = try coordinatorMaterial(phones: ["22:34:56:78:9A:BC", "32:34:56:78:9A:BC"])
        let clock = CoordinatorClock(); var transports: [CoordinatorFakeTransport] = []
        let other = try NativeSamsungPeerCoordinator.address("32:34:56:78:9A:BC")
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            let io = CoordinatorFakeTransport(material, clock: clock); io.canRejectUnexpected = true; io.rejectEmitsClose = true
            if transports.count < 2 { io.claimedPhoneAddress = other }
            transports.append(io); return io
        }, clock: clock, wallNow: { self.now }, savedSelectedPhone: "22:34:56:78:9A:BC")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        for _ in 0..<5 { await settleCoordinator() }
        XCTAssertEqual(transports.count, 3)
        XCTAssertTrue(transports[0].commands.isEmpty); XCTAssertTrue(transports[1].commands.isEmpty)
        XCTAssertEqual(transports[0].rejectedCandidates, 1); XCTAssertEqual(transports[1].rejectedCandidates, 1)
        XCTAssertEqual(transports[2].learnedExpectedCandidates, 1)
        XCTAssertEqual(transports[2].commands.count, 1); XCTAssertTrue(coordinator.diagnostics.remoteACK)
        XCTAssertEqual(coordinator.diagnostics.candidateAttempts, 3)
        XCTAssertEqual(coordinator.diagnostics.candidateRejections, 2)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testKnownWrongCandidateRetriesAreBoundedAndUnknownIdentityNeverRetries() async throws {
        for known in [true, false] {
            let material = try coordinatorMaterial(phones: ["22:34:56:78:9A:BC", "32:34:56:78:9A:BC"])
            let clock = CoordinatorClock(); var transports: [CoordinatorFakeTransport] = []
            let other = try NativeSamsungPeerCoordinator.address("32:34:56:78:9A:BC")
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
                let io = CoordinatorFakeTransport(material, clock: clock); io.canRejectUnexpected = true; io.rejectEmitsClose = true
                if known { io.claimedPhoneAddress = other } else { io.wrongPhone = true }
                transports.append(io); return io
            }, clock: clock, wallNow: { self.now }, savedSelectedPhone: "22:34:56:78:9A:BC")
            coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
            for _ in 0..<5 { await settleCoordinator() }
            XCTAssertEqual(transports.count, known ? 3 : 1)
            XCTAssertTrue(transports.allSatisfy { $0.commands.isEmpty && $0.learnedExpectedCandidates == 0 })
            XCTAssertEqual(coordinator.diagnostics.phase, .failed)
            XCTAssertEqual(coordinator.diagnostics.protocolFailure, known ? .unexpectedAddress : .unknownAddress)
            clock.advance(60); await settleCoordinator(); XCTAssertEqual(transports.count, known ? 3 : 1)
            coordinator.stop(); await settleCoordinator()
        }
    }
    @MainActor func testLocalPlayRetiresOldPauseReceiptBeforeNextMacOwnership() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE"), epoch = UUID()
        coordinator.start(); coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); coordinator.lostMac()
        coordinator.macYieldPrepared(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        coordinator.localPlaybackResumed()
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "a delayed phone request cannot reuse the retired pause receipt")
        coordinator.macYieldPrepared(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertEqual(io.responses.count, 1)
        coordinator.stop(); await settleCoordinator()
    }
    @MainActor func testProductionYieldReceiptRequiresLostMacAndCapturedAcquisitionUUID() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        let old = UUID(), current = UUID()
        coordinator.start(); coordinator.acquiredMac(epoch: old, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); coordinator.lostMac()
        coordinator.acquiredMac(epoch: current, budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        try io.request(buds); await settleCoordinator()
        coordinator.macYieldPrepared(epoch: current, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertTrue(io.responses.isEmpty, "current Mac ownership cannot attest a yielded route")
        coordinator.lostMac()
        coordinator.macYieldPrepared(epoch: old, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertTrue(io.responses.isEmpty, "old callback cannot adopt the new acquisition")
        coordinator.macYieldPrepared(epoch: current, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        coordinator.stop(); await settleCoordinator()
    }
    /// Strict synthetic certificate/owned-key validation produces the SAME typed
    /// material as production, using an in-memory vault, never Keychain or HTTP.
    func coordinatorMaterial(phones: [String] = ["22:34:56:78:9A:BC"]) throws -> C.PeerMaterial {
        let key = try key(); var object = try object(key)
        var devices = object["deviceInfoList"] as! [[String: Any]]
        for (index, address) in phones.enumerated() {
            devices.append(["dvcId": "synthetic-phone-\(index)", "deviceType": "phone", "deviceName": "Roster phone \(index)",
                "deviceModel": "SYNTHETIC", "btAddr": address, "irk": Data(repeating: 0x45, count: 16).base64EncodedString()])
        }
        object["deviceInfoList"] = devices
        let identity = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: "12:34:56:78:9A:BC", applicationIdentity: Data(repeating: 0x41, count: 16))
        return try C.preparedPeerMaterial(session: session(), identity: identity,
            vault: CertificateMemoryVault(key: key, data: encode(object)), now: now)
    }
    @MainActor private func settleCoordinator() async { for _ in 0..<150 { await Task.yield() } }

    @MainActor func testCoordinatorFinalWriteThenAuthenticatedSwitchRealCodecACKAndConnectionReuse() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinal = true
        var reads = 0, factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { reads += 1; return material }, transportFactory: { factories += 1; return io }, clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        XCTAssertEqual(reads, 1); XCTAssertEqual(io.opened, 0)
        let epoch = UUID(); coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        XCTAssertNotNil(io.finalGate); XCTAssertFalse(coordinator.diagnostics.authenticated)
        XCTAssertTrue(io.commands.isEmpty)
        io.releaseFinal(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated)
        XCTAssertTrue(coordinator.diagnostics.requestSent); XCTAssertTrue(coordinator.diagnostics.remoteACK)
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        XCTAssertEqual(io.commands, [.request(advertisingID: buds.advertisingID, address: buds, reason: .media)])
        coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        coordinator.refreshRoster(); await settleCoordinator()
        XCTAssertEqual(io.commands.count, 1)
        coordinator.lostMac(); XCTAssertTrue(coordinator.diagnostics.authenticated)
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(io.commands.count, 2); XCTAssertEqual(io.opened, 1); XCTAssertEqual(factories, 1)
        XCTAssertEqual(io.packets.filter { $0.handlerID == 0 }.count, 2)
        XCTAssertEqual(io.maxWrites, 1); XCTAssertEqual(reads, 4)
        coordinator.stop(); await settleCoordinator(); XCTAssertFalse(coordinator.diagnostics.authenticated)
    }
    @MainActor func testCoordinatorOwnershipLossBeforeFinalSendNeverSendsStaleSwitch() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let transport = CoordinatorFakeTransport(material, clock: clock); transport.holdFinal = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { transport }, clock: clock, wallNow: { self.now })
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertNotNil(transport.finalGate)
        coordinator.lostMac(); transport.releaseFinal(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated); XCTAssertTrue(transport.commands.isEmpty)
        coordinator.stop(); await settleCoordinator()
    }
    @MainActor func testCoordinatorStopAndLateFinalCompletionCannotAuthenticateOrSwitch() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinal = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        coordinator.stop(accountChanged: true); io.releaseFinal(); await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.phase, .closed); XCTAssertEqual(coordinator.diagnostics.failure, .accountChanged)
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertTrue(io.commands.isEmpty); XCTAssertGreaterThan(io.closed, 0)
    }
    @MainActor func testCoordinatorSilentHandshakeTimeoutAndRealWallClockKUExpiry() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.silent = true
        var wall = now
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { wall })
        coordinator.connectSelected(); await settleCoordinator()
        clock.advance(10); await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.failure, .handshakeTimeout); XCTAssertGreaterThan(io.closed, 0)
        io.silent = false; coordinator.connectSelected(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated)
        wall = Date(timeIntervalSince1970: Double(material.accountKey.expireTime) / 1000)
        clock.advance(0.25); await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.failure, .expiredKey); XCTAssertFalse(coordinator.diagnostics.authenticated)
        coordinator.stop()
    }
    @MainActor func testCoordinatorOnlyExpectedPhoneAuthenticates() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.wrongPhone = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertEqual(coordinator.diagnostics.failure, .authentication)
        XCTAssertTrue(io.commands.isEmpty); coordinator.stop()
    }
    @MainActor func testCoordinatorBoundedQueueAndTerminationFence() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinal = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        let reply = try XCTUnwrap(io.lastAuthReply)
        for _ in 0..<64 { io.emit(reply) }
        XCTAssertEqual(coordinator.diagnostics.queuedPackets, 64)
        io.emit(reply); XCTAssertEqual(coordinator.diagnostics.failure, .packetLimit)
        io.releaseFinal(); await settleCoordinator()
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertEqual(coordinator.diagnostics.queuedPackets, 0)
        coordinator.stop()
    }
    @MainActor func testCoordinatorProviderIsSingleBoundedAndLateMaterialAfterAccountChangeIsDiscarded() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var gate: CheckedContinuation<C.PeerMaterial, Never>?, reads = 0, factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1; return await withCheckedContinuation { gate = $0 }
        }, transportFactory: { factories += 1; return CoordinatorFakeTransport(material, clock: clock) }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        for _ in 0..<100 { coordinator.refreshRoster() }
        XCTAssertEqual(reads, 1)
        clock.advance(15); await settleCoordinator(); XCTAssertEqual(coordinator.diagnostics.failure, .materialUnavailable)
        coordinator.stop(accountChanged: true); coordinator.connectSelected(); await settleCoordinator()
        XCTAssertEqual(reads, 1)
        gate?.resume(returning: material); await settleCoordinator()
        XCTAssertEqual(factories, 0); XCTAssertTrue(coordinator.phones.isEmpty); XCTAssertFalse(coordinator.diagnostics.authenticated)
        coordinator.stop()
    }
    @MainActor func testCoordinatorRosterDoesNotGuessAndPreservesExplicitPreference() async throws {
        var material = try coordinatorMaterial(phones: ["22:34:56:78:9A:BC", "32:34:56:78:9A:BC"])
        let clock = CoordinatorClock(); var factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            factories += 1; return CoordinatorFakeTransport(material, clock: clock)
        }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertEqual(coordinator.phones.count, 2); XCTAssertEqual(coordinator.selectedPhone, ""); XCTAssertEqual(factories, 0)
        coordinator.selectPhone("32:34:56:78:9A:BC"); coordinator.connectSelected(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated)
        material = try coordinatorMaterial(); coordinator.refreshRoster(); await settleCoordinator()
        XCTAssertEqual(coordinator.selectedPhone, "32:34:56:78:9A:BC")
        XCTAssertEqual(coordinator.phones.count, 1); XCTAssertFalse(coordinator.diagnostics.authenticated)
        XCTAssertEqual(factories, 1); coordinator.stop()
    }
    @MainActor func testSavedPhonePreferenceMustBeInCurrentRosterBeforeAnyConnection() async throws {
        let material = try coordinatorMaterial(phones: ["22:34:56:78:9A:BC", "32:34:56:78:9A:BC"])
        let clock = CoordinatorClock(); var opened = 0; var saved: [String] = []
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            opened += 1; return CoordinatorFakeTransport(material, clock: clock)
        }, clock: clock, wallNow: { self.now }, savedSelectedPhone: "42:34:56:78:9A:BC", persistSelection: { saved.append($0) })
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertEqual(opened, 0, "A remembered choice is a hint, never admission to the new account roster")
        XCTAssertEqual(coordinator.diagnostics.failure, .noSelectedPhone)
        coordinator.selectPhone("42:34:56:78:9A:BC")
        XCTAssertTrue(saved.isEmpty)
        coordinator.selectPhone("32:34:56:78:9A:BC"); coordinator.connectSelected(); await settleCoordinator()
        XCTAssertEqual(saved, ["32:34:56:78:9A:BC"])
        XCTAssertEqual(opened, 1); XCTAssertTrue(coordinator.diagnostics.authenticated)
        coordinator.stop()
    }

    @MainActor func testCoordinatorRevisionOverflowFailsClosedAndDiagnosticsHaveNoIdentity() async throws {
        let valid = try coordinatorMaterial(), clock = CoordinatorClock()
        let invalid = C.PeerMaterial(ownClassicAddress: valid.ownClassicAddress, accountKey: valid.accountKey,
            revision: Int(Int32.max) + 1, phones: valid.phones, identityMode: valid.identityMode)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { invalid }, transportFactory: {
            XCTFail("invalid material must never open"); return CoordinatorFakeTransport(valid, clock: clock)
        }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.failure, .invalidMaterial)
        let json = String(decoding: try JSONEncoder().encode(coordinator.diagnostics), as: UTF8.self)
        for secret in [valid.ownClassicAddress, valid.phones[0].address, valid.phones[0].name, valid.accountKey.bytes.base64EncodedString()] { XCTAssertFalse(json.contains(secret)) }
        coordinator.stop()
    }
    @MainActor func testCoordinatorUnknownAndIncomingSwitchCannotInventOwnershipOrACK() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        let responder = try XCTUnwrap(io.responder), buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        io.emit(try responder.encodeCommand(.init(commandID: 999, type: 1, payload: Data()), handlerID: 99))
        io.emit(try responder.encodeCommand(SamsungPeerBudsSwitch.request(advertisingID: buds.advertisingID, address: buds, reason: .media).command(), handlerID: 1))
        io.emit(try responder.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: buds).command(), handlerID: 1))
        await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated); XCTAssertFalse(coordinator.diagnostics.remoteACK)
        XCTAssertEqual(coordinator.diagnostics.ignoredCommands, 1); XCTAssertTrue(io.commands.isEmpty)
        io.terminal?(.closed); await settleCoordinator()
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertEqual(coordinator.diagnostics.failure, .transport)
        coordinator.stop()
    }
}

final class NativeSamsungPeerCoordinatorOwnershipTests: XCTestCase {
    func testForeground132PublishesOwnershipOnceButBackground132CannotAcquire() {
        var gate = NativeSamsungPeerCoordinatorOwnership()
        let foreground = SamsungMdePacket.MultipointStatus(state: .foreground, streamType: .a2dp, reason: 132)
        let background = SamsungMdePacket.MultipointStatus(state: .background, streamType: .a2dp, reason: 132)
        XCTAssertNil(gate.update(enabled: true, ownsMac: false, status: foreground).acquired)
        let epoch = gate.update(enabled: true, ownsMac: true, status: foreground).acquired
        XCTAssertNotNil(epoch)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: foreground).acquired)
        XCTAssertTrue(gate.update(enabled: true, ownsMac: false, status: background).lost)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: background).acquired)
    }
    func testExactStreamOneAndOneEventPerActualOwnershipEpoch() {
        var gate = NativeSamsungPeerCoordinatorOwnership()
        let foreground = SamsungMdePacket.MultipointStatus(state: .foreground, streamType: .a2dp, reason: 0)
        let pending = SamsungMdePacket.MultipointStatus(state: .foreground, streamType: .autoSwitchRequest, reason: 0)
        XCTAssertNil(gate.update(enabled: true, ownsMac: false, status: foreground).acquired)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: pending).acquired)
        let first = gate.update(enabled: true, ownsMac: true, status: foreground).acquired
        XCTAssertNotNil(first)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: foreground).acquired)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: pending).acquired)
        XCTAssertNil(gate.update(enabled: true, ownsMac: true, status: foreground).acquired)
        XCTAssertTrue(gate.update(enabled: true, ownsMac: false, status: foreground).lost)
        XCTAssertNotEqual(gate.update(enabled: true, ownsMac: true, status: foreground).acquired, first)
        XCTAssertTrue(gate.update(enabled: false, ownsMac: true, status: foreground).lost)
        XCTAssertNotNil(gate.update(enabled: true, ownsMac: true, status: foreground).acquired)
    }
    @MainActor func testModelCallbackWaitsForActualOwnershipAndStreamOneAndRefreshKeepsRoster() async {
        let h = NativeControllerHarness()
        let controller = await h.start()
        var acquired = 0, lost = 0
        controller.onMacAcquired = { _, _ in acquired += 1 }; controller.onMacOwnershipLost = { lost += 1 }
        controller.phones = [.init(id: "synthetic", name: "Roster")]; controller.selectedPhone = "synthetic"
        h.play(); await h.advance(0.2)
        h.notify(stream: .autoSwitchRequest); await h.advance(0.15)
        XCTAssertEqual(controller.route, "Mac"); XCTAssertEqual(acquired, 0)
        h.notify(); await h.settle(); XCTAssertEqual(acquired, 1)
        h.notify(); await h.settle(); XCTAssertEqual(acquired, 1)
        h.notify(.background); await h.settle(); XCTAssertEqual(lost, 1)
        await h.stop(controller)
        await controller.refresh()
        XCTAssertEqual(controller.phones.first?.id, "synthetic"); XCTAssertEqual(controller.selectedPhone, "synthetic")
    }
}

private final class CoordinatorConcreteChannel: NativeSamsungPeerChannel {
    var receiver: NativeSamsungPeerOperation?
}
@MainActor private final class CoordinatorConcreteEffects: NativeSamsungPeerEffects {
    let material: SamsungCloudCertificate.PeerMaterial
    let clock: CoordinatorClock
    let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification)
    let channel = CoordinatorConcreteChannel()
    var responder: SamsungPeerSession?
    var decoder = SamsungPeerWire.FrameDecoder()
    var heldFinal: NativeSamsungPeerOperation?
    var closeCount = 0
    var completeFrames = 0
    var holdFinal = true
    init(_ material: SamsungCloudCertificate.PeerMaterial, _ clock: CoordinatorClock) { self.material = material; self.clock = clock }
    func start(_ request: NativeSamsungPeerRequest, operation: NativeSamsungPeerOperation) {
        do {
            switch request {
            case .connect(let peer):
                let own = try NativeSamsungPeerCoordinator.address(material.ownClassicAddress)
                responder = try SamsungPeerSession(role: .responder, accountKey: material.accountKey.bytes,
                    localAddress: peer.address, roster: .init(revision: Int32(material.revision), members: [own, peer.address]),
                    expectedPeer: own, crypto: crypto)
                _ = try responder?.start(now: clock.now)
                operation.onReturn(true, nil, nil); operation.onResult(.connected(true))
            case .discover:
                operation.onReturn(true, nil, nil); operation.onResult(.discovered(success: true, recordChannel: 7))
            case .open:
                channel.receiver = operation
                operation.onReturn(true, channel, nil); operation.onResult(.opened(channel, success: true, mtu: 17))
            case .write(let channel, let buffer):
                var final = false
                try decoder.append(buffer.bytes as Data) { packet in
                    completeFrames += 1
                    let responder = try XCTUnwrap(responder)
                    if packet.handlerID == 0 {
                        let auth = try SamsungPeerWire.Authentication.decode(crypto.openAccount(packet.payload, accountKey: material.accountKey.bytes))
                        final = auth.command == 3
                        if let reply = try responder.receiveAuthentication(packet, now: clock.now) {
                            self.channel.receiver?.onBytes(self.channel, try SamsungPeerWire.frame(reply))
                        }
                    } else { _ = try responder.receiveCommand(packet) }
                }
                operation.onReturn(true, nil, nil)
                if final && holdFinal { heldFinal = operation }
                else { operation.onResult(.written(channel: channel, id: operation.id, success: true, bytesWritten: buffer.bytes.length)) }
            }
        } catch { XCTFail("synthetic effects failed: \(type(of: error))"); operation.onReturn(false, nil, nil) }
    }
    func close(_ channel: any NativeSamsungPeerChannel, completion: @escaping @MainActor (Bool) -> Void) {
        closeCount += 1; completion(true)
    }
    func releaseFinal() {
        guard let operation = heldFinal, case .write(let channel, let buffer) = operation.request else { XCTFail("no held final write"); return }
        heldFinal = nil
        operation.onResult(.written(channel: channel, id: operation.id, success: true, bytesWritten: buffer.bytes.length))
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testCoordinatorConcreteTransportRetainsSharedDrainThroughStoppedFinalWrite() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock(), drain = NativeSamsungPeerOperationDrain()
        let effects = CoordinatorConcreteEffects(material, clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            NativeSamsungPeerTransport(effects: effects, clock: clock, drain: drain)
        }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertNotNil(effects.heldFinal); XCTAssertEqual(effects.completeFrames, 2)
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertEqual(drain.count, 1)
        coordinator.stop(); await settleCoordinator()
        XCTAssertEqual(drain.count, 1, "an accepted final chunk still owns the phone profile after Stop")
        XCTAssertEqual(effects.closeCount, 1)
        effects.releaseFinal(); await settleCoordinator()
        XCTAssertEqual(drain.count, 0); XCTAssertFalse(coordinator.diagnostics.authenticated)
        effects.holdFinal = false
        coordinator.connectSelected(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated); XCTAssertEqual(drain.count, 1)
        coordinator.stop(); await settleCoordinator(); XCTAssertEqual(drain.count, 0)
    }
    @MainActor func testCoordinatorLateOpenAfterStopAndManyRequestsCannotMultiplyWorkers() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let first = CoordinatorFakeTransport(material, clock: clock); first.holdOpen = true
        let next = CoordinatorFakeTransport(material, clock: clock)
        var factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            factories += 1; return factories == 1 ? first : next
        }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator(); XCTAssertNotNil(first.openGate)
        coordinator.stop()
        for _ in 0..<100 { coordinator.connectSelected() }
        await settleCoordinator(); XCTAssertEqual(factories, 1)
        first.releaseOpen(); await settleCoordinator()
        XCTAssertTrue(first.packets.isEmpty); XCTAssertEqual(factories, 2)
        XCTAssertTrue(coordinator.diagnostics.authenticated)
        coordinator.stop(); await settleCoordinator()
    }
    @MainActor func testCoordinatorOwnerDeinitClosesIdleFullDuplexSession() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var coordinator: NativeSamsungPeerCoordinator? = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator?.connectSelected(); await settleCoordinator(); XCTAssertTrue(coordinator?.diagnostics.authenticated == true)
        weak var observer = coordinator
        coordinator = nil; await settleCoordinator()
        XCTAssertNil(observer); XCTAssertGreaterThan(io.closed, 0)
    }
    @MainActor func testCoordinatorRevisionChangeClosesAndAuthenticatesFreshSessionWithoutStaleCommand() async throws {
        var material = try coordinatorMaterial(), transports: [CoordinatorFakeTransport] = []
        let clock = CoordinatorClock()
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            let io = CoordinatorFakeTransport(material, clock: clock); transports.append(io); return io
        }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator(); XCTAssertTrue(coordinator.diagnostics.authenticated)
        material = C.PeerMaterial(ownClassicAddress: material.ownClassicAddress, accountKey: material.accountKey,
            revision: material.revision + 1, phones: material.phones, identityMode: material.identityMode)
        coordinator.refreshRoster(); await settleCoordinator()
        XCTAssertEqual(transports.count, 2); XCTAssertGreaterThan(transports[0].closed, 0)
        XCTAssertTrue(coordinator.diagnostics.authenticated); XCTAssertTrue(transports.allSatisfy { $0.commands.isEmpty })
        coordinator.stop(); await settleCoordinator()
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testCoordinatorTerminationCancelsConcurrentRefreshAndLateReadCannotReopen() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var reads = 0, factories = 0
        var gate: CheckedContinuation<C.PeerMaterial, Never>?
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1
            if reads > 1 { return await withCheckedContinuation { gate = $0 } }
            return material
        }, transportFactory: { factories += 1; return io }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator(); XCTAssertTrue(coordinator.diagnostics.authenticated)
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertNotNil(gate); XCTAssertTrue(io.commands.isEmpty, "a new handoff waits for the fresh legitimate material read")
        io.terminal?(.closed); await settleCoordinator()
        gate?.resume(returning: material); await settleCoordinator()
        XCTAssertEqual(factories, 1); XCTAssertFalse(coordinator.diagnostics.authenticated)
        XCTAssertEqual(coordinator.diagnostics.failure, .transport); XCTAssertTrue(io.commands.isEmpty)
        coordinator.stop()
    }
    @MainActor func testCoordinatorRequestSentDoesNotImplyACKAndOnlyMatchingSuccessCounts() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.ack = false
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.requestSent); XCTAssertFalse(coordinator.diagnostics.remoteACK)
        let responder = try XCTUnwrap(io.responder), buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        let other = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FC")
        for response: SamsungPeerBudsSwitch in [.successResponse(address: other),
                .response(success: 0, advertisingID: buds.advertisingID, address: buds),
                .response(success: 1, advertisingID: buds.advertisingID ^ 1, address: buds)] {
            io.emit(try responder.encodeCommand(response.command(), handlerID: 1))
        }
        await settleCoordinator(); XCTAssertFalse(coordinator.diagnostics.remoteACK)
        io.emit(try responder.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: buds).command(), handlerID: 1))
        await settleCoordinator(); XCTAssertTrue(coordinator.diagnostics.remoteACK)
        coordinator.lostMac()
        io.emit(try responder.encodeCommand(SamsungPeerBudsSwitch.successResponse(address: buds).command(), handlerID: 1))
        await settleCoordinator(); XCTAssertFalse(coordinator.diagnostics.remoteACK)
        coordinator.stop(); await settleCoordinator()
    }
}

extension NativeSamsungPeerCoordinatorOwnershipTests {
    @MainActor func testModelDeinitStopsPeerLifecycle() async {
        let h = NativeControllerHarness()
        var controller: NativeAutoSwitchModel? = await h.start()
        var stops = 0
        controller?.onPeerLifecycle = { active in if !active { stops += 1 } }
        controller = nil; await h.settle()
        XCTAssertEqual(stops, 1)
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testOwnedContextWaitsForAuthenticationAndIsRenewedOnlyPerOwnership() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinal = true
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { value in
                XCTAssertEqual(value.ownClassicAddress, material.ownClassicAddress)
                contexts += 1; return Data([0x02, 0x18, UInt8(contexts)])
            })
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        XCTAssertNotNil(io.finalGate); XCTAssertEqual(contexts, 0)
        XCTAssertFalse(coordinator.diagnostics.ownedContextSent)
        io.releaseFinal(); await settleCoordinator()
        XCTAssertEqual(contexts, 1); XCTAssertTrue(coordinator.diagnostics.ownedContextSent)
        XCTAssertEqual(io.packets.last?.advertisement, Data([2, 24, 1]))
        coordinator.refreshRoster(); await settleCoordinator(); XCTAssertEqual(contexts, 1)
        coordinator.lostMac(); XCTAssertFalse(coordinator.diagnostics.ownedContextSent)
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(contexts, 2); XCTAssertEqual(io.packets.last?.advertisement, Data([2, 24, 2]))
        XCTAssertTrue(coordinator.diagnostics.remoteACK)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testOwnedContextFailureSendsNoBudsCommandAndDoesNotRetry() async throws {
        enum SyntheticFailure: Error { case unavailable }
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { _ in
                contexts += 1; throw SyntheticFailure.unavailable
            })
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        XCTAssertEqual(contexts, 1); XCTAssertTrue(io.commands.isEmpty)
        XCTAssertFalse(coordinator.diagnostics.requestSent); XCTAssertFalse(coordinator.diagnostics.ownedContextSent)
        XCTAssertEqual(coordinator.diagnostics.phase, .failed)
        clock.advance(30); await settleCoordinator(); XCTAssertEqual(contexts, 1)
        coordinator.stop(); await settleCoordinator()
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testCoordinatorIncomingSwitchWaitsForAttestationAfterLossAndDeduplicatesEpoch() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE"), epoch = UUID()
        coordinator.start(); coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        try io.request(buds); await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.incomingSwitchRequests, 1)
        XCTAssertTrue(io.responses.isEmpty, "a matching request alone cannot attest pause or routing")
        coordinator.lostMac(); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "ownership loss is not proof of a protected yield")
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        XCTAssertFalse(coordinator.diagnostics.requestSent); XCTAssertFalse(coordinator.diagnostics.remoteACK)
        for _ in 0..<8 { try io.request(buds, reason: .call) }
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE") // stale callback
        await settleCoordinator()
        XCTAssertEqual(io.responses.count, 1); XCTAssertEqual(coordinator.diagnostics.switchResponsesSent, 1)
        XCTAssertEqual(coordinator.publicDiagnostics["incoming_switch_requests"] as? Int, 9)
        XCTAssertEqual(coordinator.publicDiagnostics["switch_responses_sent"] as? Int, 1)
        XCTAssertEqual(io.commands.count, 2, "inbound commands cannot acquire or cause another outbound request")
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorPreparedCurrentAcquisitionAcceptsLaterCallRequestWithFreshContext() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { value in
                XCTAssertEqual(value.accountKey.bytes, material.accountKey.bytes)
                contexts += 1; return Data([2, 24, UInt8(contexts)])
            })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator()
        let outgoing = try XCTUnwrap(io.packets.last)
        XCTAssertEqual(contexts, 1)
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty); XCTAssertEqual(contexts, 1)
        try io.request(buds, reason: .call); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        let response = try XCTUnwrap(io.packets.last)
        XCTAssertEqual(response.advertisement, Data([2, 24, 2]))
        XCTAssertEqual(response.sequence, outgoing.sequence + 1)
        XCTAssertEqual(contexts, 2); XCTAssertEqual(io.maxWrites, 1)
        XCTAssertTrue(coordinator.diagnostics.ownedContextSent)
        let json = String(decoding: try JSONEncoder().encode(coordinator.diagnostics), as: UTF8.self)
        XCTAssertFalse(json.contains("AA:BB:CC")); XCTAssertFalse(json.contains(material.phones[0].address))
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorIncomingSwitchCannotPassBlockedFinalAuthentication() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdFinalCompletion = true
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { _ in contexts += 1; return Data([2, 24, 1]) })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        await settleCoordinator(); XCTAssertNotNil(io.finalCompletionGate)
        // The completed-yield callback may precede the ownership-loss callback.
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try io.request(buds); await settleCoordinator()
        XCTAssertFalse(coordinator.diagnostics.authenticated); XCTAssertTrue(io.commands.isEmpty)
        XCTAssertEqual(contexts, 0); XCTAssertEqual(coordinator.diagnostics.queuedPackets, 1)
        io.releaseFinalCompletion(); await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated)
        XCTAssertEqual(io.commands, [.successResponse(address: buds)])
        XCTAssertEqual(contexts, 1); XCTAssertEqual(io.maxWrites, 1)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorIncomingSwitchRejectsNeverOwnedWrongAddressIDAndReason() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        let other = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FC")
        coordinator.connectSelected(); await settleCoordinator()
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.commands.isEmpty, "attestation cannot invent a never-owned acquisition")
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FC")
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "wrong-address attestation cannot authorize the retained request")
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try io.request(other, id: buds.advertisingID)
        try io.request(buds, id: buds.advertisingID ^ 1)
        let responder = try XCTUnwrap(io.responder)
        var invalid = SamsungPeerBudsSwitch.request(advertisingID: buds.advertisingID, address: buds, reason: .media).command().payload
        invalid[8] = 0
        io.emit(try responder.encodeCommand(.init(commandID: 1, type: 1, payload: invalid), handlerID: 1))
        io.emit(try responder.encodeCommand(.init(commandID: 1, type: 1, payload: invalid.prefix(8)), handlerID: 1))
        await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty); XCTAssertEqual(coordinator.diagnostics.ignoredCommands, 2)
        try io.request(buds, reason: .call); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorReadyStubEmptyEventsAreBoundedNoOpsWithoutDeviceStateFallback() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        coordinator.connectSelected(); await settleCoordinator()
        let responder = try XCTUnwrap(io.responder)
        for id: Int32 in [10, 11] {
            io.emit(try responder.encodeCommand(.init(commandID: id, type: 3, payload: Data()), handlerID: 1))
        }
        await settleCoordinator()
        XCTAssertEqual(coordinator.diagnostics.ignoredCommands, 0)
        XCTAssertEqual(coordinator.diagnostics.receivedKinds, ["h1_c10_t3": 1, "h1_c11_t3": 1])
        for (handler, id, type, payload): (Int32, Int32, Int32, Data) in [
            (1, 10, 3, Data([0])), (1, 11, 1, Data()), (1, 5, 1, Data()),
            (1, 999, 3, Data()), (99, 10, 3, Data()), (1, 10, 99, Data())] {
            io.emit(try responder.encodeCommand(.init(commandID: id, type: type, payload: payload), handlerID: handler))
        }
        await settleCoordinator()
        XCTAssertTrue(coordinator.diagnostics.authenticated); XCTAssertTrue(io.commands.isEmpty)
        XCTAssertEqual(coordinator.diagnostics.ignoredCommands, 6)
        XCTAssertEqual(coordinator.diagnostics.receivedKinds["other"], 3)
        XCTAssertEqual(coordinator.diagnostics.incomingSwitchRequests, 0)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorNewAcquisitionInvalidatesBothRequestAndPreparedReceipt() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE"), first = UUID()
        coordinator.start(); coordinator.acquiredMac(epoch: first, budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        try io.request(buds); await settleCoordinator()
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "new epoch cannot reuse the old request")
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "new epoch cannot reuse the old prepared receipt")
        coordinator.acquiredMac(epoch: first, budsAddress: "AA:BB:CC:DD:EE:FE") // stale old callback
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        XCTAssertEqual(io.commands.count, 4, "stale ownership callback cannot create another acquisition")
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorQueuedOldRequestCannotAdoptNewEpochAndWorkerStaysSingleWriter() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdCommand = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertNotNil(io.commandGate)
        try io.request(buds)
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE")
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertEqual(io.activeWrites, 1); XCTAssertTrue(io.responses.isEmpty)
        io.releaseCommand(); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty, "ingress epoch must survive queuing behind a suspended send")
        try io.request(buds); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)])
        XCTAssertEqual(io.maxWrites, 1)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorIncomingReplyQueuesBehindExistingWrite() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock); io.holdCommand = true
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        XCTAssertNotNil(io.commandGate)
        coordinator.lostMac(); coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        for _ in 0..<3 { try io.request(buds) }
        await settleCoordinator()
        XCTAssertEqual(io.activeWrites, 1); XCTAssertTrue(io.responses.isEmpty)
        io.releaseCommand(); await settleCoordinator()
        XCTAssertEqual(io.responses, [.successResponse(address: buds)]); XCTAssertEqual(io.maxWrites, 1)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorStopAccountChangeAndReconnectDiscardQueuedReplyAndStaleCallbacks() async throws {
        for accountChanged in [false, true] {
            let material = try coordinatorMaterial(), clock = CoordinatorClock()
            let first = CoordinatorFakeTransport(material, clock: clock); first.holdFinalCompletion = true
            let next = CoordinatorFakeTransport(material, clock: clock)
            var factories = 0
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
                factories += 1; return factories == 1 ? first : next
            }, clock: clock, wallNow: { self.now })
            let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE"), epoch = UUID()
            coordinator.start(); coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
            try first.request(buds)
            let latePacket = try XCTUnwrap(first.responder).encodeCommand(SamsungPeerBudsSwitch.request(
                advertisingID: buds.advertisingID, address: buds, reason: .media).command(), handlerID: 1)
            let lateReceive = first.receive, peer = try XCTUnwrap(first.peer)
            coordinator.lostMac(); coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
            coordinator.stop(accountChanged: accountChanged); coordinator.connectSelected(); await settleCoordinator()
            XCTAssertEqual(factories, 1, "old accepted final send must drain before a new worker opens")
            first.releaseFinalCompletion(); await settleCoordinator()
            XCTAssertEqual(factories, 2); XCTAssertTrue(coordinator.diagnostics.authenticated)
            lateReceive?(.init(expectedPeer: peer, packet: latePacket))
            coordinator.acquiredMac(epoch: epoch, budsAddress: "AA:BB:CC:DD:EE:FE") // obsolete ownership callback
            coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
            try next.request(buds); await settleCoordinator()
            XCTAssertTrue(first.commands.isEmpty); XCTAssertTrue(next.commands.isEmpty)
            XCTAssertEqual(coordinator.diagnostics.switchResponsesSent, 0)
            XCTAssertEqual(first.maxWrites, 1); XCTAssertEqual(next.maxWrites, 1)
            coordinator.stop(); await settleCoordinator()
        }
    }

    @MainActor func testCoordinatorTransportReconnectCannotReuseFormerOwnershipReceipt() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var transports: [CoordinatorFakeTransport] = []
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            let io = CoordinatorFakeTransport(material, clock: clock); transports.append(io); return io
        }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        let first = try XCTUnwrap(transports.first)
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        first.terminal?(.closed); await settleCoordinator()
        coordinator.connectSelected(); await settleCoordinator()
        let next = try XCTUnwrap(transports.last)
        XCTAssertEqual(transports.count, 2)
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try next.request(buds); await settleCoordinator()
        XCTAssertTrue(next.responses.isEmpty, "transport replacement retires the old incoming-response authority")
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorResponseContextFailureFailsClosedAndDoesNotRetry() async throws {
        enum SyntheticFailure: Error { case unavailable }
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { _ in
                contexts += 1
                if contexts > 1 { throw SyntheticFailure.unavailable }
                return Data([2, 24, 1])
            })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        coordinator.lostMac(); coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty); XCTAssertEqual(contexts, 2)
        XCTAssertEqual(coordinator.diagnostics.failure, .ownedContext)
        clock.advance(30); await settleCoordinator(); XCTAssertEqual(contexts, 2)
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorChecksEpochAgainAfterResponseContextProvider() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var invalidate: (() -> Void)?
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { _ in invalidate?(); return Data([2, 24, 1]) })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        invalidate = { coordinator.stop() }
        coordinator.lostMac(); coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try io.request(buds); await settleCoordinator()
        XCTAssertTrue(io.responses.isEmpty); XCTAssertEqual(coordinator.diagnostics.switchResponsesSent, 0)
        XCTAssertEqual(coordinator.diagnostics.phase, .closed)
        invalidate = nil; await settleCoordinator()
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testCoordinatorEachFreshAcquisitionAllowsExactlyOneFreshResponse() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        let io = CoordinatorFakeTransport(material, clock: clock)
        var contexts = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: { io },
            clock: clock, wallNow: { self.now }, ownedContextProvider: { _ in contexts += 1; return Data([2, 24, UInt8(contexts)]) })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start()
        for count in 1...2 {
            coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
            // Reacquisition itself does not authorize a response to another request.
            try io.request(buds); await settleCoordinator()
            XCTAssertEqual(io.responses.count, count - 1)
            coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
            coordinator.lostMac(); await settleCoordinator()
            try io.request(buds); await settleCoordinator()
            XCTAssertEqual(io.responses.count, count)
            XCTAssertEqual(coordinator.diagnostics.switchResponsesSent, count)
            XCTAssertEqual(io.packets.last?.advertisement, Data([2, 24, UInt8(count * 2)]))
        }
        XCTAssertEqual(contexts, 4); XCTAssertEqual(io.maxWrites, 1); XCTAssertEqual(io.opened, 1)
        let sequences = io.packets.filter { $0.handlerID == 1 }.map(\.sequence)
        XCTAssertEqual(sequences, [sequences[0], sequences[0] + 1, sequences[0] + 2, sequences[0] + 3])
        coordinator.stop(); await settleCoordinator()
    }

    @MainActor func testCoordinatorAccountMaterialReplacementRetiresPendingIncomingAndAttestation() async throws {
        var material = try coordinatorMaterial()
        let clock = CoordinatorClock()
        var transports: [CoordinatorFakeTransport] = []
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material }, transportFactory: {
            let io = CoordinatorFakeTransport(material, clock: clock); transports.append(io); return io
        }, clock: clock, wallNow: { self.now })
        let buds = try NativeSamsungPeerCoordinator.address("AA:BB:CC:DD:EE:FE")
        coordinator.start(); coordinator.acquiredMac(epoch: UUID(), budsAddress: "AA:BB:CC:DD:EE:FE"); await settleCoordinator()
        let first = try XCTUnwrap(transports.first)
        try first.request(buds); await settleCoordinator()
        coordinator.lostMac()
        material = C.PeerMaterial(ownClassicAddress: material.ownClassicAddress, accountKey: material.accountKey,
            revision: material.revision + 1, phones: material.phones, identityMode: material.identityMode)
        coordinator.refreshRoster(); await settleCoordinator()
        let next = try XCTUnwrap(transports.last)
        XCTAssertEqual(transports.count, 2); XCTAssertTrue(coordinator.diagnostics.authenticated)
        coordinator.macYieldPrepared(budsAddress: "AA:BB:CC:DD:EE:FE")
        try next.request(buds); await settleCoordinator()
        XCTAssertTrue(first.responses.isEmpty); XCTAssertTrue(next.commands.isEmpty)
        coordinator.stop(); await settleCoordinator()
    }
}

extension SamsungCloudCertificateTests {
    @MainActor func testOwnedMDEValidatedSyntheticMaterialReturnsOnlyGoldenDevicePacket() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var reads = 0, factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { reads += 1; return material },
            transportFactory: { factories += 1; return CoordinatorFakeTransport(material, clock: clock) },
            clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        let before = coordinator.diagnostics
        let packet = try await coordinator.ownedMDEConfiguration()
        // Provisioned HEX fixture 0123456789abcdef, not its UTF-8 or peer identity.
        // Independent Python hashlib / crc_hqx vector.
        XCTAssertEqual(packet, Data([0xFC, 0x0E, 0, 1, 0x43, 4, 3, 7, 0, 0, 0x0B,
                                     3, 1, 0x55, 0xC5, 0x83, 0x40, 0xCC]))
        XCTAssertEqual(coordinator.diagnostics, before)
        XCTAssertEqual(reads, 1); XCTAssertEqual(factories, 0)
        coordinator.stop()
    }

    @MainActor func testOwnedMDEWaitsForExistingSingleMaterialReadWithoutOpeningPeer() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var gate: CheckedContinuation<C.PeerMaterial, Never>?, reads = 0, factories = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1; return await withCheckedContinuation { gate = $0 }
        }, transportFactory: { factories += 1; return CoordinatorFakeTransport(material, clock: clock) },
            clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        let request = Task { try await coordinator.ownedMDEConfiguration() }
        await settleCoordinator(); XCTAssertEqual(reads, 1)
        gate?.resume(returning: material); gate = nil
        let packet = try await request.value
        XCTAssertEqual(packet, try SamsungMdePacket.configureOwnedAccountVersion3(
            accountFingerprint: XCTUnwrap(material.accountFingerprint).bytes))
        XCTAssertEqual(factories, 0); XCTAssertEqual(clock.now, 100)
        coordinator.stop()
    }

    @MainActor func testOwnedMDEDisabledStoppedAndAccountChangedNeverReturnBareConfiguration() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var reads = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { reads += 1; return material },
            transportFactory: { XCTFail("packet provider must not open transport"); return CoordinatorFakeTransport(material, clock: clock) },
            clock: clock, wallNow: { self.now })
        do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("disabled") }
        catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .cancelled) }
        XCTAssertEqual(reads, 0)
        for accountChanged in [false, true] {
            coordinator.start(); await settleCoordinator()
            coordinator.stop(accountChanged: accountChanged)
            let readsBefore = reads
            do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("stopped") }
            catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, accountChanged ? .accountChanged : .cancelled) }
            XCTAssertEqual(reads, readsBefore)
        }
    }

    @MainActor func testOwnedMDEMissingTypedFingerprintAndInvalidMaterialFailClosed() async throws {
        let valid = try coordinatorMaterial(), clock = CoordinatorClock()
        let missingFingerprint = C.PeerMaterial(ownClassicAddress: valid.ownClassicAddress, accountKey: valid.accountKey,
            revision: valid.revision, phones: valid.phones, identityMode: valid.identityMode)
        let invalidRevision = C.PeerMaterial(ownClassicAddress: valid.ownClassicAddress, accountKey: valid.accountKey,
            revision: -1, phones: valid.phones, identityMode: valid.identityMode, accountFingerprint: valid.accountFingerprint)
        let wrongIdentity = C.PeerMaterial(ownClassicAddress: valid.ownClassicAddress, accountKey: valid.accountKey,
            revision: valid.revision, phones: valid.phones, identityMode: .controllerCoherent, accountFingerprint: valid.accountFingerprint)
        for material in [missingFingerprint, invalidRevision, wrongIdentity] {
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material },
                transportFactory: { XCTFail("invalid material"); return CoordinatorFakeTransport(valid, clock: clock) },
                clock: clock, wallNow: { self.now })
            coordinator.start(); await settleCoordinator()
            do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("invalid material") }
            catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .invalidMaterial) }
            coordinator.stop()
        }
    }

    @MainActor func testOwnedMDELostSelectedPeerAndFailedRefreshRetirePreviouslyValidContext() async throws {
        let valid = try coordinatorMaterial(), clock = CoordinatorClock()
        for failedRead in [false, true] {
            var reads = 0
            let unavailable = C.PeerMaterial(ownClassicAddress: valid.ownClassicAddress, accountKey: valid.accountKey,
                revision: valid.revision, phones: [], identityMode: valid.identityMode, accountFingerprint: valid.accountFingerprint)
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
                reads += 1
                if reads == 1 { return valid }
                if failedRead { throw C.Failure.malformed }
                return unavailable
            }, transportFactory: { XCTFail("packet provider must not connect"); return CoordinatorFakeTransport(valid, clock: clock) },
                clock: clock, wallNow: { self.now })
            coordinator.start(); await settleCoordinator()
            _ = try await coordinator.ownedMDEConfiguration()
            coordinator.refreshRoster(); await settleCoordinator()
            do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("unavailable peer or material") }
            catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .materialUnavailable) }
            coordinator.stop(); await settleCoordinator()
        }
    }

    @MainActor func testOwnedMDERechecksExpiryOfCachedMaterial() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var wall = now
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: { material },
            transportFactory: { CoordinatorFakeTransport(material, clock: clock) }, clock: clock, wallNow: { wall })
        coordinator.start(); await settleCoordinator()
        _ = try await coordinator.ownedMDEConfiguration()
        wall = Date(timeIntervalSince1970: Double(material.accountKey.expireTime) / 1000)
        do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("expired material") }
        catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .expiredKey) }
        coordinator.stop()
    }

    @MainActor func testOwnedMDECancellationRetiresWaitWithoutCancellingSharedMaterialRead() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var gate: CheckedContinuation<C.PeerMaterial, Never>?, reads = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1; return await withCheckedContinuation { gate = $0 }
        }, transportFactory: { CoordinatorFakeTransport(material, clock: clock) }, clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        let request = Task { try await coordinator.ownedMDEConfiguration() }
        await settleCoordinator(); request.cancel()
        do { _ = try await request.value; XCTFail("cancelled waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        gate?.resume(returning: material); gate = nil; await settleCoordinator()
        let packet = try await coordinator.ownedMDEConfiguration()
        XCTAssertNotEqual(packet, SamsungMdePacket.configureVersion3())
        XCTAssertEqual(reads, 1)
        coordinator.stop()
    }

    @MainActor func testOwnedMDEPendingWaitIsRetiredByStopOrAccountChange() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        for accountChanged in [false, true] {
            var gate: CheckedContinuation<C.PeerMaterial, Never>?
            let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
                await withCheckedContinuation { gate = $0 }
            }, transportFactory: { XCTFail("stopped waiter"); return CoordinatorFakeTransport(material, clock: clock) },
                clock: clock, wallNow: { self.now })
            coordinator.start(); await settleCoordinator()
            let request = Task { try await coordinator.ownedMDEConfiguration() }
            await settleCoordinator(); coordinator.stop(accountChanged: accountChanged)
            gate?.resume(returning: material); gate = nil; await settleCoordinator()
            do { _ = try await request.value; XCTFail("retired lifecycle") }
            catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, accountChanged ? .accountChanged : .cancelled) }
            XCTAssertFalse(coordinator.diagnostics.authenticated)
        }
    }

    @MainActor func testOwnedMDEOldGenerationCannotAdoptContextAfterImmediateRestart() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var gate: CheckedContinuation<C.PeerMaterial, Never>?, reads = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1
            if reads == 1 { return await withCheckedContinuation { gate = $0 } }
            return material
        }, transportFactory: { XCTFail("provider must not connect"); return CoordinatorFakeTransport(material, clock: clock) },
            clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        let old = Task { try await coordinator.ownedMDEConfiguration() }
        await settleCoordinator(); coordinator.stop(accountChanged: true); coordinator.start()
        gate?.resume(returning: material); gate = nil; await settleCoordinator()
        coordinator.refreshRoster(); await settleCoordinator()
        do { _ = try await old.value; XCTFail("old waiter cannot adopt restarted context") }
        catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .cancelled) }
        let fresh = try await coordinator.ownedMDEConfiguration()
        XCTAssertNotEqual(fresh, SamsungMdePacket.configureVersion3()); XCTAssertEqual(reads, 2)
        coordinator.stop()
    }

    @MainActor func testOwnedMDEFrozenClockWaitHasOneRealThreeSecondDeadline() async throws {
        let material = try coordinatorMaterial(), clock = CoordinatorClock()
        var gate: CheckedContinuation<C.PeerMaterial, Never>?, reads = 0
        let coordinator = NativeSamsungPeerCoordinator(materialProvider: {
            reads += 1; return await withCheckedContinuation { gate = $0 }
        }, transportFactory: { XCTFail("deadline must not connect"); return CoordinatorFakeTransport(material, clock: clock) },
            clock: clock, wallNow: { self.now })
        coordinator.start(); await settleCoordinator()
        let began = ContinuousClock.now
        do { _ = try await coordinator.ownedMDEConfiguration(); XCTFail("unavailable material") }
        catch { XCTAssertEqual(error as? NativeSamsungPeerCoordinator.Failure, .materialUnavailable) }
        let elapsed = began.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(3))
        XCTAssertLessThan(elapsed, .seconds(4))
        XCTAssertEqual(clock.now, 100); XCTAssertEqual(reads, 1)
        coordinator.stop(); gate?.resume(returning: material); gate = nil; await settleCoordinator()
    }
}
