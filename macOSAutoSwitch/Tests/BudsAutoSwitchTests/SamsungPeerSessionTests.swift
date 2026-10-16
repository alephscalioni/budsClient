import XCTest
@testable import BudsAutoSwitch

final class SamsungPeerSessionTests: XCTestCase {
    typealias W = SamsungPeerWire
    typealias S = SamsungPeerSession
    typealias F = SamsungPeerDiagnostics.Failure
    private let ku = Data(repeating: 0x42, count: 32) // synthetic, never account material
    private let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification,
                                           randomIV: { Data(repeating: 0x19, count: 16) })
    private var a: SamsungPeerAddress { try! .init(bytes: peerHex("102030405060")) }
    private var b: SamsungPeerAddress { try! .init(bytes: peerHex("112233445566")) }
    private var c: SamsungPeerAddress { try! .init(bytes: peerHex("213243546576")) }
    private var roster: SamsungPeerRoster { try! .init(revision: 0, members: [a, b, c]) }

    private func endpoint(_ role: S.Role, key: Data? = nil, expected: SamsungPeerAddress? = nil,
                          provider: SamsungPeerCryptography? = nil,
                          send: Int32 = 1, receive: Int32? = nil) throws -> S {
        try S(role: role, accountKey: key ?? ku, localAddress: role == .initiator ? a : b,
              roster: roster, expectedPeer: expected, crypto: provider ?? crypto,
              timeout: 5, initialSendSequence: send, initialReceiveSequence: receive)
    }
    private func account(_ plain: Data, type: Int32? = 1) throws -> W.Packet {
        .init(payload: try crypto.sealAccount(plain, accountKey: ku), authType: type)
    }
    private func relay(_ packet: W.Packet) throws -> W.Packet {
        var decoder = W.FrameDecoder(); var output: W.Packet?
        for byte in try W.frame(packet) { try decoder.append(Data([byte])) { output = $0 } }
        try decoder.finish(); return try XCTUnwrap(output)
    }
    private func handshake(_ initiator: S, _ responder: S) throws -> (W.Packet, W.Packet, W.Packet) {
        XCTAssertNil(try responder.start(now: 0))
        let first = try XCTUnwrap(initiator.start(now: 0))
        let second = try XCTUnwrap(responder.receiveAuthentication(relay(first), now: 1))
        let third = try XCTUnwrap(initiator.receiveAuthentication(relay(second), now: 2))
        XCTAssertEqual(initiator.phase, .awaitingFinalSend)
        XCTAssertFalse(initiator.diagnostics.sessionReady)
        try initiator.confirmFinalReplySent(now: 2)
        XCTAssertNil(try responder.receiveAuthentication(relay(third), now: 3))
        return (first, second, third)
    }
    private func assertFailure(_ session: S, _ expected: F, _ action: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? F, expected, file: file, line: line)
        }
        XCTAssertEqual(session.phase, .failed, file: file, line: line)
        XCTAssertEqual(session.diagnostics.failure, expected, file: file, line: line)
        XCTAssertFalse(session.diagnostics.sessionReady, file: file, line: line)
        XCTAssertFalse(session.diagnostics.peerRecognized, file: file, line: line)
    }

    func testRealSyntheticHandshakeAndEncryptedSwitchInBothDirections() throws {
        let initiator = try endpoint(.initiator, expected: b)
        let responder = try endpoint(.responder, expected: a)
        let (one, two, three) = try handshake(initiator, responder)
        for packet in [one, two, three] {
            XCTAssertEqual(packet.handlerID, 0); XCTAssertEqual(packet.authType, 1); XCTAssertNil(packet.iv)
        }
        let first = try W.Authentication.decode(crypto.openAccount(one.payload, accountKey: ku))
        XCTAssertEqual(first.command, 1); XCTAssertEqual(first.address, a.bytes)
        XCTAssertEqual(first.revision, 0); XCTAssertTrue(first.channels.isEmpty); XCTAssertFalse(first.supportTCPKeep)
        let second = try W.Authentication.decode(crypto.openAccount(two.payload, accountKey: ku))
        XCTAssertEqual(second.command, 2); XCTAssertEqual(second.address, b.bytes)
        XCTAssertEqual(second.hash, crypto.publicKeyHash(first.nonce)); XCTAssertEqual(second.revision, 0)
        let third = try crypto.openAccount(three.payload, accountKey: ku)
        // Independent command3 layout: NO address, nonce, revision, channel or TCP flag.
        XCTAssertEqual(third, Data([8, 3, 0x2a, 6]) + crypto.publicKeyHash(second.nonce))
        XCTAssertTrue(initiator.diagnostics.sessionReady); XCTAssertTrue(responder.diagnostics.sessionReady)
        let buds = try SamsungPeerAddress(bytes: peerHex("123456789abc"))
        let request = SamsungPeerBudsSwitch.request(advertisingID: 0x2ebc, address: buds, reason: .media)
        let outer = try relay(initiator.encodeCommand(request.command(), handlerID: 1, advertisement: Data([0xee]), revision: 0))
        XCTAssertNil(outer.authType); XCTAssertNil(outer.iv); XCTAssertEqual(outer.sequence, 1)
        let received = try responder.receiveCommand(outer)
        XCTAssertEqual(received.advertisement, Data([0xee])); XCTAssertEqual(received.revision, 0)
        XCTAssertEqual(try SamsungPeerBudsSwitch.decode(handlerID: received.handlerID, command: received.command), request)
        let response = SamsungPeerBudsSwitch.successResponse(address: buds)
        let returned = try initiator.receiveCommand(relay(responder.encodeCommand(response.command(), handlerID: 1)))
        XCTAssertEqual(try SamsungPeerBudsSwitch.decode(handlerID: returned.handlerID, command: returned.command), response)
        // Session CBC has no MAC; this test proves synthetic codec compatibility only.
    }

    func testIndependentInitiateBytesLegacyAuthTypeAndResultSemantics() throws {
        let responder = try endpoint(.responder); _ = try responder.start(now: 0)
        let key = try crypto.makeEphemeralKey()
        // Auth command1, result2 (Android only rejects -1), address, SPKI, explicit R0.
        let plain = Data([8, 1, 0x10, 2, 0x1a, 6]) + a.bytes + Data([0x22, 91]) + key.publicKeySPKI + Data([0x40, 0])
        let reply = try XCTUnwrap(responder.receiveAuthentication(account(plain, type: nil), now: 1))
        XCTAssertEqual(responder.phase, .awaitingReply)
        let replyAuth = try W.Authentication.decode(crypto.openAccount(reply.payload, accountKey: ku))
        XCTAssertEqual(replyAuth.hash, crypto.publicKeyHash(key.publicKeySPKI))
        let final = Data([8, 3, 0x2a, 6]) + crypto.publicKeyHash(replyAuth.nonce)
        XCTAssertNil(try responder.receiveAuthentication(account(final, type: nil), now: 2))
        XCTAssertEqual(responder.phase, .authenticated)
    }

    func testRosterIsMandatoryAndIdentityCannotBeInvented() throws {
        XCTAssertThrowsError(try SamsungPeerRoster(revision: 0, members: []))
        let otherRoster = try SamsungPeerRoster(revision: 0, members: [b])
        XCTAssertThrowsError(try S(role: .initiator, accountKey: ku, localAddress: a, roster: otherRoster, crypto: crypto)) { error in
            XCTAssertEqual(error as? F, .localIdentityNotInRoster)
        }
        let stranger = try SamsungPeerAddress(bytes: Data(repeating: 0xff, count: 6))
        XCTAssertThrowsError(try endpoint(.initiator, expected: stranger))
        XCTAssertThrowsError(try endpoint(.initiator, key: Data(count: 16)))
        let spy = CountingCrypto(base: crypto)
        let responder = try endpoint(.responder, provider: spy); _ = try responder.start(now: 0)
        let unknown = Data([8, 1, 0x1a, 6]) + stranger.bytes + Data([0x22, 1, 0xff])
        assertFailure(responder, .unknownAddress) { _ = try responder.receiveAuthentication(account(unknown), now: 1) }
        XCTAssertEqual(spy.generated, 0) // address rejected before generating/deriving keys
    }

    func testPinnedPeerCannotBeReplacedByAnotherEnrolledAddress() throws {
        let responder = try endpoint(.responder, expected: c); _ = try responder.start(now: 0)
        let first = try XCTUnwrap(endpoint(.initiator).start(now: 0))
        assertFailure(responder, .unexpectedAddress) { _ = try responder.receiveAuthentication(first, now: 1) }
    }

    func testBadHashAndMissingHashAreTerminal() throws {
        for hash in [Data(), Data(repeating: 0, count: 6), Data(repeating: 0, count: 7)] {
            let initiator = try endpoint(.initiator); _ = try initiator.start(now: 0)
            let key = try crypto.makeEphemeralKey()
            let plain = Data([8, 2, 0x1a, 6]) + b.bytes + Data([0x22, 91]) + key.publicKeySPKI + Data([0x2a, UInt8(hash.count)]) + hash
            assertFailure(initiator, .invalidHash) { _ = try initiator.receiveAuthentication(account(plain), now: 1) }
            XCTAssertThrowsError(try initiator.start(now: 2))
        }
    }

    func testResponderRejectsInvalidFinalHashOrChangedAddress() throws {
        for changedAddress in [false, true] {
            let initiator = try endpoint(.initiator); let responder = try endpoint(.responder)
            _ = try responder.start(now: 0)
            let one = try XCTUnwrap(initiator.start(now: 0))
            let two = try XCTUnwrap(responder.receiveAuthentication(one, now: 1))
            let replyAuth = try W.Authentication.decode(crypto.openAccount(two.payload, accountKey: ku))
            var final = Data([8, 3])
            if changedAddress { final += Data([0x1a, 6]) + c.bytes }
            final += Data([0x2a, 6]) + (changedAddress ? crypto.publicKeyHash(replyAuth.nonce) : Data(repeating: 0, count: 6))
            assertFailure(responder, changedAddress ? .unexpectedAddress : .invalidHash) {
                _ = try responder.receiveAuthentication(account(final), now: 2)
            }
        }
    }

    func testWrongAccountKeyTamperMalformedProtobufAndRemoteFailure() throws {
        let initiator = try endpoint(.initiator)
        let one = try XCTUnwrap(initiator.start(now: 0))
        let wrong = try endpoint(.responder, key: Data(repeating: 0x43, count: 32)); _ = try wrong.start(now: 0)
        assertFailure(wrong, .cryptoFailure) { _ = try wrong.receiveAuthentication(one, now: 1) }
        let tampered = try endpoint(.responder); _ = try tampered.start(now: 0)
        var corrupt = one; corrupt.payload[corrupt.payload.startIndex] ^= 1
        assertFailure(tampered, .cryptoFailure) { _ = try tampered.receiveAuthentication(corrupt, now: 1) }
        let malformed = try endpoint(.responder); _ = try malformed.start(now: 0)
        assertFailure(malformed, .malformedAuthentication) { _ = try malformed.receiveAuthentication(account(Data([0])), now: 1) }
        let failed = try endpoint(.initiator); _ = try failed.start(now: 0)
        let failure = Data([8, 2, 0x10] + Array(repeating: UInt8(0xff), count: 9) + [1])
        assertFailure(failed, .remoteRejected) { _ = try failed.receiveAuthentication(account(failure), now: 1) }
    }

    func testUnsupportedTypesHandlerAndInvalidNonce() throws {
        for type: Int32 in [0, 2, 4, 8, 16, 32, 99] {
            let responder = try endpoint(.responder); _ = try responder.start(now: 0)
            assertFailure(responder, .unsupportedAuthType) { _ = try responder.receiveAuthentication(account(Data([8, 1]), type: type), now: 1) }
        }
        for useIV in [false, true] {
            let responder = try endpoint(.responder); _ = try responder.start(now: 0)
            var packet = try account(Data([8, 1]))
            if useIV { packet.iv = Data() } else { packet.handlerID = 1 }
            assertFailure(responder, .invalidEnvelope) { _ = try responder.receiveAuthentication(packet, now: 1) }
        }
        let responder = try endpoint(.responder); _ = try responder.start(now: 0)
        let badNonce = Data([8, 1, 0x1a, 6]) + a.bytes + Data([0x22, 1, 0xff])
        assertFailure(responder, .invalidPublicKey) { _ = try responder.receiveAuthentication(account(badNonce), now: 1) }
    }

    func testRoleOrderReplayAndPreAuthenticationSessionGuard() throws {
        let initiator = try endpoint(.initiator); _ = try initiator.start(now: 0)
        XCTAssertThrowsError(try initiator.encodeCommand(.init(commandID: 1), handlerID: 1)) { XCTAssertEqual($0 as? F, .notAuthenticated) }
        assertFailure(initiator, .unexpectedSequence) { _ = try initiator.receiveAuthentication(account(Data([8, 1])), now: 1) }
        let responder = try endpoint(.responder); _ = try responder.start(now: 0)
        assertFailure(responder, .unexpectedSequence) { _ = try responder.receiveAuthentication(account(Data([8, 3])), now: 1) }
        let a = try endpoint(.initiator); let b = try endpoint(.responder)
        let (one, _, _) = try handshake(a, b)
        assertFailure(b, .unexpectedSequence) { _ = try b.receiveAuthentication(one, now: 4) }
    }

    func testTimeoutAtBoundaryTotalBudgetAndClockRollback() throws {
        let waiting = try endpoint(.responder); _ = try waiting.start(now: 10)
        try waiting.pollTimeout(now: 14.999)
        assertFailure(waiting, .timeout) { try waiting.pollTimeout(now: 15) }
        let a = try endpoint(.initiator); let b = try endpoint(.responder)
        _ = try b.start(now: 0); let one = try XCTUnwrap(a.start(now: 0))
        _ = try b.receiveAuthentication(one, now: 4)
        assertFailure(b, .timeout) { try b.pollTimeout(now: 5) } // step did not refresh timeout
        let rollback = try endpoint(.initiator); _ = try rollback.start(now: 20)
        assertFailure(rollback, .invalidClock) { try rollback.pollTimeout(now: 19) }
        let nonfinite = try endpoint(.responder)
        assertFailure(nonfinite, .invalidClock) { _ = try nonfinite.start(now: .nan) }
        let finalSender = try endpoint(.initiator); let other = try endpoint(.responder)
        _ = try other.start(now: 0)
        let two = try XCTUnwrap(other.receiveAuthentication(XCTUnwrap(finalSender.start(now: 0)), now: 1))
        _ = try finalSender.receiveAuthentication(two, now: 2)
        assertFailure(finalSender, .timeout) { try finalSender.confirmFinalReplySent(now: 5) }
    }

    func testSessionReplaySequenceExhaustionAndCorruptCBC() throws {
        let a = try endpoint(.initiator, send: .max); let b = try endpoint(.responder, receive: .max)
        _ = try handshake(a, b)
        let packet = try a.encodeCommand(.init(commandID: 1), handlerID: 1)
        _ = try b.receiveCommand(packet)
        assertFailure(b, .unexpectedSequence) { _ = try b.receiveCommand(packet) }
        assertFailure(a, .sequenceExhausted) { _ = try a.encodeCommand(.init(commandID: 1), handlerID: 1) }
        let x = try endpoint(.initiator); let y = try endpoint(.responder); _ = try handshake(x, y)
        var corrupt = try x.encodeCommand(.init(commandID: 1), handlerID: 1)
        corrupt.payload.removeLast()
        assertFailure(y, .malformedSession) { _ = try y.receiveCommand(corrupt) }
    }

    func testInjectedFailureCloseAndSecretFreeDiagnostics() throws {
        let injected = CountingCrypto(base: crypto); injected.failGeneration = true
        let session = try endpoint(.initiator, provider: injected)
        assertFailure(session, .cryptoFailure) { _ = try session.start(now: 0) }
        let a = try endpoint(.initiator); let b = try endpoint(.responder); _ = try handshake(a, b)
        let json = String(decoding: try JSONEncoder().encode(a.diagnostics), as: UTF8.self)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["phase", "cryptoCompatibility", "rosterAvailable", "peerRecognized", "sessionReady"])
        XCTAssertFalse(json.contains("424242")); XCTAssertFalse(json.contains("102030405060"))
        XCTAssertEqual(a.description, "SamsungPeerSession(authenticated, none)")
        XCTAssertEqual(self.a.description, "SamsungPeerAddress(redacted)")
        a.close(); XCTAssertEqual(a.phase, .closed); XCTAssertFalse(a.diagnostics.sessionReady)
        XCTAssertFalse(a.diagnostics.peerRecognized)
        XCTAssertThrowsError(try a.encodeCommand(.init(), handlerID: 1)) { XCTAssertEqual($0 as? F, .closed) }
    }
}

private final class CountingCrypto: SamsungPeerCryptography {
    let base: SamsungPeerCrypto
    var generated = 0
    var failGeneration = false
    var compatibility: SamsungPeerDiagnostics.CryptoCompatibility { .injectedProviderRequiresVerification }
    init(base: SamsungPeerCrypto) { self.base = base }
    func makeEphemeralKey() throws -> SamsungPeerEphemeralKey {
        generated += 1
        if failGeneration { throw SamsungPeerCryptoFailure.randomGeneration }
        return try base.makeEphemeralKey()
    }
    func publicKeyHash(_ spki: Data) -> Data { base.publicKeyHash(spki) }
    func sealAccount(_ p: Data, accountKey: Data) throws -> Data { try base.sealAccount(p, accountKey: accountKey) }
    func openAccount(_ p: Data, accountKey: Data) throws -> Data { try base.openAccount(p, accountKey: accountKey) }
    func sealSession(_ p: Data, sessionKey: Data) throws -> Data { try base.sealSession(p, sessionKey: sessionKey) }
    func openSession(_ p: Data, sessionKey: Data) throws -> Data { try base.openSession(p, sessionKey: sessionKey) }
}
