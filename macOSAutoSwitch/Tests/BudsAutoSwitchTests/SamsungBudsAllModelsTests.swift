import XCTest
@testable import BudsAutoSwitch

final class SamsungBudsAllModelsTests: XCTestCase {
    typealias Packet = SamsungBudsSettingsPacket
    typealias Profile = SamsungBudsModelProfile

    private func statusFrame(_ profile: Profile, revision: UInt8 = 1, count: Int = 60,
                             left: Int? = nil, right: Int? = nil) -> Packet.Frame {
        var p = [UInt8](repeating: 0, count: count)
        if count > 0 { p[0] = revision }
        if count > 7 { p[2] = 81; p[3] = 72; p[6] = profile == .buds ? 17 : 0x12; p[7] = 64 }
        let offset = profile == .budsPlus ? 15 : 14
        if profile != .buds, count >= offset + 4 {
            let ids = [left ?? profile.colorIDs.min()!, right ?? profile.colorIDs.max()!]
            for (i, id) in ids.enumerated() { p[offset + i * 2] = UInt8(truncatingIfNeeded: id); p[offset + i * 2 + 1] = UInt8(id >> 8) }
        }
        return .init(command: 0x61, payload: Data(p), isFragment: false, legacyFraming: profile == .buds)
    }

    func testAllThirteenExactIDsAndDistinctServiceFamilies() throws {
        XCTAssertEqual(Profile.allCases.count, 13)
        for profile in Profile.allCases {
            for id in profile.colorIDs {
                let frame = statusFrame(profile, left: id, right: id)
                XCTAssertEqual(Profile.physical(frame, model: profile.rawValue), true, profile.rawValue)
                XCTAssertEqual(Profile.identify(frame, expected: profile), profile)
                XCTAssertEqual(try XCTUnwrap(Packet.status(frame, model: profile.rawValue)).model, profile.rawValue)
                if profile != .buds { XCTAssertEqual(Profile.identify(frame), profile) }
            }
        }
        XCTAssertNil(Profile.identify(statusFrame(.buds)))
        XCTAssertTrue(Profile.buds.legacyFraming)
        XCTAssertFalse(Profile.budsPlus.legacyFraming)
        XCTAssertTrue(Profile.buds.serviceUUID.contains("1102"))
        for p: Profile in [.budsPlus, .budsLive, .budsPro] { XCTAssertTrue(p.serviceUUID.contains("1101")) }
        XCTAssertEqual(Profile.buds4.serviceUUID, Packet.serviceUUID)
    }

    func testZeroConflictingMixedAndTruncatedIDsNeverGuess() {
        for profile in Profile.allCases where profile != .buds {
            let zeros = statusFrame(profile, left: 0, right: 0)
            XCTAssertNil(Profile.physical(zeros, model: profile.rawValue))
            XCTAssertNil(Profile.identify(zeros))
            let oneZero = statusFrame(profile, left: profile.colorIDs.min()!, right: 0)
            XCTAssertNil(Profile.physical(oneZero, model: profile.rawValue))
            let conflict = statusFrame(profile, left: profile.colorIDs.min()!, right: 65535)
            XCTAssertEqual(Profile.physical(conflict, model: profile.rawValue), false)
            XCTAssertNil(Profile.identify(conflict))
            XCTAssertNil(Packet.status(conflict, model: profile.rawValue))
            XCTAssertNil(Profile.physical(statusFrame(profile, count: 14), model: profile.rawValue))
            XCTAssertNil(Packet.status(statusFrame(profile, count: 12), model: profile.rawValue))
        }
        let mixed = statusFrame(.buds4, left: 355, right: 340)
        XCTAssertNil(Profile.identify(mixed))
        XCTAssertNil(Profile.identify(statusFrame(.buds4), expected: .buds3Pro))
    }

    func testConservativeFamilyResolutionAndExplicitModelWins() {
        for profile in Profile.allCases {
            XCTAssertEqual(Profile.resolve(model: nil, name: profile.title + " (ABCD)"), profile)
            XCTAssertEqual(Profile.resolve(model: profile.rawValue, name: "Galaxy Buds3 Pro"), profile)
        }
        XCTAssertEqual(Profile.resolve(model: "Galaxy Buds4 Pro", name: "Renamed"), .buds4Pro)
        XCTAssertEqual(Profile.resolve(model: nil, name: "Galaxy Buds 4 Pro (ABCD)"), .buds4Pro)
        for name in ["Galaxy Buds5", "Galaxy Buds4 Ultra", "My Buds3 Pro", "Galaxy Buds Pro Max", "Buds30"] {
            XCTAssertNil(Profile.resolve(model: nil, name: name), name)
        }
    }

