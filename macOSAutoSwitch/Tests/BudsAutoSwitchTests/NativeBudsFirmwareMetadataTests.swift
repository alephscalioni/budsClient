import Foundation
import XCTest
@testable import BudsAutoSwitch

final class NativeBudsFirmwareMetadataTests: XCTestCase {
    private func frame(_ properties: [UInt8], read: Bool = true, fragment: Bool = false) -> SamsungMdePacket.Frame {
        .init(command: read ? 0x44 : 0x45, payload: Data((read ? [0xFF, 0xFF] : []) + properties),
              sequence: 1, isResponse: read, isFragment: fragment)
    }
    private func property(_ value: String = "R630XXU0AZG2") -> [UInt8] { [0x17, 0x02, UInt8(value.utf8.count)] + value.utf8 }

    func testActualVersionPropertyCanBeReadWithoutEnteringOTA() {
        for read in [true, false] {
            XCTAssertEqual(SamsungMdePacket.firmwareVersion(frame([0x08, 0x02, 1, 80] + property(), read: read)), "R630XXU0AZG2")
        }
        XCTAssertNil(SamsungMdePacket.firmwareVersion(frame([0x08, 0x02, 1, 80])))
    }
    func testUnknownModelsMalformedASCIIAndConflictingPropertiesStayUnknown() {
        for value in ["", "R630XXU0AZG", "R630XXU0AZG22", "R540XXU0AZG2", "r630XXU0AZG2", "R630XXU0AZG\0", "R630XXU0AZG "] {
            XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(property(value))))
        }
        XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(property() + property("R630XXU0AZD2"))))
        XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(property(), fragment: true)))
    }
    func testTruncationOrMalformedTrailingTLVInvalidatesTheWholeMetadataReading() {
        let bytes = property()
        for count in 0..<bytes.count { XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(Array(bytes.prefix(count))))) }
        XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(bytes + [1, 2])))
        XCTAssertNil(SamsungMdePacket.firmwareVersion(frame(bytes + [1, 2, 8, 0])))
    }
}
