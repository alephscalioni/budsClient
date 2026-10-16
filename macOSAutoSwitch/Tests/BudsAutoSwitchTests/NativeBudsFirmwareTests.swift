// SPDX-License-Identifier: GPL-3.0-only
// Synthetic format/protocol tests for the Swift adaptation of GalaxyBudsClient
// by Tim Schneeberger (timschneeb) and contributors. See repository LICENSE and
// NativeBudsFirmware.swift for source attribution and single-reference CRC evidence.
// Default tests use synthetic bytes only. One optional local reference read needs
// BUDS3PRO_FIRMWARE_REFERENCE_PATH explicitly set. No network or device IO is used.

import CryptoKit
import Foundation
import XCTest
@testable import BudsAutoSwitch

final class NativeBudsFirmwareTests: XCTestCase {
    private typealias F = NativeBudsFirmware

    private func le(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }
    private func readLE(_ bytes: Data) -> UInt32 {
        Array(bytes.prefix(4)).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    /// Deliberately independent bit-at-a-time fixture checksum; the production
    /// implementation uses a lookup table. The standard check vector is tested.
    private func fixtureCRC<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var accumulator = UInt32.max
        for byte in bytes {
            accumulator ^= UInt32(byte)
            for _ in 0..<8 {
                if accumulator & 1 != 0 { accumulator = (accumulator >> 1) ^ 0xEDB88320 }
                else { accumulator >>= 1 }
            }
        }
        return ~accumulator
    }
    private func put(_ value: UInt32, in bytes: inout Data, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 4), with: le(value))
    }
    private func sealSyntheticWholeContainer(_ bytes: inout Data) {
        let checksum = fixtureCRC(bytes.dropLast(4))
        let position = bytes.count - 4
        put(checksum, in: &bytes, at: position)
    }
    /// Generic shipped layout with a deliberately synthetic whole-file checksum.
    /// This fixture is not evidence of vendor checksum coverage or installation.
    private func syntheticContainer(_ entries: [(Int, Data)], declaredSize: Int? = nil, gap: Int = 0) -> Data {
        let headerSize = 12 + entries.count * 16
        let fileSize = headerSize + gap + entries.reduce(0) { $0 + $1.1.count } + 4
        var bytes = Data(le(0xCAFECAFE) + le(UInt32(declaredSize ?? fileSize)) + le(UInt32(entries.count)))
        var position = headerSize + gap
        for (id, raw) in entries {
            bytes.append(contentsOf: le(UInt32(id)) + le(fixtureCRC(raw)) + le(UInt32(position)) + le(UInt32(raw.count)))
            position += raw.count
        }
        bytes.append(Data(repeating: 0, count: gap))
        for (_, raw) in entries { bytes.append(raw) }
        bytes.append(contentsOf: le(fixtureCRC(bytes)))
        return bytes
    }
    private func image(_ model: String = "SM-R630", size: Int = 1500) -> Data {
        var bytes = Data((model + "\0").utf8)
        bytes.append(Data(repeating: 0xA5, count: max(0, size - bytes.count)))
        return bytes
    }
    private func syntheticBinary(_ model: String = "SM-R630", size: Int = 1500) throws -> F.Binary {
        try F.parse(syntheticContainer([(7, image(model, size: size))]), checksum: .syntheticWholeContainerCRC32ISOHDLC)
    }
    /// Small synthetic data with the structure observed in R630XXU0AZG2:
    /// complete-file TotalSize, id 6 at 28, no gaps, segment CRC == trailer.
    /// The payload/length/digest are not the downloaded firmware's bytes.
    private func buds3ProSingleSegmentFixture(_ raw: Data) -> Data {
        let crc = fixtureCRC(raw)
        var bytes = Data(le(F.magic) + le(UInt32(raw.count + 32)) + le(1))
        bytes.append(contentsOf: le(6) + le(crc) + le(28) + le(UInt32(raw.count)))
        bytes.append(raw)
        bytes.append(contentsOf: le(crc))
        return bytes
    }
    private func expectFailure<T>(_ expected: F.Failure? = nil, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> T) {
        do { _ = try body(); XCTFail("Expected a firmware failure", file: file, line: line) }
        catch let failure as F.Failure {
            if let expected { XCTAssertEqual(failure, expected, file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    private func send(_ transfer: inout F.Transfer, _ command: UInt8, _ payload: [UInt8],
                      at now: TimeInterval = 1) throws -> [F.Packet] {
        try transfer.receive(command: command, payload: Data(payload), at: now)
    }
    private func uploading(size: Int = 1500, mtu: Int = 650) throws -> F.Transfer {
        var transfer = F.Transfer()
        _ = try transfer.begin(syntheticBinary(size: size), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        _ = try send(&transfer, 0xBB, [0])
        _ = try send(&transfer, 0xBC, [0, UInt8(truncatingIfNeeded: mtu), UInt8(mtu >> 8)])
        _ = try send(&transfer, 0xBC, [1, 7, 0])
        return transfer
    }

    func testSyntheticFixtureMatchesObservedBuds3ProSingleSegmentProfile() throws {
        let raw = image("R630XXU0AZG2", size: 96)
        let bytes = buds3ProSingleSegmentFixture(raw)
        let parsed = try F.parse(bytes, checksum: .verifiedBuds3ProSingleSegment)
        XCTAssertEqual(parsed.checksumPolicy, .verifiedBuds3ProSingleSegment)
        XCTAssertEqual(parsed.totalSize, bytes.count)
        XCTAssertEqual(parsed.detectedModel, .buds3Pro)
        XCTAssertEqual(parsed.segments.count, 1)
        XCTAssertEqual(parsed.segments[0].id, 6)
        XCTAssertEqual(parsed.segments[0].position, 28)
        XCTAssertEqual(parsed.segments[0].size, bytes.count - 32)
        XCTAssertEqual(parsed.segments[0].rawData, raw)
        XCTAssertEqual(parsed.segments[0].crc32, fixtureCRC(raw))
        XCTAssertEqual(parsed.crc32, parsed.segments[0].crc32)
        XCTAssertEqual(try parsed.serializeTable(),
                       Data(le(fixtureCRC(raw)) + [1, 6] + le(UInt32(raw.count)) + le(fixtureCRC(raw))))
        let wholeFileCRC = fixtureCRC(bytes.dropLast(4))
        XCTAssertNotEqual(wholeFileCRC, parsed.crc32)
        expectFailure(.checksumMismatch(segmentID: nil, expected: parsed.crc32, actual: wholeFileCRC)) {
            try F.parse(bytes, checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        // A returned open packet is only a pure plan, not installation evidence.
        var transfer = F.Transfer()
        XCTAssertEqual(try transfer.begin(parsed, targetModel: .buds3Pro, at: 0).first?.command, .open)
        var padded = Data([0xFF, 0xFF]); padded.append(bytes)
        XCTAssertEqual(try F.parse(padded.dropFirst(2), checksum: .verifiedBuds3ProSingleSegment), parsed)
    }

    func testVerifiedProfileRejectsOtherStructuresWhileGenericInspectionRemainsAvailable() throws {
        let raw = image(size: 96)
        let valid = buds3ProSingleSegmentFixture(raw)
        var wrongTotal = valid; put(UInt32(valid.count - 4), in: &wrongTotal, at: 4)
        var wrongID = valid; put(7, in: &wrongID, at: 12)
        var shortSegment = valid; put(UInt32(raw.count - 1), in: &shortSegment, at: 24)
        var leadingGap = syntheticContainer([(6, raw)], gap: 1)
        let leadingTrailerOffset = leadingGap.count - 4
        put(fixtureCRC(raw), in: &leadingGap, at: leadingTrailerOffset)
        var trailingGap = valid
        trailingGap.insert(0, at: trailingGap.count - 4)
        let trailingFileSize = UInt32(trailingGap.count)
        put(trailingFileSize, in: &trailingGap, at: 4)
        let multipleSegments = syntheticContainer([(6, raw), (7, Data([1, 2, 3]))])
        for bytes in [wrongTotal, wrongID, shortSegment, leadingGap, trailingGap, multipleSegments] {
            expectFailure(.unsupportedBuds3ProSingleSegmentProfile) {
                try F.parse(bytes, checksum: .verifiedBuds3ProSingleSegment)
            }
            let inspected = try F.parse(bytes, checksum: .inspectWithoutValidation)
            var transfer = F.Transfer()
            expectFailure(.checksumNotVerified) { try transfer.begin(inspected, targetModel: .buds3Pro, at: 0) }
            XCTAssertEqual(transfer.state, .ready)
            XCTAssertNil(transfer.deadline)
        }
    }

    func testVerifiedProfileChecksSegmentBytesAndMatchingTrailerIndependently() throws {
        let raw = image(size: 96)
        let valid = buds3ProSingleSegmentFixture(raw)
        let crc = fixtureCRC(raw)
        let trailerOffset = valid.count - 4
        var badTrailer = valid; put(crc ^ 1, in: &badTrailer, at: trailerOffset)
        expectFailure(.checksumMismatch(segmentID: nil, expected: crc, actual: crc ^ 1)) {
            try F.parse(badTrailer, checksum: .verifiedBuds3ProSingleSegment)
        }
        var badData = valid; badData[badData.count - 5] ^= 1
        expectFailure(.checksumMismatch(segmentID: 6, expected: crc,
                                        actual: fixtureCRC(badData.subdata(in: 28..<(badData.count - 4))))) {
            try F.parse(badData, checksum: .verifiedBuds3ProSingleSegment)
        }
        // Mutually agreeing CRC fields still cannot validate different data.
        var matchingBadCRCs = valid
        put(crc ^ 1, in: &matchingBadCRCs, at: 16)
        put(crc ^ 1, in: &matchingBadCRCs, at: trailerOffset)
        expectFailure(.checksumMismatch(segmentID: 6, expected: crc ^ 1, actual: crc)) {
            try F.parse(matchingBadCRCs, checksum: .verifiedBuds3ProSingleSegment)
        }
    }

    func testSyntheticPolicyAndOtherModelsCannotSatisfyDefaultTransferEligibility() throws {
        for marker in ["R630", "R540", "R640"] {
            let synthetic = try syntheticBinary(marker, size: 96)
            let model = try XCTUnwrap(synthetic.detectedModel)
            var transfer = F.Transfer()
            expectFailure(.checksumNotVerified) { try transfer.begin(synthetic, targetModel: model, at: 0) }
            XCTAssertEqual(transfer.state, .ready)
            XCTAssertNil(transfer.deadline)
            XCTAssertEqual(try transfer.begin(synthetic, targetModel: model, at: 0,
                                              policy: .syntheticTestOnly).first?.command, .open)
        }
        for (marker, model) in [("R540", F.Model.buds4), ("R640", F.Model.buds4Pro)] {
            // Matching structure/CRCs do not establish a verified profile for another model.
            let parsed = try F.parse(buds3ProSingleSegmentFixture(image(marker, size: 96)),
                                     checksum: .verifiedBuds3ProSingleSegment)
            var transfer = F.Transfer()
            expectFailure(.unsupportedBuds3ProSingleSegmentProfile) {
                try transfer.begin(parsed, targetModel: model, at: 0)
            }
            XCTAssertEqual(transfer.state, .ready)
        }
        let verified = try F.parse(buds3ProSingleSegmentFixture(image(size: 96)),
                                   checksum: .verifiedBuds3ProSingleSegment)
        var wrongTarget = F.Transfer()
        expectFailure(.modelMismatch(expected: .buds4, actual: .buds3Pro)) {
            try wrongTarget.begin(verified, targetModel: .buds4, at: 0)
        }
    }

    func testVerifiedOuterProfileDoesNotInferNestedChecksumCoverage() throws {
        var nested = syntheticContainer([(7, image(size: 96))])
        nested[nested.count - 1] ^= 1 // Invalid synthetic inner CRC, valid outer segment CRC.
        let outer = buds3ProSingleSegmentFixture(nested)
        let parsed = try F.parse(outer, checksum: .verifiedBuds3ProSingleSegment, fullAnalysis: true)
        let inspectedInner = try XCTUnwrap(parsed.segments[0].nestedBinary)
        XCTAssertEqual(inspectedInner.checksumPolicy, .inspectWithoutValidation)
        expectFailure(.checksumNotVerified) { try inspectedInner.validateTarget(.buds3Pro) }
    }

    /// Optional read-only reference check. Opt in with an explicit local path,
    /// e.g. BUDS3PRO_FIRMWARE_REFERENCE_PATH=/tmp/buds3pro-firmware-reference.bin.
    /// Nothing is downloaded, bundled, written, or sent to a device. This checks
    /// the exact reference digest/structure/CRC, not target identity or install.
    /// Source: https://fw.timschneeberger.me/v3/firmware/download/R630XXU0AZG2
    /// Host measurements: /tmp/buds-firmware-crc-reference.json.
    func testOptionalLocalR630XXU0AZG2Reference() throws {
        guard let path = ProcessInfo.processInfo.environment["BUDS3PRO_FIRMWARE_REFERENCE_PATH"], !path.isEmpty else {
            throw XCTSkip("Set BUDS3PRO_FIRMWARE_REFERENCE_PATH to opt in to a local reference read")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == 8_683_104,
              digest == "2e1bd0151459c21daf2d669c6ff6b548821140a6247817fce9534a12299622ce" else {
            XCTFail("Expected the exact 8,683,104-byte R630XXU0AZG2 reference with documented SHA256; got \(bytes.count) bytes, SHA256 \(digest)")
            return
        }
        XCTAssertEqual(readLE(bytes), 0xCAFECAFE)
        let parsed = try F.parse(bytes, checksum: .verifiedBuds3ProSingleSegment)
        XCTAssertEqual(parsed.totalSize, bytes.count)
        XCTAssertEqual(parsed.segments.count, 1)
        let segment = try XCTUnwrap(parsed.segments.first)
        XCTAssertEqual(segment.id, 6)
        XCTAssertEqual(segment.position, 28)
        XCTAssertEqual(segment.size, 8_683_072)
        XCTAssertEqual(segment.crc32, 0x0985CC89)
        XCTAssertEqual(fixtureCRC(segment.rawData), 0x0985CC89)
        XCTAssertEqual(parsed.crc32, segment.crc32)
        XCTAssertEqual(readLE(bytes.suffix(4)), segment.crc32)
        let wholeFileCRC = F.crc32ISOHDLC(bytes.dropLast(4))
        XCTAssertEqual(wholeFileCRC, 0x5F4DA4C4)
        XCTAssertNotEqual(wholeFileCRC, parsed.crc32)
    }

    func testIndependentCRCVectorAndExactContainerAndWireTable() throws {
        XCTAssertEqual(fixtureCRC(Array("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(F.crc32ISOHDLC(Array("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(F.crc32ISOHDLC(Data()), 0)
        let first = Data("SM-R630\0first".utf8), second = Data([0x00, 0xFF, 0x82, 0x01])
        let bytes = syntheticContainer([(7, first), (2, second)], gap: 3)
        let parsed = try F.parse(bytes, buildName: "untrusted-file-name-R640", checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertEqual(parsed.totalSize, bytes.count)
        XCTAssertEqual(parsed.detectedModel, .buds3Pro, "Build name never overrides embedded evidence")
        XCTAssertEqual(parsed.segments.map(\.id), [7, 2])
        XCTAssertEqual(parsed.segments[0].position, 47)
        XCTAssertEqual(parsed.segments[1].position, 47 + first.count)
        XCTAssertEqual(parsed.segment(id: 7)?.rawData, first)
        XCTAssertNil(parsed.segment(id: -1)); XCTAssertNil(parsed.segment(id: 256))
        var expected = le(fixtureCRC(bytes.dropLast(4))) + [2, 7]
        expected += le(UInt32(first.count)) + le(fixtureCRC(first))
        expected += [2] + le(UInt32(second.count)) + le(fixtureCRC(second))
        XCTAssertEqual(try parsed.serializeTable(), Data(expected))
        XCTAssertEqual(try parsed.serializeTable().count, 23)
        // Generic/synthetic parsing preserves metadata without imposing the
        // complete-file TotalSize invariant of the observed Buds3Pro profile.
        let declared = try F.parse(syntheticContainer([(7, first)], declaredSize: 1), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertEqual(declared.totalSize, 1)
        // Foundation Data slices can have nonzero indices.
        var padded = Data([9, 9]); padded.append(bytes)
        XCTAssertEqual(try F.parse(padded.dropFirst(2), checksum: .syntheticWholeContainerCRC32ISOHDLC),
                       try F.parse(bytes, checksum: .syntheticWholeContainerCRC32ISOHDLC))
    }

    func testContainerTruncationDebugMagicSignedBoundsAndTableBounds() throws {
        let valid = syntheticContainer([(7, image(size: 32))])
        for length in 0..<valid.count {
            expectFailure { try F.parse(Data(valid.prefix(length)), checksum: .syntheticWholeContainerCRC32ISOHDLC) }
        }
        expectFailure(.unsupportedDebugContainer) {
            try F.parse(Data(le(0x42434F4D)), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        expectFailure(.unsupportedDebugContainer) {
            try F.parse(Data(":02000004FE00FC".utf8), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        expectFailure(.invalidMagic(0)) { try F.parse(Data(repeating: 0, count: 16), checksum: .syntheticWholeContainerCRC32ISOHDLC) }
        for value in [UInt32(0), 0xFFFFFFFF, 0x80000000, UInt32(F.maximumContainerBytes + 1)] {
            var malformed = valid; put(value, in: &malformed, at: 4)
            expectFailure(.invalidDeclaredSize(Int(Int32(bitPattern: value)))) {
                try F.parse(malformed, checksum: .inspectWithoutValidation)
            }
        }
        for count in [UInt32(0), 256, 0xFFFFFFFF, 0x7FFFFFFF] {
            var malformed = valid; put(count, in: &malformed, at: 8)
            expectFailure(.invalidSegmentCount(Int(Int32(bitPattern: count)))) {
                try F.parse(malformed, checksum: .inspectWithoutValidation)
            }
        }
        var tooShort = valid; put(255, in: &tooShort, at: 8)
        expectFailure(.truncatedContainer) { try F.parse(tooShort, checksum: .inspectWithoutValidation) }
        for id in [UInt32(256), 0xFFFFFFFF, 0x7FFFFFFF] {
            var malformed = valid; put(id, in: &malformed, at: 12)
            expectFailure(.invalidSegmentID(Int(Int32(bitPattern: id)))) {
                try F.parse(malformed, checksum: .inspectWithoutValidation)
            }
        }
        let badRanges: [(UInt32, UInt32)] = [(0, 1), (27, 1), (0xFFFFFFFF, 1), (28, 0),
                                            (28, 0xFFFFFFFF), (28, 0x7FFFFFFF), (UInt32(valid.count - 4), 1)]
        for (position, size) in badRanges {
            var malformed = valid
            put(position, in: &malformed, at: 20); put(size, in: &malformed, at: 24)
            expectFailure(.invalidSegmentRange(id: 7, position: Int(Int32(bitPattern: position)),
                                              size: Int(Int32(bitPattern: size)))) {
                try F.parse(malformed, checksum: .inspectWithoutValidation)
            }
        }
    }

    func testDuplicateOverlappingSegmentsAndWireTableCountLimit() throws {
        expectFailure(.duplicateSegmentID(7)) {
            try F.parse(syntheticContainer([(7, image()), (7, image())]), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        var overlapping = syntheticContainer([(7, image()), (8, image())])
        put(44, in: &overlapping, at: 36) // Second entry starts at the first entry's absolute offset.
        expectFailure(.overlappingSegments) { try F.parse(overlapping, checksum: .inspectWithoutValidation) }
        let entries = (0..<113).map { ($0, image(size: 8)) }
        let parsed = try F.parse(syntheticContainer(entries), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        expectFailure(.tableTooLarge) { try parsed.serializeTable() }
        var transfer = F.Transfer()
        expectFailure(.tableTooLarge) { try transfer.begin(parsed, targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly) }
        XCTAssertEqual(transfer.state, .ready)
        let largest = try F.parse(syntheticContainer(Array(entries.prefix(112))), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertEqual(try largest.serializeTable().count, 1013)
        XCTAssertEqual(try F.Packet(command: .open, type: .request, payload: largest.serializeTable()).encodedSPPNew().count, 1020)
    }

    func testContainerByteBudgetAndUnsortedAbsoluteSegments() throws {
        let oversized = Data(repeating: 0, count: F.maximumContainerBytes + 1)
        expectFailure(.invalidContainerSize(oversized.count)) {
            try F.parse(oversized, checksum: .inspectWithoutValidation)
        }
        var unsorted = syntheticContainer([(7, image(size: 32)), (9, Data([1, 2, 3]))])
        let firstEntry = unsorted.subdata(in: 12..<28)
        let secondEntry = unsorted.subdata(in: 28..<44)
        unsorted.replaceSubrange(12..<28, with: secondEntry)
        unsorted.replaceSubrange(28..<44, with: firstEntry)
        sealSyntheticWholeContainer(&unsorted)
        let parsed = try F.parse(unsorted, checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertEqual(parsed.segments.map(\.id), [9, 7], "Table order is preserved independently of absolute offsets")
        XCTAssertEqual(parsed.segment(id: 9)?.rawData, Data([1, 2, 3]))
        XCTAssertEqual(parsed.segment(id: 7)?.rawData, image(size: 32))
    }

    func testContainerAndSegmentCRCFailuresAreSeparateAndInspectionCannotBegin() throws {
        let valid = syntheticContainer([(7, image(size: 32))])
        var corrupted = valid; corrupted[corrupted.count - 5] ^= 1
        expectFailure(.checksumMismatch(segmentID: nil, expected: readLE(valid.suffix(4)),
                                        actual: fixtureCRC(corrupted.dropLast(4)))) {
            try F.parse(corrupted, checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        sealSyntheticWholeContainer(&corrupted) // Container now passes, but the segment checksum must still fail.
        expectFailure(.checksumMismatch(segmentID: 7, expected: readLE(valid.subdata(in: 16..<20)),
                                        actual: fixtureCRC(corrupted.subdata(in: 28..<(corrupted.count - 4))))) {
            try F.parse(corrupted, checksum: .syntheticWholeContainerCRC32ISOHDLC)
        }
        let inspected = try F.parse(corrupted, checksum: .inspectWithoutValidation)
        XCTAssertEqual(inspected.checksumPolicy, .inspectWithoutValidation)
        var transfer = F.Transfer()
        expectFailure(.checksumNotVerified) { try transfer.begin(inspected, targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly) }
        XCTAssertEqual(transfer.state, .ready); XCTAssertNil(transfer.deadline)
    }

    func testNestedAnalysisUsesSameFormatChecksumsAndDepthLimit() throws {
        let inner = syntheticContainer([(2, image("R640XXU0ABC", size: 32))])
        let outer = syntheticContainer([(7, inner)])
        let inspected = try F.parse(outer, checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertNil(inspected.segments[0].nestedBinary)
        let analyzed = try F.parse(outer, checksum: .syntheticWholeContainerCRC32ISOHDLC, fullAnalysis: true)
        XCTAssertEqual(analyzed.detectedModel, .buds4Pro)
        XCTAssertEqual(analyzed.segments[0].nestedBinary?.segments[0].id, 2)
        var deep = inner
        for _ in 0...F.maximumNestedDepth { deep = syntheticContainer([(7, deep)]) }
        expectFailure(.analysisLimit) { try F.parse(deep, checksum: .syntheticWholeContainerCRC32ISOHDLC, fullAnalysis: true) }
        var badInner = inner; badInner[badInner.count - 1] ^= 1
        let outerWithBadInner = syntheticContainer([(7, badInner)]) // Outer CRCs valid, nested CRC invalid.
        expectFailure { try F.parse(outerWithBadInner, checksum: .syntheticWholeContainerCRC32ISOHDLC, fullAnalysis: true) }
    }

    func testFailClosedModelEvidenceForAllThreeModelsAndCrossModelImages() throws {
        let supported: [(F.Model, String)] = [(.buds3Pro, "R630"), (.buds4, "R540"), (.buds4Pro, "R640")]
        for (model, sku) in supported {
            XCTAssertEqual(F.Model(identifier: sku), model)
            XCTAssertEqual(F.Model(identifier: " SM-" + sku + "\n"), model)
            for marker in [sku, "SM-" + sku, sku + "XXU0ABC"] {
                let parsed = try syntheticBinary(marker)
                XCTAssertEqual(parsed.detectedModel, model)
                for (target, _) in supported {
                    var transfer = F.Transfer()
                    if target == model {
                        XCTAssertEqual(try transfer.begin(parsed, targetModel: target, at: 0, policy: .syntheticTestOnly).first?.command, .open)
                    } else {
                        expectFailure(.modelMismatch(expected: target, actual: model)) {
                            try transfer.begin(parsed, targetModel: target, at: 0, policy: .syntheticTestOnly)
                        }
                        XCTAssertEqual(transfer.state, .ready)
                    }
                }
            }
        }
        for unknown in ["Buds3Pro", "Galaxy Buds4", "R630XX", "R6300", "SM-R630-extra", "", "R510"] {
            XCTAssertNil(F.Model(identifier: unknown))
        }
        for marker in ["", "no model", "SM-R510", "SM-R6300", "prefixR630", "SM-R630\0SM-R640", "R630 R540",
                       "SM-R630 SM-R510", "SM-R630 R999"] {
            let parsed = try syntheticBinary(marker)
            XCTAssertNil(parsed.detectedModel, marker)
            var transfer = F.Transfer()
            expectFailure(.unknownBinaryModel) { try transfer.begin(parsed, targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly) }
        }
        let mixed = try F.parse(syntheticContainer([(1, image("SM-R630")), (2, image("R540"))]), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        XCTAssertNil(mixed.detectedModel)
        var transfer = F.Transfer()
        expectFailure(.unknownTargetModel) { try transfer.begin(syntheticBinary(), targetModel: nil, at: 0, policy: .syntheticTestOnly) }
        // A marker in a container gap is not embedded model evidence.
        var gap = syntheticContainer([(1, Data(repeating: 0xA5, count: 20))], gap: 8)
        gap.replaceSubrange(28..<35, with: Data("SM-R630".utf8)); sealSyntheticWholeContainer(&gap)
        XCTAssertNil(try F.parse(gap, checksum: .syntheticWholeContainerCRC32ISOHDLC).detectedModel)
    }

    func testCodecCommandsSignedMTUClampNAKAndAllDecoderFields() throws {
        XCTAssertEqual(F.Command.allCases.map(\.rawValue), [0xB9, 0xBB, 0xBC, 0xBD, 0xBE])
        XCTAssertEqual(F.SessionResultCode.allCases.map(\.rawValue), Array(UInt8(0)...7))
        XCTAssertEqual(F.ControlID.unknown.rawValue, 2); XCTAssertEqual(F.UpdateID.unknown.rawValue, 2)
        XCTAssertEqual(try F.decode(command: 0xBB, payload: Data([7])), .session(7))
        XCTAssertEqual(try F.decode(command: 0xBC, payload: Data([0, 0xFF, 0x7F])), .mtu(650))
        XCTAssertEqual(try F.decode(command: 0xBC, payload: Data([0, 1, 0])), .mtu(1))
        XCTAssertEqual(try F.decode(command: 0xBC, payload: Data([1, 0xFF, 0])), .ready(segmentID: 255))
        XCTAssertEqual(try F.decode(command: 0xBD, payload: Data([0x78, 0x56, 0x34, 0x92, 255])),
                       .download(offset: 0x12345678, count: 255, nak: true))
        XCTAssertEqual(try F.decode(command: 0xBD, payload: Data([0, 0, 0, 0, 1])), .download(offset: 0, count: 1, nak: false))
        XCTAssertEqual(try F.decode(command: 0xBE, payload: Data([0, 100, 7])), .percent(100, resultCode: 7))
        XCTAssertEqual(try F.decode(command: 0xBE, payload: Data([1, 0, 9])), .stateChange(state: 0, resultCode: 9))
        XCTAssertEqual(try F.decode(command: 0xB9, payload: Data([1, 12])), .result(1, errorCode: 12))
    }

    func testMalformedUnknownAndInvalidCodecValuesNeverIndexOrAllocateUnchecked() {
        let lengths: [(UInt8, Int)] = [(0xBB, 1), (0xBC, 3), (0xBD, 5), (0xBE, 3), (0xB9, 2)]
        for (command, length) in lengths {
            for count in 0...(length + 2) where count != length {
                expectFailure(.malformedPacket(command)) {
                    try F.decode(command: command, payload: Data(repeating: 0, count: count))
                }
            }
            expectFailure(.malformedPacket(command)) {
                try F.decode(command: command, payload: Data(repeating: 0, count: length), isFragment: true)
            }
        }
        expectFailure(.unknownCommand(0xB0)) { try F.decode(command: 0xB0, payload: Data()) }
        expectFailure(.unknownControl(2)) { try F.decode(command: 0xBC, payload: Data([2, 0, 0])) }
        expectFailure(.unknownUpdate(2)) { try F.decode(command: 0xBE, payload: Data([2, 0, 0])) }
        let invalidFields: [([UInt8], F.Failure)] = [([0, 0, 0], .invalidMTU(0)),
                                                    ([0, 255, 255], .invalidMTU(-1)),
                                                    ([1, 255, 255], .invalidSegmentID(-1)),
                                                    ([1, 0, 1], .invalidSegmentID(256))]
        for (bytes, expected) in invalidFields {
            expectFailure(expected) { try F.decode(command: 0xBC, payload: Data(bytes)) }
        }
        expectFailure(.invalidPacketCount(0)) { try F.decode(command: 0xBD, payload: Data([0, 0, 0, 0, 0])) }
        expectFailure(.invalidProgress(101)) { try F.decode(command: 0xBE, payload: Data([0, 101, 0])) }
    }

    func testFragmentsExactOffsetsPayloadsFinalBitAndBounds() throws {
        let parsed = try syntheticBinary(size: 1500)
        let packets = try parsed.fragments(segmentID: 7, offset: 0, count: 3, mtu: 650)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets.map { $0.payload.count }, [654, 654, 204])
        XCTAssertEqual(packets.map { readLE($0.payload) }, [0x80000000, 0x8000028A, 1300])
        for packet in packets { XCTAssertEqual(packet.command, .downloadData); XCTAssertEqual(packet.type, .response); XCTAssertTrue(packet.isFragment) }
        XCTAssertEqual(packets.reduce(Data()) { $0 + $1.payload.dropFirst(4) }, parsed.segments[0].rawData)
        let oneByte = try parsed.fragments(segmentID: 7, offset: 1499, count: 1, mtu: 650)
        XCTAssertEqual(oneByte[0].payload, Data(le(1499)) + parsed.segments[0].rawData.suffix(1))
        let exact = try syntheticBinary(size: 1300).fragments(segmentID: 7, offset: 0, count: 2, mtu: 650)
        XCTAssertEqual(readLE(exact[1].payload), 650)
        for mtu in [Int.min, -1, 0, 651, Int.max] {
            expectFailure(.invalidMTU(mtu)) { try parsed.fragments(segmentID: 7, offset: 0, count: 1, mtu: mtu) }
        }
        for offset in [Int.min, -1, 1500, 1501, Int.max] {
            expectFailure(.invalidOffset(offset)) { try parsed.fragments(segmentID: 7, offset: offset, count: 1, mtu: 650) }
        }
        for count in [Int.min, -1, 0, 4, 256, Int.max] {
            expectFailure(.invalidPacketCount(count)) { try parsed.fragments(segmentID: 7, offset: 0, count: count, mtu: 650) }
        }
        expectFailure(.invalidPacketCount(2)) { try parsed.fragments(segmentID: 7, offset: 1300, count: 2, mtu: 650) }
        for id in [-1, 0, 256, Int.max] {
            expectFailure(.unknownSegment(id)) { try parsed.fragments(segmentID: id, offset: 0, count: 1, mtu: 650) }
        }
        XCTAssertEqual(try parsed.fragments(segmentID: 7, offset: 0, count: 255, mtu: 1).count, 255)
    }

    func testSyntheticProtocolTraceAndOutgoingSPPNewFlags() throws {
        let parsed = try syntheticBinary(size: 1500)
        var transfer = F.Transfer()
        let open = try XCTUnwrap(transfer.begin(parsed, targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly).first)
        XCTAssertEqual(open.command, .open); XCTAssertEqual(open.type, .request); XCTAssertFalse(open.isFragment)
        XCTAssertEqual(open.payload, try parsed.serializeTable())
        XCTAssertEqual(transfer.state, .initializingSession); XCTAssertEqual(transfer.deadline, 20)
        XCTAssertTrue(try send(&transfer, 0xBB, [0]).isEmpty)
        let mtu = try XCTUnwrap(send(&transfer, 0xBC, [0, 0xE8, 3]).first) // Device asks for 1000; ACK 650.
        XCTAssertEqual(mtu, .init(command: .control, type: .response, payload: Data([0, 0x8A, 2])))
        XCTAssertEqual(transfer.mtu, 650)
        let ready = try send(&transfer, 0xBC, [1, 7, 0])
        XCTAssertEqual(ready, [.init(command: .control, type: .response, payload: Data([1, 7, 0]))])
        let fragments = try send(&transfer, 0xBD, [0, 0, 0, 0, 3])
        XCTAssertEqual(fragments, try parsed.fragments(segmentID: 7, offset: 0, count: 3, mtu: 650))
        XCTAssertEqual(transfer.lastRequest, .init(segmentID: 7, offset: 0, count: 3, nak: false))
        let retransmission = try send(&transfer, 0xBD, [0x8A, 2, 0, 0x80, 1])
        XCTAssertEqual(retransmission, [fragments[1]])
        XCTAssertEqual(transfer.lastRequest?.nak, true)
        XCTAssertNil(transfer.deviceReportedCompletion, "Even sending a final fragment is not completion")
        XCTAssertTrue(try send(&transfer, 0xBE, [0, 100, 0]).isEmpty)
        XCTAssertEqual(transfer.state, .awaitingDeviceCompletion)
        XCTAssertEqual(transfer.transferPercent, 100); XCTAssertEqual(transfer.reportedBytes, parsed.totalSize)
        XCTAssertNil(transfer.deviceReportedCompletion)
        XCTAssertEqual(try send(&transfer, 0xBE, [1, 0, 9]), [.init(command: .update, type: .response, payload: Data([1]))])
        XCTAssertEqual(transfer.deviceReportedCompletion, .stateChange(resultCode: 9))
        XCTAssertFalse(transfer.isActive); XCTAssertNil(transfer.deadline)
        XCTAssertTrue(try send(&transfer, 0xB9, [1, 255], at: 1000).isEmpty)
        XCTAssertEqual(transfer.deviceReportedCompletion, .stateChange(resultCode: 9))
        // Encode follows outgoing C# semantics even though C# Decode reverses Type.
        let openBytes = try open.encodedSPPNew(), mtuBytes = try mtu.encodedSPPNew()
        XCTAssertEqual(openBytes.first, 0xFD); XCTAssertEqual(openBytes.last, 0xDD)
        XCTAssertEqual(openBytes[2] & 0x30, 0)
        // Fixed golden CRC16 for BC 00 8A 02, independently generated with
        // Python binascii.crc_hqx(body, 0), matching upstream Crc16.cs.
        XCTAssertEqual(mtuBytes, Data([0xFD, 6, 0x10, 0xBC, 0, 0x8A, 2, 0xF2, 0x6A, 0xDD]))
        XCTAssertEqual(try fragments[0].encodedSPPNew().prefix(4), Data([0xFD, 0x91, 0x32, 0xBD]))
        XCTAssertEqual(try fragments[2].encodedSPPNew().prefix(4), Data([0xFD, 0xCF, 0x30, 0xBD]))
        XCTAssertEqual(mtuBytes.count, 10)
        expectFailure(.malformedPacket(0xBB)) {
            try F.Packet(command: .open, type: .request, payload: Data(repeating: 0, count: 1021)).encodedSPPNew()
        }
    }

    func testRemoteResultAndErrorACKsUseSourceSuccessPredicates() throws {
        var success = try uploading()
        let ack = try send(&success, 0xB9, [0, 77])
        XCTAssertEqual(ack, [.init(command: .result, type: .response, payload: Data([1]))])
        XCTAssertEqual(success.deviceReportedCompletion, .result(errorCode: 77))
        XCTAssertEqual(success.transferPercent, 0, "A device result is independent of percent notifications")
        var copyFailure = try uploading()
        XCTAssertEqual(try send(&copyFailure, 0xBE, [1, 3, 18]), [.init(command: .update, type: .response, payload: Data([1]))])
        XCTAssertEqual(copyFailure.state, .failed(.copyFailed(18))); XCTAssertNil(copyFailure.deviceReportedCompletion)
        var verifyFailure = try uploading()
        XCTAssertEqual(try send(&verifyFailure, 0xB9, [2, 19]), [.init(command: .result, type: .response, payload: Data([1]))])
        XCTAssertEqual(verifyFailure.state, .failed(.verificationFailed(19)))
        for code in UInt8(1)...7 {
            var session = F.Transfer()
            _ = try session.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
            XCTAssertTrue(try send(&session, 0xBB, [code]).isEmpty)
            XCTAssertEqual(session.state, .failed(.sessionFailed(code)), "Opened (3) is not manager success")
        }
    }

    func testOutOfOrderMalformedAndOutOfRangeInputFailsAtomically() throws {
        var idle = F.Transfer()
        XCTAssertTrue(try send(&idle, 0xB9, [0, 0]).isEmpty)
        XCTAssertEqual(idle.state, .ready)
        let outOfOrder: [(UInt8, [UInt8])] = [(0xBC, [0, 1, 0]), (0xBD, [0, 0, 0, 0, 1]),
                                             (0xBE, [0, 100, 0]), (0xB9, [0, 0])]
        for (command, payload) in outOfOrder {
            var transfer = F.Transfer()
            _ = try transfer.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
            expectFailure(.unexpectedMessage) { try send(&transfer, command, payload) }
            XCTAssertEqual(transfer.state, .failed(.unexpectedMessage)); XCTAssertNil(transfer.deviceReportedCompletion)
        }
        var selected = try uploading()
        expectFailure(.unknownSegment(8)) { try send(&selected, 0xBC, [1, 8, 0]) }
        XCTAssertEqual(selected.state, .failed(.unknownSegment(8)))
        var batch = try uploading()
        expectFailure(.invalidPacketCount(4)) { try send(&batch, 0xBD, [0, 0, 0, 0, 4]) }
        XCTAssertNil(batch.lastRequest, "No partial response batch was accepted")
        XCTAssertEqual(batch.state, .failed(.invalidPacketCount(4)))
        var eof = try uploading()
        expectFailure(.invalidOffset(1500)) { try send(&eof, 0xBD, le(1500) + [1]) }
        var huge = try uploading()
        expectFailure(.invalidOffset(0x7FFFFFFF)) { try send(&huge, 0xBD, [255, 255, 255, 255, 1]) }
        var malformed = try uploading()
        expectFailure(.malformedPacket(0xBE)) { try send(&malformed, 0xBE, [0, 100]) }
        XCTAssertEqual(malformed.state, .failed(.malformedPacket(0xBE)))
    }

    func testSegmentSelectionAndNAKRetransmissionNeverInventSequentialOffsets() throws {
        let parsed = try F.parse(syntheticContainer([(7, image(size: 32)), (9, Data([1, 2, 3, 4]))]), checksum: .syntheticWholeContainerCRC32ISOHDLC)
        var transfer = F.Transfer()
        _ = try transfer.begin(parsed, targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        _ = try send(&transfer, 0xBB, [0]); _ = try send(&transfer, 0xBC, [0, 10, 0])
        _ = try send(&transfer, 0xBC, [1, 9, 0])
        let second = try send(&transfer, 0xBD, [1, 0, 0, 0, 1])
        XCTAssertEqual(second.first?.payload, Data([1, 0, 0, 0, 2, 3, 4]))
        _ = try send(&transfer, 0xBC, [1, 7, 0])
        XCTAssertEqual(transfer.currentSegmentID, 7)
        let retry = try send(&transfer, 0xBD, [20, 0, 0, 0x80, 1])
        XCTAssertEqual(retry, try parsed.fragments(segmentID: 7, offset: 20, count: 1, mtu: 10))
        XCTAssertTrue(transfer.lastRequest?.nak == true)
    }

    func testDeterministicSessionControlCopyCompletionAndOverallTimeouts() throws {
        var session = F.Transfer()
        _ = try session.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        try session.advanceTime(to: 19.999)
        expectFailure(.timeout(.session)) { try session.advanceTime(to: 20) }
        XCTAssertEqual(session.state, .failed(.timeout(.session)))
        var control = F.Transfer()
        _ = try control.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        _ = try send(&control, 0xBB, [0], at: 5)
        expectFailure(.timeout(.control)) { try control.advanceTime(to: 25) }
        var segmentWait = F.Transfer()
        _ = try segmentWait.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        _ = try send(&segmentWait, 0xBB, [0], at: 1)
        _ = try send(&segmentWait, 0xBC, [0, 1, 0], at: 2)
        expectFailure(.timeout(.control)) { try segmentWait.advanceTime(to: 22) }
        var copy = try uploading()
        expectFailure(.timeout(.copy)) { try copy.advanceTime(to: 21) }
        var complete = try uploading()
        _ = try send(&complete, 0xBE, [0, 100, 0], at: 2)
        expectFailure(.timeout(.completion)) { try complete.advanceTime(to: 22) }
        XCTAssertNil(complete.deviceReportedCompletion)
        var timeouts = F.Timeouts(); timeouts.overall = 5
        var overall = F.Transfer(timeouts: timeouts)
        _ = try overall.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly)
        _ = try send(&overall, 0xBB, [0], at: 1)
        _ = try send(&overall, 0xBC, [0, 1, 0], at: 2)
        _ = try send(&overall, 0xBC, [1, 7, 0], at: 3)
        _ = try send(&overall, 0xBD, [0, 0, 0, 0, 1], at: 4)
        expectFailure(.timeout(.overall)) { try send(&overall, 0xB9, [0, 0], at: 5) }
        XCTAssertNil(overall.deviceReportedCompletion)
    }

    func testCancellationDisconnectTransportErrorsAndClockValidationAreLocalOnly() throws {
        var cancelled = try uploading(); cancelled.cancel()
        XCTAssertEqual(cancelled.state, .cancelled); XCTAssertNil(cancelled.deadline)
        XCTAssertTrue(try send(&cancelled, 0xB9, [0, 0], at: 500).isEmpty)
        var disconnected = try uploading(); disconnected.disconnected()
        XCTAssertEqual(disconnected.state, .failed(.disconnected))
        var failed = try uploading(); failed.transportFailed()
        XCTAssertEqual(failed.state, .failed(.transportFailure))
        var repeated = try uploading()
        expectFailure(.inProgress) { try repeated.begin(syntheticBinary(), targetModel: .buds3Pro, at: 1, policy: .syntheticTestOnly) }
        XCTAssertEqual(repeated.state, .uploading)
        var reversed = try uploading()
        expectFailure(.invalidTime) { try reversed.advanceTime(to: 0.9) }
        XCTAssertEqual(reversed.state, .failed(.invalidTime))
        for clock in [TimeInterval.nan, .infinity, -.infinity, -1, TimeInterval.greatestFiniteMagnitude] {
            var transfer = F.Transfer()
            expectFailure(.invalidTime) { try transfer.begin(syntheticBinary(), targetModel: .buds3Pro, at: clock, policy: .syntheticTestOnly) }
        }
        for invalid in [TimeInterval.nan, .infinity, 0, -1, 86401] {
            var timeouts = F.Timeouts(); timeouts.copy = invalid
            var transfer = F.Transfer(timeouts: timeouts)
            expectFailure(.invalidTimeouts) { try transfer.begin(syntheticBinary(), targetModel: .buds3Pro, at: 0, policy: .syntheticTestOnly) }
        }
        var invalidIncomingClock = try uploading()
        expectFailure(.invalidTime) { try send(&invalidIncomingClock, 0xB9, [0, 0], at: .nan) }
        XCTAssertNil(invalidIncomingClock.deviceReportedCompletion)
    }
}
