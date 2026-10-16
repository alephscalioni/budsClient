import XCTest
@testable import BudsAutoSwitch

final class NativePacketDiagnosticsTests: XCTestCase {
    func testDiagnosticDoesNotRetainOtherPropertyValues() throws {
        let secret = Array("PRIVATE-ACCOUNT-MATERIAL".utf8)
        let payload = [UInt8(0x02), 0x05, UInt8(secret.count)] + secret + [0x13,0x02,0x01,0x01]
        let frame = SamsungMdePacket.Frame(command: 0x45, payload: Data(payload), sequence: 0,
                                           isResponse: false, isFragment: false)
        let summary = SamsungMdePacket.diagnosticSummary(frame)
        let json = try JSONSerialization.data(withJSONObject: summary)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(summary["seamless_connection_raw"] as? Int, 1)
        let properties = try XCTUnwrap(summary["properties"] as? [[String: Int]])
        XCTAssertEqual(properties.first, ["id":1282,"length":secret.count])
        XCTAssertTrue(properties.allSatisfy { Set($0.keys) == ["id", "length"] })
    }

    func testMalformedPropertyCannotPublishAnEarlierRawValue() {
        let frame = SamsungMdePacket.Frame(command: 0x44, payload: Data([0x13,0x02,0x13,0x02,1,0,0xFF]),
                                           sequence: 0, isResponse: true, isFragment: false)
        let summary = SamsungMdePacket.diagnosticSummary(frame)
        XCTAssertEqual(summary["properties_valid"] as? Bool, false)
        XCTAssertNil(summary["seamless_connection_raw"])
    }

    func testReadSeamlessUsesExistingPropertyIDWithoutWriting() {
        // Python binascii.crc_hqx independent CRC vector from existing SMEP reader.
        XCTAssertEqual(Array(SamsungMdePacket.readSeamlessConnection()),
                       [0xFC,0x06,0,1,0x44,0x13,0x02,0xBB,0xC1,0xCC])
    }
}