    func testOlderStatusBranchesAndRevisionGates() throws {
        var original = statusFrame(.buds).payload
        original[7] = 1; original[9] = 4; original[10] = 1; original[11] = 7; original[12] = 0
        let old = try XCTUnwrap(Packet.status(.init(command: 0x61, payload: original, isFragment: false, legacyFraming: true), model: "Buds"))
        XCTAssertNil(old.casePercent); XCTAssertEqual(old.noise, .ambient); XCTAssertEqual(old.equalizer, 3)
        XCTAssertTrue(old.wearingBoth); XCTAssertTrue(old.settings.isEmpty)
        var plus = statusFrame(.budsPlus, revision: 13).payload
        plus[8] = 1; plus[9] = 2; plus[11] = 6; plus[19] = 1; plus[23] = 0
        let plusStatus = try XCTUnwrap(Packet.status(.init(command: 0x61, payload: plus, isFragment: false), model: "BudsPlus"))
        XCTAssertEqual(plusStatus.noise, .ambient); XCTAssertEqual(plusStatus.equalizer, 5)
        XCTAssertEqual(plusStatus.settings[.sidetone], 1); XCTAssertEqual(plusStatus.settings[.callAudioToBuds], 1)
        plus[0] = 7
        XCTAssertTrue(Packet.Setting.observed(Array(plus), model: "BudsPlus").isEmpty)
        var pro = Array(statusFrame(.budsPro, revision: 10).payload)
        pro[29] = 16; pro[32] = 1; pro[36] = 1; pro[37] = 0
        XCTAssertEqual(Packet.Setting.observed(pro, model: "BudsPro")[.stereoBalance], 16)
        XCTAssertEqual(Packet.Setting.observed(pro, model: "BudsPro")[.sidetone], 1)
        pro[0] = 8
        XCTAssertNil(Packet.Setting.observed(pro, model: "BudsPro")[.sidetone])
        XCTAssertNil(Packet.Setting.observed(pro, model: "BudsPro")[.callAudioToBuds])
        XCTAssertNil(Packet.Setting.observed(pro, model: "Buds2")[.conversationDetection])
    }

    func testBuds4OnlyUsesCommonPrefixAndTenByteTouchIsExclusive() throws {
        for profile in Profile.allCases {
            let decoded = try XCTUnwrap(Packet.status(statusFrame(profile), model: profile.rawValue))
            XCTAssertEqual(decoded.touchControls?.wireLength, profile.touchPayloadLength(revision: decoded.revision))
            XCTAssertEqual(profile.noiseModes.contains(.adaptive), [Profile.buds3Pro, .buds4Pro].contains(profile))
            if !profile.supportsTenByteTouch { XCTAssertFalse(profile.allows(command: 0x90, payload: [UInt8](repeating: 0, count: 10), status: decoded)) }
        }
        for profile: Profile in [.buds4, .buds4Pro] {
            let common = try XCTUnwrap(Packet.status(statusFrame(profile, count: 25), model: profile.rawValue))
            XCTAssertEqual(common.left, 81); XCTAssertEqual(common.right, 72); XCTAssertEqual(common.touchControls?.wireLength, 10)
            XCTAssertTrue(common.settings.isEmpty)
        }
        let newRevision = try XCTUnwrap(Packet.status(statusFrame(.buds3Pro, revision: 5), model: "Buds3Pro"))
        XCTAssertNil(newRevision.touchControls); XCTAssertTrue(newRevision.settings.isEmpty)
    }

    func testClosedWhitelistCapabilitiesAndObservedScalarGate() throws {
        for profile in Profile.allCases {
            let status = try XCTUnwrap(Packet.status(statusFrame(profile), model: profile.rawValue))
            XCTAssertTrue(profile.allows(command: 0xA0, payload: [], status: nil))
            XCTAssertTrue(profile.allows(command: 0xA1, payload: [], status: nil))
            XCTAssertEqual(profile.allows(command: 0x9D, payload: [1], status: status), profile.supportsFitTest)
            XCTAssertEqual(profile.allows(command: 0x69, payload: [], status: nil), profile.supportsCustomEqualizer)
            XCTAssertFalse(profile.allows(command: 0xAF, payload: [0], status: status))
            XCTAssertEqual(profile.allows(command: 0x78, payload: [3], status: status), [Profile.buds3Pro, .buds4Pro].contains(profile))
            XCTAssertFalse(profile.allows(command: 122, payload: [1], status: nil))
            XCTAssertEqual(profile.allows(command: 0x63, payload: [], status: nil), profile.supportsInfo)
        }
        XCTAssertTrue(Profile.buds3Pro.allows(command: 0xB4, payload: [], status: nil))
        XCTAssertFalse(Profile.buds.allows(command: 0xB4, payload: [], status: nil))
        XCTAssertTrue(Profile.buds.allows(command: 0x80, payload: [1], status: nil))
        XCTAssertTrue(Profile.budsLive.allows(command: 0x98, payload: [1], status: nil))
        XCTAssertFalse(Profile.buds4.allows(command: 0x80, payload: [1], status: nil))
        XCTAssertTrue(Profile.buds.allows(command: 0x86, payload: [1, 7], status: nil))
        XCTAssertFalse(Profile.buds.allows(command: 0x86, payload: [3], status: nil))
        XCTAssertFalse(Profile.buds2.allows(command: 0x86, payload: [7], status: nil))
        let status = try XCTUnwrap(Packet.status(statusFrame(.buds3Pro), model: "Buds3Pro"))
        XCTAssertTrue(Profile.buds3Pro.allows(command: 122, payload: [1], status: status))
        XCTAssertFalse(Profile.buds4Pro.allows(command: 122, payload: [1], status: status))
    }

