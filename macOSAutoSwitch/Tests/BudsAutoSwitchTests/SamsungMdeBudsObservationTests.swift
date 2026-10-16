import Foundation
import XCTest
@testable import BudsAutoSwitch

final class SamsungMdeBudsObservationTests: XCTestCase {
    private typealias Facts = SamsungMdeBudsObservation

    // Synthetic fixed TLVs, independent of production packet/TLV builders.
    private func frame(_ bytes: [UInt8], command: UInt8 = 0x45,
                       fragment: Bool = false, response: Bool = false) -> SamsungMdePacket.Frame {
        .init(command: command, payload: Data(bytes), sequence: 0,
              isResponse: response, isFragment: fragment)
    }

    func testReadAndNotifyOffsets() throws {
        let notify = frame([0x06, 0x02, 1, 1, 0x07, 0x02, 1, 2, 0x1F, 0x02, 1, 1])
        let read = frame([0x00, 0x02, 0x06, 0x02, 1, 1, 0x07, 0x02, 1, 2, 0x1F, 0x02, 1, 1],
                         command: 0x44, response: true)
        let facts = try XCTUnwrap(Facts.decode(notify))
        XCTAssertEqual(Facts.decode(read), facts)
        XCTAssertEqual(facts.wearingLeft, true)
        XCTAssertEqual(facts.wearingRight, false)
        XCTAssertEqual(facts.sppConnectionCount, 1)
        XCTAssertEqual(facts.wearing, true)
        XCTAssertEqual(facts.sppConnectable, true)
        XCTAssertEqual(facts.wearingLeftObservation, .known(true))
        XCTAssertEqual(facts.wearingRightObservation, .known(false))
        XCTAssertEqual(facts.sppConnectionCountObservation, .known(1))
        // The READ selector is skipped; it need not be ALL_CURRENT_STATES.
        XCTAssertEqual(Facts.decode(frame([0x1F, 0x02, 0x1F, 0x02, 1, 1], command: 0x44))?.sppConnectionCount, 1)
    }

    func testSparseFactsDoNotDefaultToFalse() throws {
        let left = try XCTUnwrap(Facts.decode(frame([0x06, 0x02, 1, 2])))
        XCTAssertEqual(left.wearingLeft, false)
        XCTAssertEqual(left.wearingRightObservation, .unreported)
        XCTAssertEqual(left.sppConnectionCountObservation, .unreported)
        XCTAssertNil(left.wearingRight)
        XCTAssertNil(left.sppConnectionCount)
        XCTAssertNil(left.wearing)
        XCTAssertNil(left.sppConnectable)

        let right = try XCTUnwrap(Facts.decode(frame([0x07, 0x02, 1, 1])))
        XCTAssertEqual(right.wearingLeftObservation, .unreported)
        XCTAssertEqual(right.wearingRight, true)
        XCTAssertEqual(right.wearing, true)

        let spp = try XCTUnwrap(Facts.decode(frame([0x1F, 0x02, 1, 2])))
        XCTAssertEqual(spp.wearingLeftObservation, .unreported)
        XCTAssertEqual(spp.wearingRightObservation, .unreported)
        XCTAssertNil(spp.wearing)
        XCTAssertEqual(spp.sppConnectionCount, 2)
        XCTAssertEqual(spp.sppConnectable, false)
    }

    func testAbsentAndPresentUnknownAreDistinct() throws {
        let absent = try XCTUnwrap(Facts.decode(frame([])))
        let unknown = try XCTUnwrap(Facts.decode(frame([0x06, 0x02, 1, 0, 0x07, 0x02, 1, 0xFF, 0x1F, 0x02, 1, 0xFF])))
        XCTAssertEqual(absent.wearingLeftObservation, .unreported)
        XCTAssertEqual(absent.wearingRightObservation, .unreported)
        XCTAssertEqual(absent.sppConnectionCountObservation, .unreported)
        XCTAssertEqual(unknown.wearingLeftObservation, .unknown)
        XCTAssertEqual(unknown.wearingRightObservation, .unknown)
        XCTAssertEqual(unknown.sppConnectionCountObservation, .unknown)
        for facts in [absent, unknown] {
            XCTAssertNil(facts.wearingLeft)
            XCTAssertNil(facts.wearingRight)
            XCTAssertNil(facts.sppConnectionCount)
            XCTAssertNil(facts.wearing)
            XCTAssertNil(facts.sppConnectable)
        }
        XCTAssertNotEqual(absent, unknown)
        XCTAssertEqual(Facts.decode(frame([0, 2], command: 0x44)), absent)
    }

