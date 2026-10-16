import XCTest
@testable import BudsAutoSwitch

final class SamsungContinuityBudsContextTests: XCTestCase {
    typealias B = SamsungContinuityBudsContext

    func testFlagsTable() throws {
        // Fixed protocol expectations, independent of the encoder's bit packing.
        let rows: [(B.HFP, Bool, Bool, Bool, Bool, Bool, UInt8)] = [
            (.absent, false, false, false, false, false, 0x00),
            (.connected, false, false, false, false, false, 0x01),
            (.audioActive, false, false, false, false, false, 0x02),
            (.absent, true, false, false, false, false, 0x04),
            (.absent, false, true, false, false, false, 0x08),
            (.absent, false, false, true, false, false, 0x10),
            (.absent, false, false, false, true, false, 0x20),
            (.absent, false, false, false, false, true, 0x40),
            (.absent, true, true, false, false, false, 0x0c),
            (.connected, true, true, false, false, false, 0x0d),
            (.absent, true, true, true, true, true, 0x7c),
            (.connected, true, true, true, true, true, 0x7d),
            (.audioActive, true, true, true, true, true, 0x7e)
        ]
        let address = try SamsungPeerAddress(bytes: Data([0x02, 0x13, 0x24, 0x35, 0x46, 0x57]))
        for (hfp, a2dp, foreground, bis, wearing, spp, expected) in rows {
            let b = B(address: address, hfp: hfp, a2dp: a2dp, foreground: foreground,
                      bis: bis, wearing: wearing, sppConnectable: spp)
            XCTAssertEqual(b.encode(), Data([0x33, 0x11, 0x57, expected]))
            XCTAssertEqual(b.encode().count, 4) // no extras or volume
            XCTAssertEqual(b.encode()[3] & 0x80, 0)
        }
        XCTAssertNil(B.HFP(rawValue: 3))
        XCTAssertNil(B.HFP(rawValue: 255))
    }

    func testIndependentSyntheticAddressVectors() throws {
        let rows: [([UInt8], [UInt8])] = [
            ([0x02, 0x13, 0x24, 0x35, 0x46, 0x57], [0x33, 0x11, 0x57, 0x02]),
            ([0xff, 0x00, 0x80, 0x01, 0x02, 0xa5], [0x33, 0xd9, 0xa5, 0x02]),
            ([0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc], [0x33, 0x2e, 0xbc, 0x02]),
            ([0, 0, 0, 0, 0, 0], [0x33, 0, 0, 0x02])
        ]
        for (address, expected) in rows {
            let b = B(address: try .init(bytes: Data(address)), hfp: .audioActive,
                      a2dp: false, foreground: false, bis: false, wearing: false,
                      sppConnectable: false)
            XCTAssertEqual(b.encode(), Data(expected))
            XCTAssertEqual(b.encode(), b.encode())
        }
    }

    func testDescriptionsRedactAddressAndState() throws {
        let b = B(address: try .init(bytes: Data([0xff, 0, 0x80, 1, 2, 0xa5])),
                  hfp: .connected, a2dp: true, foreground: true,
                  bis: false, wearing: false, sppConnectable: false)
        XCTAssertEqual(String(describing: b), "SamsungContinuityBudsContext(redacted)")
        XCTAssertEqual(String(reflecting: b), "SamsungContinuityBudsContext(redacted)")
    }
}