    func testBuds4GestureEditsPreserveDisabledHoldAndConstantTailAcrossAcknowledgements() throws {
        for profile: Profile in [.buds4, .buds4Pro] {
            var frame = statusFrame(profile)
            var bytes = frame.payload
            bytes[10] = 0xF8 // Hold is off; unrelated master/call/swipe flags remain on.
            frame = .init(command: 0x61, payload: bytes, isFragment: false)
            let touch = try XCTUnwrap(Packet.status(frame, model: profile.rawValue)?.touchControls)
            let first = touch.payload(changing: .doublePinch, enabled: true)
            XCTAssertEqual(first, [1, 1, 1, 0, 0, 1, 1, 1, 1, 1])
            let confirmed = try XCTUnwrap(touch.replacing(with: first))
            XCTAssertEqual(confirmed.payload(changing: .triplePinch, enabled: true)[4], 0)
            XCTAssertEqual(confirmed.mediaPayload(enabled: false), [1, 0, 0, 0, 0, 1, 1, 0, 1, 1])
        }
    }

    func testLegacyGoldenCRCExactProfileAndFragmentedDelivery() throws {
        // SppMessage.Encode: FE / request=00 / size=04 / command+payload /
        // CCITT-zero CRC over 78 01 = D1 91 / EE. Header is outside CRC.
        let golden = Data([0xFE, 0, 4, 0x78, 1, 0xD1, 0x91, 0xEE])
        XCTAssertEqual(Packet.frame(command: 0x78, payload: [1], profile: .buds), golden)
        let ambient = Data([0xFE, 0, 4, 0x80, 1, 0xB9, 0x0B, 0xEE])
        let equalizer = Data([0xFE, 0, 5, 0x86, 1, 7, 0x2C, 0xCA, 0xEE])
        XCTAssertEqual(Packet.frame(command: 0x80, payload: [1], profile: .buds), ambient)
        XCTAssertEqual(Packet.frame(command: 0x86, payload: [1, 7], profile: .buds), equalizer)
        let ack = Packet.Frame(command: 0x42, payload: Data([0x86, 1, 7]), isFragment: false, legacyFraming: true)
        XCTAssertTrue(Packet.acknowledges(ack, command: 0x86, payload: [1, 7], profile: .buds))
        XCTAssertFalse(Packet.acknowledges(ack, command: 0x86, payload: [1, 8], profile: .buds))
        XCTAssertFalse(Packet.acknowledges(ack, command: 0x86, payload: [1, 7]))
        XCTAssertNil(Packet.decodeCompleteFrame(golden))
        XCTAssertEqual(Packet.decodeCompleteFrame(golden, profile: .buds)?.legacyFraming, true)
        XCTAssertNil(Packet.decodeCompleteFrame(Packet.frame(command: 0x78, payload: [1]), profile: .buds))
        for offset in [0, 2, 3, 4, 5, 6, 7] {
            var invalid = golden; invalid[offset] ^= 1
            XCTAssertNil(Packet.decodeCompleteFrame(invalid, profile: .buds))
        }
        var invalidType = golden; invalidType[1] = 2
        XCTAssertNil(Packet.decodeCompleteFrame(invalidType, profile: .buds))
        let maximum = Packet.frame(command: 0, payload: [UInt8](repeating: 0, count: 252), profile: .buds)
        XCTAssertEqual(maximum.count, 259); XCTAssertEqual(maximum[2], 255)
        XCTAssertNotNil(Packet.decodeCompleteFrame(maximum, profile: .buds))
        var stream = Packet.Stream(profile: .buds)
        XCTAssertTrue(try stream.append(golden.prefix(3), at: 0).isEmpty)
        XCTAssertEqual(try stream.append(golden.dropFirst(3), at: 0.1).count, 1)
        XCTAssertTrue(try stream.append(golden.prefix(3), at: 1).isEmpty)
        XCTAssertTrue(try stream.append(golden.dropFirst(3), at: 3.1).isEmpty)
        XCTAssertEqual(try stream.append(golden, at: 3.2).count, 1)
        var modern = Packet.Stream()
        XCTAssertTrue(try modern.append(golden, at: 0).isEmpty)
    }
}