    func testCombinedWearingTruthTable() throws {
        // Rows/columns: absent, unknown zero, wearing, not wearing, unknown ff.
        let values: [UInt8?] = [nil, 0, 1, 2, 0xFF]
        let expected: [[Bool?]] = [
            [nil, nil, true, nil, nil],
            [nil, nil, true, nil, nil],
            [true, true, true, true, true],
            [nil, nil, true, false, nil],
            [nil, nil, true, nil, nil]
        ]
        for (row, left) in values.enumerated() {
            for (column, right) in values.enumerated() {
                let lhs: [UInt8] = left.map { [0x06, 0x02, 1, $0] } ?? []
                let rhs: [UInt8] = right.map { [0x07, 0x02, 1, $0] } ?? []
                let facts = try XCTUnwrap(Facts.decode(frame(lhs + rhs)))
                XCTAssertEqual(facts.wearing, expected[row][column], "combination \(row),\(column)")
            }
        }
    }

    func testWearingOnlyAcceptsDocumentedStates() throws {
        for raw in UInt8.min...UInt8.max {
            let facts = try XCTUnwrap(Facts.decode(frame([0x06, 0x02, 1, raw, 0x07, 0x02, 1, raw])))
            let expected: Facts.Observation<Bool>
            switch raw {
            case 1: expected = .known(true)
            case 2: expected = .known(false)
            default: expected = .unknown
            }
            XCTAssertEqual(facts.wearingLeftObservation, expected)
            XCTAssertEqual(facts.wearingRightObservation, expected)
            XCTAssertEqual(facts.wearing, expected.value)
        }
    }

    func testSppCountsSentinelAndEntireUndocumentedRange() throws {
        let known: [(UInt8, Int, Bool)] = [(0, 0, true), (1, 1, true), (2, 2, false)]
        for (raw, count, connectable) in known {
            let facts = try XCTUnwrap(Facts.decode(frame([0x1F, 0x02, 1, raw])))
            XCTAssertEqual(facts.sppConnectionCountObservation, .known(count))
            XCTAssertEqual(facts.sppConnectionCount, count)
            XCTAssertEqual(facts.sppConnectable, connectable)
        }
        for raw in UInt8(3)...UInt8.max {
            let facts = try XCTUnwrap(Facts.decode(frame([0x1F, 0x02, 1, raw])))
            XCTAssertEqual(facts.sppConnectionCountObservation, .unknown)
            XCTAssertNil(facts.sppConnectionCount)
            XCTAssertNil(facts.sppConnectable)
        }
    }

    func testDuplicateInvalidValueErasesPositiveEvidence() throws {
        let facts = try XCTUnwrap(Facts.decode(frame([
            0x06, 0x02, 1, 1, 0x07, 0x02, 1, 1, 0x1F, 0x02, 1, 0,
            0x06, 0x02, 1, 0, 0x07, 0x02, 1, 3, 0x1F, 0x02, 1, 0xFF
        ])))
        XCTAssertEqual(facts.wearingLeftObservation, .unknown)
        XCTAssertEqual(facts.wearingRightObservation, .unknown)
        XCTAssertEqual(facts.sppConnectionCountObservation, .unknown)
        XCTAssertNil(facts.wearing)
        XCTAssertNil(facts.sppConnectable)
    }

