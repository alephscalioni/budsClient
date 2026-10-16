import XCTest
@testable import BudsAutoSwitch

final class SamsungPeerWireTests: XCTestCase {
    typealias W = SamsungPeerWire

    func testIndependentPacketGoldenAndOptionalPresence() throws {
        // Hand-written tags: handler1, seq150, payload aa bb, adv cc,
        // revision explicitly0, authType1, IV explicitly empty, unknown field8=7.
        let bytes = Data([0x08, 1, 0x10, 0x96, 1, 0x1a, 2, 0xaa, 0xbb,
                          0x22, 1, 0xcc, 0x28, 0, 0x30, 1, 0x3a, 0, 0x40, 7])
        let p = try W.Packet.decode(bytes)
        XCTAssertEqual(p.handlerID, 1); XCTAssertEqual(p.sequence, 150)
        XCTAssertEqual(p.payload, Data([0xaa, 0xbb])); XCTAssertEqual(p.advertisement, Data([0xcc]))
        XCTAssertEqual(p.revision, 0); XCTAssertEqual(p.authType, 1); XCTAssertEqual(p.iv, Data())
        XCTAssertEqual(p.unknownFields, Data([0x40, 7])); XCTAssertEqual(try p.encoded(), bytes)
        let empty = try W.Packet.decode(Data())
        XCTAssertNil(empty.revision); XCTAssertNil(empty.authType); XCTAssertNil(empty.iv)
        XCTAssertEqual(empty.handlerID, 0)
        XCTAssertEqual(try W.Packet(payload: Data([1]), authType: 1).encoded(), Data([0x1a, 1, 1, 0x30, 1]))
    }

    func testIndependentAuthenticationNegativeInt32AndUTF8() throws {
        let bytes = Data([0x08, 3, 0x10] + Array(repeating: UInt8(0xff), count: 9) + [1,
            0x1a, 6, 1, 2, 3, 4, 5, 6, 0x22, 2, 0x30, 0,
            0x2a, 6, 0, 1, 2, 3, 4, 5, 0x32, 1, 0x61, 0x32, 0,
            0x38, 1, 0x40, 0, 0x48, 0])
        let a = try W.Authentication.decode(bytes)
        XCTAssertEqual(a.command, 3); XCTAssertEqual(a.result, -1)
        XCTAssertEqual(a.address, Data([1, 2, 3, 4, 5, 6])); XCTAssertEqual(a.nonce, Data([0x30, 0]))
        XCTAssertEqual(a.hash, Data([0, 1, 2, 3, 4, 5])); XCTAssertEqual(a.channels, ["a", ""])
        XCTAssertTrue(a.supportTCPKeep); XCTAssertEqual(a.revision, 0); XCTAssertEqual(a.memberID, 0)
        XCTAssertEqual(try a.encoded(), bytes)
        XCTAssertThrowsError(try W.Authentication.decode(Data([0x32, 1, 0xff])))
        // Valid uint64 truncated to int32, ordinary protobuf int32 semantics.
        XCTAssertEqual(try W.Command.decode(Data([8, 0xff, 0xff, 0xff, 0xff, 0x0f])).commandID, -1)
        XCTAssertEqual(try W.Command(commandID: .min).encoded(),
                       Data([8, 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 1]))
        XCTAssertEqual(try W.Authentication(command: 3, hash: Data([1, 2, 3, 4, 5, 6])).encoded(),
                       Data([8, 3, 0x2a, 6, 1, 2, 3, 4, 5, 6]))
    }

    func testUnknownWireTypesGroupsWrongWireAndDuplicateLastWins() throws {
        // field1 wrong wire (bytes), unknown fixed64/32, group10 with nested
        // group11, unknown varint and bytes. All independent literal protobuf.
        let unknown = Data([0x0a, 1, 0xaa, 0x51, 1, 2, 3, 4, 5, 6, 7, 8,
                            0x5d, 1, 2, 3, 4, 0x53, 0x5b, 0x60, 7, 0x5c, 0x54,
                            0x60, 8, 0x6a, 2, 0xee, 0xff])
        let p = try W.Packet.decode(unknown + Data([8, 1, 8, 2]))
        XCTAssertEqual(p.handlerID, 2); XCTAssertEqual(p.unknownFields, unknown)
        XCTAssertEqual(try p.encoded(), Data([8, 2]) + unknown)
        XCTAssertThrowsError(try W.Packet.decode(Data([0x53, 0x5c]))) // mismatched end
        XCTAssertThrowsError(try W.Packet.decode(Data([0x54]))) // top-level end
        XCTAssertThrowsError(try W.Packet.decode(Data([0x53]))) // unterminated group
        XCTAssertThrowsError(try W.Packet.decode(Data([0x53, 0x5b, 0x5c, 0x54]), limits: W.Limits(groupDepth: 1)))
    }

    func testBoundsTruncationAndMalformedProtobuf() throws {
        for bytes: [UInt8] in [[0], [6], [7], [0x80], [0x1a, 2, 0], [0x51, 0], [0x5d, 0],
            [8] + Array(repeating: 0xff, count: 9) + [2],
            [8] + Array(repeating: 0x80, count: 10),
            [0x80, 0x80, 0x80, 0x80, 0x10, 0], // field number >2^29-1
            [0x1a] + Array(repeating: 0xff, count: 9) + [1]] {
            XCTAssertThrowsError(try W.Packet.decode(Data(bytes)), "\(bytes)")
        }
        XCTAssertThrowsError(try W.Packet.decode(Data([8, 1, 8, 2]), limits: W.Limits(fields: 1)))
        let retained = try W.Packet.decode(Data([0x50, 1, 0x58, 2]))
        XCTAssertThrowsError(try retained.encoded(limits: W.Limits(fields: 1)))
        XCTAssertThrowsError(try W.Packet.decode(Data([8, 1]), limits: W.Limits(messageBytes: 1)))
        XCTAssertThrowsError(try W.Packet(payload: Data(repeating: 0, count: 5)).encoded(limits: W.Limits(messageBytes: 4)))
        XCTAssertThrowsError(try W.Limits(messageBytes: 0))
        XCTAssertThrowsError(try W.Limits(groupDepth: 65))
    }

