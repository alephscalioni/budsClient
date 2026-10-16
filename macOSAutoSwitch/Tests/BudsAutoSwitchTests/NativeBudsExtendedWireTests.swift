import Foundation
import XCTest
@testable import BudsAutoSwitch

final class NativeBudsExtendedWireTests: XCTestCase {
    func testMetadataQueriesNeverPermitPayloadOrFirmwareWrites() {
        for command: UInt8 in [0x69, 0xB4] {
            XCTAssertTrue(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: command, payload: [])))
            XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: command, payload: [1])))
        }
        for command: UInt8 in [0xBB, 0xBC, 0xBD, 0xBE] {
            XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: command, payload: [])))
        }
    }

    func testCustomCurveWhitelistRequiresNineBoundedSignedGains() {
        let good: [UInt8] = [9, 246, 247, 250, 255, 0, 1, 5, 9, 10]
        XCTAssertTrue(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x89, payload: good)))
        for bad in [Array(good.dropLast()), [8] + Array(good.dropFirst()), [9, 245] + Array(good.dropFirst(2)), [9, 11] + Array(good.dropFirst(2))] {
            XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x89, payload: bad)))
        }
        XCTAssertTrue(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x86, payload: [7])))
        XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(SamsungBudsSettingsPacket.frame(command: 0x86, payload: [8])))
    }

    func testForwardedMetadataCannotSmuggleTransferCommands() {
        for command in [0x69, 0xB4] {
            XCTAssertNotNil(NativeBudsSettingsWire.frame(["command": command, "payload": Data([0]).base64EncodedString()]))
        }
        XCTAssertNil(NativeBudsSettingsWire.frame(["command": 0xBB, "payload": ""]))
    }

    func testLegacyUpstreamUpdaterHostIsRejected() {
        XCTAssertThrowsError(try NativeAppUpdateConfiguration.read(info: [
            "SUFeedURL": "https://timschneeberger.me/updates/galaxybudsclient/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()
        ]))
    }
}