    func testDuplicateInvalidLengthsErasePositiveEvidence() throws {
        let positive: [UInt8] = [0x06, 0x02, 1, 1, 0x07, 0x02, 1, 1, 0x1F, 0x02, 1, 1]
        let invalid: [[UInt8]] = [
            [0x06, 0x02, 0, 0x07, 0x02, 0, 0x1F, 0x02, 0],
            [0x06, 0x02, 2, 1, 1, 0x07, 0x02, 2, 1, 1, 0x1F, 0x02, 2, 0, 0]
        ]
        for suffix in invalid {
            let facts = try XCTUnwrap(Facts.decode(frame(positive + suffix)))
            XCTAssertEqual(facts.wearingLeftObservation, .unknown)
            XCTAssertEqual(facts.wearingRightObservation, .unknown)
            XCTAssertEqual(facts.sppConnectionCountObservation, .unknown)
            XCTAssertNil(facts.wearingLeft)
            XCTAssertNil(facts.wearingRight)
            XCTAssertNil(facts.sppConnectionCount)
            XCTAssertNil(facts.wearing)
            XCTAssertNil(facts.sppConnectable)
        }
    }

    func testLastKnownOccurrenceWinsAndFramesHaveNoSharedState() throws {
        let facts = try XCTUnwrap(Facts.decode(frame([
            0x06, 0x02, 1, 0xFF, 0x06, 0x02, 1, 1, 0x06, 0x02, 1, 2,
            0x07, 0x02, 0, 0x07, 0x02, 1, 2,
            0x1F, 0x02, 1, 0xFF, 0x1F, 0x02, 1, 0, 0x1F, 0x02, 1, 2
        ])))
        XCTAssertEqual(facts.wearingLeftObservation, .known(false))
        XCTAssertEqual(facts.wearingRightObservation, .known(false))
        XCTAssertEqual(facts.wearing, false)
        XCTAssertEqual(facts.sppConnectionCountObservation, .known(2))
        XCTAssertEqual(facts.sppConnectable, false)
        let next = try XCTUnwrap(Facts.decode(frame([])))
        XCTAssertEqual(next.wearingLeftObservation, .unreported)
        XCTAssertEqual(next.wearingRightObservation, .unreported)
        XCTAssertEqual(next.sppConnectionCountObservation, .unreported)
    }

    func testMalformedSuffixAfterPositiveInvalidatesEntireFrame() {
        let positive: [UInt8] = [0x06, 0x02, 1, 1, 0x1F, 0x02, 1, 0]
        let suffixes: [[UInt8]] = [
            [0x07], [0x07, 0x02], [0x07, 0x02, 1], [0x07, 0x02, 2, 1],
            [0xF0], [0xF0, 0x7F], [0xF0, 0x7F, 1], [0xF0, 0x7F, 255, 0]
        ]
        for suffix in suffixes {
            XCTAssertNil(Facts.decode(frame(positive + suffix)))
            XCTAssertNil(Facts.decode(frame([0, 2] + positive + suffix, command: 0x44)))
        }
    }

    func testTruncatedTlvAndReadPrefixAreRejected() {
        for payload: [UInt8] in [[], [0]] {
            XCTAssertNil(Facts.decode(frame(payload, command: 0x44)))
        }
        for tlv: [UInt8] in [[0x06, 0x02, 1, 1], [0x07, 0x02, 2, 1, 2], [0x1F, 0x02, 1, 0]] {
            for end in 1..<tlv.count {
                let truncated = Array(tlv.prefix(end))
                XCTAssertNil(Facts.decode(frame(truncated)))
                XCTAssertNil(Facts.decode(frame([0, 2] + truncated, command: 0x44)))
            }
        }
    }