    func testContinuousFragmentedDecoderAtEveryCutAndByteBoundary() throws {
        // Frame1 length8 -> Packet(handler1, seq150, payload ff). Frame2 empty.
        let stream = Data([8, 8, 1, 0x10, 0x96, 1, 0x1a, 1, 0xff, 0])
        for cut in 0...stream.count {
            var decoder = W.FrameDecoder(); var packets: [W.Packet] = []
            try decoder.append(Data(stream.prefix(cut))) { packets.append($0) }
            try decoder.append(Data(stream.dropFirst(cut))) { packets.append($0) }
            try decoder.finish()
            XCTAssertEqual(packets.count, 2); XCTAssertEqual(packets.first?.sequence, 150)
            XCTAssertEqual(packets.first?.payload, Data([0xff])); XCTAssertEqual(packets.last, W.Packet())
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
        // Independently laid-out 130-byte protobuf body, varint prefix 82 01.
        let large = Data([0x82, 1, 0x1a, 0x7f] + Array(repeating: UInt8(0xab), count: 127) + [0x00])
        // Last zero above is an invalid tag in the 130-byte body: reject at completion.
        var bad = W.FrameDecoder()
        XCTAssertThrowsError(try bad.append(large) { _ in XCTFail() })
        let actual = Data([0x83, 1, 0x1a, 0x80, 1] + Array(repeating: UInt8(0xab), count: 128))
        var decoder = W.FrameDecoder(); var packets: [W.Packet] = []
        for b in actual { try decoder.append(Data([b])) { packets.append($0) } }
        try decoder.finish(); XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].payload.count, 128)
    }

    func testFrameOverflowLengthLimitTruncationAndPoison() throws {
        for bytes in [Array(repeating: UInt8(0x80), count: 10),
                      Array(repeating: UInt8(0xff), count: 9) + [2], [0x81, 1]] {
            var decoder = W.FrameDecoder(limits: try W.Limits(messageBytes: 128))
            XCTAssertThrowsError(try decoder.append(Data(bytes)) { _ in XCTFail() })
            XCTAssertThrowsError(try decoder.append(Data([0])) { _ in XCTFail() })
        }
        for bytes: [UInt8] in [[0x80], [3, 8, 1]] {
            var decoder = W.FrameDecoder()
            try decoder.append(Data(bytes)) { _ in XCTFail() }
            XCTAssertThrowsError(try decoder.finish())
            XCTAssertThrowsError(try decoder.finish())
        }
        let p = W.Packet(payload: Data(repeating: 0xaa, count: 128))
        let frame = try W.frame(p)
        XCTAssertEqual(Array(frame.prefix(2)), [0x83, 1])
    }

    func testCallbackErrorPoisonsDecoderAndLargeBatchDoesNotAccumulate() throws {
        var decoder = W.FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0])) { _ in throw W.Failure.limit })
        XCTAssertThrowsError(try decoder.finish())
        var fresh = W.FrameDecoder(); var count = 0
        try fresh.append(Data(repeating: 0, count: 10_000)) { _ in count += 1 }
        try fresh.finish(); XCTAssertEqual(count, 10_000); XCTAssertEqual(fresh.bufferedByteCount, 0)
    }

    func testBudsSwitchIndependentGoldenVectors() throws {
        let a = try SamsungPeerAddress(bytes: Data([0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc]))
        XCTAssertEqual(a.advertisingID, 0x2ebc)
        let request = Data([8, 1, 0x10, 1, 0x1a, 9, 0x2e, 0xbc, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 1])
        let command = try W.Command.decode(request)
        XCTAssertEqual(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: command),
                       .request(advertisingID: 0x2ebc, address: a, reason: .media))
        XCTAssertEqual(try SamsungPeerBudsSwitch.request(advertisingID: 0x2ebc, address: a, reason: .media).command().encoded(), request)
        let response = Data([8, 1, 0x10, 2, 0x1a, 9, 1, 0x2e, 0xbc, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc])
        XCTAssertEqual(try SamsungPeerBudsSwitch.successResponse(address: a).command().encoded(), response)
        XCTAssertEqual(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: W.Command.decode(response)),
                       .response(success: 1, advertisingID: 0x2ebc, address: a))
        var call = command; call.payload[8] = 2
        XCTAssertEqual(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: call), .request(advertisingID: 0x2ebc, address: a, reason: .call))
        var independentID = command; independentID.payload[0] = 0
        XCTAssertNoThrow(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: independentID))
        for length in [0, 8, 10] {
            XCTAssertThrowsError(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: .init(commandID: 1, type: 1, payload: Data(repeating: 0, count: length))))
        }
        XCTAssertThrowsError(try SamsungPeerBudsSwitch.decode(handlerID: 0, command: command))
        var unsupported = command; unsupported.payload[8] = 3
        XCTAssertThrowsError(try SamsungPeerBudsSwitch.decode(handlerID: 1, command: unsupported))
    }
}
