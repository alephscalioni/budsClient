import XCTest
@testable import BudsAutoSwitch

final class NativeSetupPacketTests: XCTestCase {
    func testWindowsClassicBluetoothSettingInfoVector() throws {
        // Static Windows wrapper/Dynamic bytes; CRC independently calculated
        // with Python binascii.crc_hqx(content, 0), not the Swift implementation.
        let vector: [UInt8] = [0xFC, 0x15, 0x00, 0x01, 0x73, 0x01, 0x01, 0x04,
            0x00, 0x01, 0x75, 0x00, 0x2A, 0x41, 0x0C, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x55, 0xC6, 0xCC]
        let packet = SamsungMdePacket.settingInfoClassicBluetooth()
        XCTAssertEqual(Array(packet), vector)
        let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(packet))
        XCTAssertEqual(decoded.command, 0x73)
        XCTAssertEqual(decoded.payload.count, 17)
        XCTAssertEqual(decoded.payload[4], 1, "Classic Bluetooth, not LE Audio")
        for end in 0..<packet.count {
            XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(packet.prefix(end))))
        }
        var corrupt = packet; corrupt[9] ^= 1
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(corrupt))
    }
}