    func testOnlyReadNotifyAndNonfragmentedFramesAreAccepted() {
        let positive: [UInt8] = [0x06, 0x02, 1, 1]
        for command in UInt8.min...UInt8.max where command != 0x44 && command != 0x45 {
            XCTAssertNil(Facts.decode(frame(positive, command: command)))
        }
        for response in [false, true] {
            XCTAssertNil(Facts.decode(frame(positive, fragment: true, response: response)))
            XCTAssertNil(Facts.decode(frame([0, 2] + positive, command: 0x44, fragment: true, response: response)))
            XCTAssertEqual(Facts.decode(frame(positive, response: response))?.wearing, true)
            XCTAssertEqual(Facts.decode(frame([0, 2] + positive, command: 0x44, response: response))?.wearing, true)
        }
    }

    func testUnrelatedPropertiesAreIgnoredWithoutRetainingValues() throws {
        // Synthetic filler only, with no identifiers, account data or captures.
        let unrelated: [UInt8] = [0xF0, 0x7F, 2, 0xA5, 0x5A, 0xF1, 0x7F, 0]
        let positive: [UInt8] = [0x06, 0x02, 1, 1]
        XCTAssertEqual(Facts.decode(frame(unrelated + positive + unrelated)), Facts.decode(frame(positive)))
        let empty = try XCTUnwrap(Facts.decode(frame([])))
        XCTAssertEqual(Facts.decode(frame(unrelated)), empty)
        // Only the three typed evidence fields are stored; no raw input survives.
        let facts = try XCTUnwrap(Facts.decode(frame(unrelated + positive)))
        XCTAssertEqual(Set(Mirror(reflecting: facts).children.compactMap(\.label)),
                       ["wearingLeftObservation", "wearingRightObservation", "sppConnectionCountObservation"])
    }

    func testMaximumPayloadAndTlvTraversalFollowAcceptedFrameContract() throws {
        // 338 empty unknown TLVs plus one five-byte unknown TLV = 1019 bytes.
        let emptyTlv: [UInt8] = [0xF0, 0x7F, 0]
        let padding = Array(repeating: emptyTlv, count: 338).flatMap { $0 }
        let maximumNotify = padding + [0xF1, 0x7F, 2, 0, 0]
        let maximumRead: [UInt8] = [0, 2] + padding + [0xF1, 0x7F, 0]
        XCTAssertEqual(maximumNotify.count, 1019)
        XCTAssertEqual(maximumRead.count, 1019)
        XCTAssertNotNil(Facts.decode(frame(maximumNotify)))
        XCTAssertNotNil(Facts.decode(frame(maximumRead, command: 0x44)))
        // Oversized but syntactically complete streams are rejected too.
        let oversized = Array(repeating: emptyTlv, count: 340).flatMap { $0 }
        XCTAssertEqual(oversized.count, 1020)
        XCTAssertNil(Facts.decode(frame(oversized)))
        XCTAssertNil(Facts.decode(frame([0, 2] + oversized, command: 0x44)))
        // Relevant evidence beyond 64/256 TLVs must still be processed.
        XCTAssertEqual(Facts.decode(frame(padding + [0x06, 0x02, 1, 1]))?.wearing, true)
        XCTAssertEqual(Facts.decode(frame(padding + [0x1F, 0x02, 1, 2]))?.sppConnectable, false)
    }

    func testMaximumTlvValueLengthIsTraversedAndRelevantLengthIsUnknown() throws {
        let value = [UInt8](repeating: 0, count: 255)
        let unrelated: [UInt8] = [0xF0, 0x7F, 255] + value
        XCTAssertEqual(Facts.decode(frame(unrelated + [0x06, 0x02, 1, 1]))?.wearing, true)
        for key: UInt8 in [0x06, 0x07, 0x1F] {
            let facts = try XCTUnwrap(Facts.decode(frame([key, 0x02, 255] + value)))
            switch key {
            case 0x06: XCTAssertEqual(facts.wearingLeftObservation, .unknown)
            case 0x07: XCTAssertEqual(facts.wearingRightObservation, .unknown)
            default: XCTAssertEqual(facts.sppConnectionCountObservation, .unknown)
            }
        }
        XCTAssertNil(Facts.decode(frame(Array(unrelated.dropLast()))))
    }
}
