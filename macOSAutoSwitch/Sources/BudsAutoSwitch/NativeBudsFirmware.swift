// SPDX-License-Identifier: GPL-3.0-only
// Swift adaptation of GalaxyBudsClient by Tim Schneeberger (timschneeb) and
// contributors: Model/Firmware/{FirmwareBinary,FirmwareSegment,FirmwareConstants}.cs,
// Message/FirmwareTransferManager.cs, Message/{Encoder,Decoder}/Fota*.cs,
// Message/SppMessage{,Enums}.cs and Utils/Crc16.cs. See the repository's LICENSE.
// Upstream: https://github.com/timschneeb/GalaxyBudsClient
// This adaptation adds bounds, explicit integrity policy and deterministic clocks.
// Distributed under GPLv3, WITHOUT ANY WARRANTY; see LICENSE for the full terms.

import Foundation

/// Pure container/codec/transfer planning. Nothing here opens a connection, writes
/// a device, schedules a timer, or grants transport ownership. Returned packets
/// are descriptions only. A future host must independently verify model evidence,
/// authenticate its image, validate incoming envelopes, and acquire an exclusive
/// transport lease. The reference below proves one container checksum profile only.
enum NativeBudsFirmware {
    static let magic: UInt32 = 0xCAFECAFE
    static let combinationMagic: UInt32 = 0x42434F4D
    static let maximumMTU = 650
    static let maximumContainerBytes = 64 * 1024 * 1024
    static let maximumSegments = 255 // SerializeTable writes a byte count/id.
    static let maximumPayloadBytes = 1020 // SppNew: ten-bit size, minus id + CRC16.
    static let maximumAnalysisBytes = 128 * 1024 * 1024
    static let maximumNestedDepth = 4

    enum Model: String, CaseIterable, Equatable {
        case buds3Pro = "Buds3Pro", buds4 = "Buds4", buds4Pro = "Buds4Pro"

        var identifier: String {
            switch self {
            case .buds3Pro: return "R630"
            case .buds4: return "R540"
            case .buds4Pro: return "R640"
            }
        }

        /// Exact SKU only; a friendly name, substring or cached UI model is not evidence.
        init?(identifier: String) {
            let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let model = Self.allCases.first(where: {
                value == $0.identifier || value == "SM-" + $0.identifier
            }) else { return nil }
            self = model
        }
    }

    /// CRC32 uses ISO-HDLC (reflected EDB88320, init/xorout FFFFFFFF).
    /// Host evidence: /tmp/buds-firmware-crc-reference.json, downloaded with system
    /// curl TLS verification to /tmp/buds3pro-firmware-reference.bin from
    /// https://fw.timschneeberger.me/v3/firmware/download/R630XXU0AZG2
    /// SHA256: 2e1bd0151459c21daf2d669c6ff6b548821140a6247817fce9534a12299622ce
    /// That single 8,683,104-byte image has magic CAFECAFE, TotalSize == file size,
    /// one segment (id 6, position 28, length 8,683,072), and segment CRC 0985CC89
    /// matching ISO-HDLC(segment data) AND the final four-byte trailer. CRC32 of
    /// the file excluding that trailer is instead 5F4DA4C4. No multi-segment CRC
    /// coverage, other model/release support, authenticity or device install is
    /// established. "Verified" names this observed structural/checksum profile;
    /// it does not pin every parsed image to the reference digest or byte length.
    enum ChecksumPolicy: Equatable {
        case inspectWithoutValidation
        case verifiedBuds3ProSingleSegment
        /// Fixture convention only: segment CRCs plus CRC32(file minus trailer).
        /// This coverage is synthetic, not vendor verified, and cannot satisfy
        /// the default transfer policy. No alternative checksum profile is tried.
        case syntheticWholeContainerCRC32ISOHDLC
    }

    enum TransferPolicy: Equatable {
        case verifiedBuds3ProSingleSegment
        /// Pure protocol simulation only; never verified installation evidence.
        case syntheticTestOnly
    }

    enum TimeoutPhase: Equatable { case session, control, copy, completion, overall }

    enum Failure: Error, Equatable {
        case truncatedContainer, unsupportedDebugContainer, invalidMagic(UInt32)
        case invalidContainerSize(Int), invalidDeclaredSize(Int), invalidSegmentCount(Int)
        case invalidSegmentID(Int), duplicateSegmentID(Int)
        case invalidSegmentRange(id: Int, position: Int, size: Int), overlappingSegments
        case checksumMismatch(segmentID: Int?, expected: UInt32, actual: UInt32)
        case analysisLimit, tableTooLarge
        case unknownBinaryModel, unknownTargetModel, modelMismatch(expected: Model, actual: Model)
        case checksumNotVerified, unsupportedBuds3ProSingleSegmentProfile, inProgress
        case invalidMTU(Int), unknownSegment(Int), invalidOffset(Int), invalidPacketCount(Int)
        case unknownCommand(UInt8), malformedPacket(UInt8), unknownControl(UInt8), unknownUpdate(UInt8)
        case invalidProgress(Int), unexpectedMessage, invalidTime, invalidTimeouts
        case sessionFailed(UInt8), copyFailed(UInt8), verificationFailed(UInt8)
        case timeout(TimeoutPhase), disconnected, transportFailure
    }

    struct Segment: Equatable {
        let id: Int
        let crc32: UInt32
        let position: Int
        let size: Int
        let rawData: Data
        let nestedBinary: Binary?

        fileprivate init(id: Int, crc32: UInt32, position: Int, size: Int,
                         rawData: Data, nestedBinary: Binary?) {
            self.id = id; self.crc32 = crc32; self.position = position
            self.size = size; self.rawData = rawData; self.nestedBinary = nestedBinary
        }
    }

    struct Binary: Equatable {
        let buildName: String
        let totalSize: Int
        let crc32: UInt32
        let segments: [Segment]
        let checksumPolicy: ChecksumPolicy
        let modelIdentifiers: [String]
        var detectedModel: Model? {
            guard modelIdentifiers.count == 1 else { return nil }
            return Model(identifier: modelIdentifiers[0])
        }

        fileprivate init(buildName: String, totalSize: Int, crc32: UInt32, segments: [Segment],
                         checksumPolicy: ChecksumPolicy, modelIdentifiers: [String]) {
            self.buildName = buildName; self.totalSize = totalSize; self.crc32 = crc32
            self.segments = segments; self.checksumPolicy = checksumPolicy
            self.modelIdentifiers = modelIdentifiers
        }

        func segment(id: Int) -> Segment? { segments.first { $0.id == id } }

        /// Wire table: container CRC32 LE, count u8, then (id u8, size i32 LE,
        /// segment CRC32 LE). Position and container magic are NOT transmitted.
        func serializeTable() throws -> Data {
            guard 5 + 9 * segments.count <= NativeBudsFirmware.maximumPayloadBytes else { throw Failure.tableTooLarge }
            var result = NativeBudsFirmware.littleEndian(crc32) + [UInt8(segments.count)]
            for segment in segments {
                result += [UInt8(segment.id)] + NativeBudsFirmware.littleEndian(UInt32(segment.size))
                    + NativeBudsFirmware.littleEndian(segment.crc32)
            }
            return Data(result)
        }

        func validateTarget(_ model: Model?, policy: TransferPolicy = .verifiedBuds3ProSingleSegment) throws {
            guard let model else { throw Failure.unknownTargetModel }
            guard let detectedModel else { throw Failure.unknownBinaryModel }
            guard model == detectedModel else { throw Failure.modelMismatch(expected: model, actual: detectedModel) }
            switch policy {
            case .verifiedBuds3ProSingleSegment:
                guard checksumPolicy == .verifiedBuds3ProSingleSegment else { throw Failure.checksumNotVerified }
                guard detectedModel == .buds3Pro else { throw Failure.unsupportedBuds3ProSingleSegmentProfile }
            case .syntheticTestOnly:
                guard checksumPolicy == .syntheticWholeContainerCRC32ISOHDLC else { throw Failure.checksumNotVerified }
            }
        }

        /// Validate the entire batch before constructing any response. Repeated
        /// offsets/NAKs may retransmit, but no request may start at/past EOF or
        /// ask for a further packet after the final (possibly short) fragment.
        func fragments(segmentID: Int, offset: Int, count: Int, mtu: Int) throws -> [Packet] {
            guard (1...NativeBudsFirmware.maximumMTU).contains(mtu) else { throw Failure.invalidMTU(mtu) }
            guard let segment = segment(id: segmentID) else { throw Failure.unknownSegment(segmentID) }
            guard offset >= 0, offset < segment.size else { throw Failure.invalidOffset(offset) }
            guard (1...255).contains(count), count <= 1 + (segment.size - offset - 1) / mtu else {
                throw Failure.invalidPacketCount(count)
            }
            return (0..<count).map { index in
                let start = offset + mtu * index
                let end = min(start + mtu, segment.size)
                let isLast = end == segment.size
                // High bit SET means more follows; final fragment CLEARS it.
                let header = UInt32(start) | (isLast ? 0 : 0x80000000)
                return Packet(command: .downloadData, type: .response,
                              payload: Data(NativeBudsFirmware.littleEndian(header)) + segment.rawData.subdata(in: start..<end),
                              isFragment: true)
            }
        }
    }

    /// Exact shipped little-endian layout: magic u32, TotalSize i32, count i32,
    /// count * (id i32, CRC32 bits, absolute position i32, size i32), data, CRC32.
    /// Generic inspection/synthetic parsing preserves bounded TotalSize metadata,
    /// gaps and table order; overlapping segments are rejected. The verified
    /// Buds3Pro profile additionally requires TotalSize == physical file length,
    /// exactly id 6 at byte 28, and its data filling all bytes before the trailer.
    static func parse(_ data: Data, buildName: String = "", checksum: ChecksumPolicy,
                      fullAnalysis: Bool = false) throws -> Binary {
        var budget = maximumAnalysisBytes
        return try parse(data, buildName: buildName, checksum: checksum,
                         fullAnalysis: fullAnalysis, depth: 0, budget: &budget)
    }

    private static func parse(_ data: Data, buildName: String, checksum: ChecksumPolicy,
                              fullAnalysis: Bool, depth: Int, budget: inout Int) throws -> Binary {
        guard data.count <= maximumContainerBytes else { throw Failure.invalidContainerSize(data.count) }
        guard data.count >= 4 else { throw Failure.truncatedContainer }
        guard depth <= maximumNestedDepth, data.count <= budget else { throw Failure.analysisLimit }
        budget -= data.count
        let bytes = [UInt8](data) // Normalize Data slices; never assume their startIndex is zero.
        let fileMagic = u32(bytes, 0)
        if fileMagic == combinationMagic || bytes.starts(with: Array(":02000004FE00FC".utf8)) {
            throw Failure.unsupportedDebugContainer
        }
        guard fileMagic == magic else { throw Failure.invalidMagic(fileMagic) }
        guard bytes.count >= 16 else { throw Failure.truncatedContainer }
        let totalSize = signed32(bytes, 4)
        guard (1...maximumContainerBytes).contains(totalSize) else { throw Failure.invalidDeclaredSize(totalSize) }
        let count = signed32(bytes, 8)
        guard (1...maximumSegments).contains(count) else { throw Failure.invalidSegmentCount(count) }
        let tableEnd = 12 + count * 16
        let dataEnd = bytes.count - 4
        guard tableEnd <= dataEnd else { throw Failure.truncatedContainer }
        var entries: [(id: Int, crc: UInt32, position: Int, size: Int)] = []
        var ids = Set<Int>()
        for index in 0..<count {
            let base = 12 + index * 16
            let id = signed32(bytes, base)
            let position = signed32(bytes, base + 8), size = signed32(bytes, base + 12)
            guard (0...255).contains(id) else { throw Failure.invalidSegmentID(id) }
            guard ids.insert(id).inserted else { throw Failure.duplicateSegmentID(id) }
            guard position >= tableEnd, position <= dataEnd, size > 0, size <= dataEnd - position else {
                throw Failure.invalidSegmentRange(id: id, position: position, size: size)
            }
            entries.append((id, u32(bytes, base + 4), position, size))
        }
        let ordered = entries.sorted { $0.position < $1.position }
        for index in 1..<ordered.count {
            guard ordered[index - 1].position + ordered[index - 1].size <= ordered[index].position else {
                throw Failure.overlappingSegments
            }
        }
        let containerCRC = u32(bytes, dataEnd)
        if checksum == .verifiedBuds3ProSingleSegment {
            guard totalSize == bytes.count, entries.count == 1,
                  let entry = entries.first, entry.id == 6, entry.position == 28,
                  entry.size == dataEnd - 28 else {
                throw Failure.unsupportedBuds3ProSingleSegmentProfile
            }
            guard containerCRC == entry.crc else {
                throw Failure.checksumMismatch(segmentID: nil, expected: entry.crc, actual: containerCRC)
            }
        } else if checksum == .syntheticWholeContainerCRC32ISOHDLC {
            let actual = crc32ISOHDLC(bytes[..<dataEnd])
            guard actual == containerCRC else {
                throw Failure.checksumMismatch(segmentID: nil, expected: containerCRC, actual: actual)
            }
        }
        var segments: [Segment] = []
        var markers = Set<String>()
        for entry in entries {
            let raw = Data(bytes[entry.position..<(entry.position + entry.size)])
            if checksum != .inspectWithoutValidation {
                let actual = crc32ISOHDLC(raw)
                guard actual == entry.crc else {
                    throw Failure.checksumMismatch(segmentID: entry.id, expected: entry.crc, actual: actual)
                }
            }
            markers.formUnion(modelMarkers(in: raw))
            var nested: Binary?
            if fullAnalysis, raw.count >= 4, u32([UInt8](raw.prefix(4)), 0) == magic {
                // The reference establishes only the outer single-segment CRC.
                // Nested coverage is unknown; retain generic inspection there.
                let nestedChecksum: ChecksumPolicy = checksum == .verifiedBuds3ProSingleSegment
                    ? .inspectWithoutValidation : checksum
                nested = try parse(raw, buildName: "0x" + String(entry.position, radix: 16) + " (nested)",
                                   checksum: nestedChecksum, fullAnalysis: true, depth: depth + 1, budget: &budget)
            }
            segments.append(Segment(id: entry.id, crc32: entry.crc, position: entry.position,
                                    size: entry.size, rawData: raw, nestedBinary: nested))
        }
        return Binary(buildName: buildName, totalSize: totalSize, crc32: containerCRC, segments: segments,
                      checksumPolicy: checksum, modelIdentifiers: markers.sorted())
    }

    /// Markers inside segment data only. Scan all Rddd candidates, including
    /// unsupported models, so a first/last matching supported SKU cannot win a
    /// mixed-model image. SM-R630 and R630 build prefixes identify the same SKU.
    /// CRCs and model strings are consistency checks, not cryptographic authenticity.
    static func detectModel(in data: Data) -> Model? {
        let markers = modelMarkers(in: data)
        guard markers.count == 1, let identifier = markers.first else { return nil }
        return Model(identifier: identifier)
    }

    private static func modelMarkers(in data: Data) -> Set<String> {
        guard data.count >= 4, data.count <= maximumContainerBytes else { return [] }
        let bytes = [UInt8](data)
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        func alphanumeric(_ byte: UInt8) -> Bool {
            digit(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        var result = Set<String>()
        for index in 0...(bytes.count - 4) where bytes[index] == 82 {
            guard index == 0 || !alphanumeric(bytes[index - 1]),
                  digit(bytes[index + 1]), digit(bytes[index + 2]), digit(bytes[index + 3]) else { continue }
            if index + 4 < bytes.count, digit(bytes[index + 4]) {
                result.insert("unsupported-model-number")
            } else {
                result.insert(String(decoding: bytes[index..<(index + 4)], as: UTF8.self))
            }
        }
        return result
    }

    enum Command: UInt8, CaseIterable {
        case result = 0xB9, open = 0xBB, control = 0xBC, downloadData = 0xBD, update = 0xBE
    }
    enum MessageType: UInt8 { case request = 0, response = 1 }
    enum SessionResultCode: UInt8, CaseIterable {
        case closed = 0, opening = 1, openedAndPending = 2, opened = 3
        case openedAndDownloadComplete = 4, closing = 5, aborting = 6, abortingAndWaitingWriteEvent = 7
    }
    enum ControlID: UInt8 { case sendMTU = 0, readyToDownload = 1, unknown = 2 }
    enum UpdateID: UInt8 { case percent = 0, stateChange = 1, unknown = 2 }

    struct Packet: Equatable {
        let command: Command
        let type: MessageType
        let payload: Data
        let isFragment: Bool

        init(command: Command, type: MessageType, payload: Data, isFragment: Bool = false) {
            self.command = command; self.type = type; self.payload = payload; self.isFragment = isFragment
        }

        /// Outgoing normal SppNew only, following SppMessage.Encode exactly:
        /// FD, size LE (response 0x1000 / fragment 0x2000), id, payload, CRC16 LE, DD.
        /// No inbound type inference: upstream SppMessage.Decode reverses its
        /// type interpretation relative to Encode; Fota decoders ignore Type.
        /// Incoming bodies must be supplied by a separately validated envelope.
        func encodedSPPNew() throws -> Data {
            guard payload.count <= NativeBudsFirmware.maximumPayloadBytes else { throw Failure.malformedPacket(command.rawValue) }
            let size = UInt16(payload.count + 3)
            let header = size | (type == .response ? 0x1000 : 0) | (isFragment ? 0x2000 : 0)
            let body = [command.rawValue] + [UInt8](payload)
            let crc = NativeBudsFirmware.crc16(body)
            return Data([0xFD, UInt8(truncatingIfNeeded: header), UInt8(header >> 8)] + body
                        + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8), 0xDD])
        }
    }

    enum Incoming: Equatable {
        case session(UInt8), mtu(Int), ready(segmentID: Int)
        case download(offset: Int, count: Int, nak: Bool)
        case percent(Int, resultCode: UInt8), stateChange(state: UInt8, resultCode: UInt8)
        case result(UInt8, errorCode: UInt8)
    }

    /// Exact lengths are intentionally stricter than the original unchecked
    /// index reads. Unknown subcommands, fragment envelopes and invalid signed
    /// fields fail closed. NAK is decoded, but (as upstream) does not change the
    /// requested offset/count or invent a separate acknowledgement command.
    static func decode(command: UInt8, payload: Data, isFragment: Bool = false) throws -> Incoming {
        guard let commandID = Command(rawValue: command) else { throw Failure.unknownCommand(command) }
        guard !isFragment, payload.count <= maximumPayloadBytes else { throw Failure.malformedPacket(command) }
        let p = [UInt8](payload)
        switch commandID {
        case .open:
            guard p.count == 1 else { throw Failure.malformedPacket(command) }
            return .session(p[0])
        case .control:
            guard p.count == 3 else { throw Failure.malformedPacket(command) }
            let value = Int(Int16(bitPattern: UInt16(p[1]) | UInt16(p[2]) << 8))
            switch p[0] {
            case ControlID.sendMTU.rawValue:
                guard value > 0 else { throw Failure.invalidMTU(value) }
                return .mtu(min(value, maximumMTU))
            case ControlID.readyToDownload.rawValue:
                guard (0...255).contains(value) else { throw Failure.invalidSegmentID(value) }
                return .ready(segmentID: value)
            default: throw Failure.unknownControl(p[0])
            }
        case .downloadData:
            guard p.count == 5 else { throw Failure.malformedPacket(command) }
            guard p[4] > 0 else { throw Failure.invalidPacketCount(0) }
            return .download(offset: Int(u32(p, 0) & 0x7FFFFFFF), count: Int(p[4]), nak: p[3] & 0x80 != 0)
        case .update:
            guard p.count == 3 else { throw Failure.malformedPacket(command) }
            switch p[0] {
            case UpdateID.percent.rawValue:
                guard p[1] <= 100 else { throw Failure.invalidProgress(Int(p[1])) }
                return .percent(Int(p[1]), resultCode: p[2])
            case UpdateID.stateChange.rawValue: return .stateChange(state: p[1], resultCode: p[2])
            default: throw Failure.unknownUpdate(p[0])
            }
        case .result:
            guard p.count == 2 else { throw Failure.malformedPacket(command) }
            return .result(p[0], errorCode: p[1])
        }
    }

    struct Timeouts: Equatable {
        var session: TimeInterval = 20
        var control: TimeInterval = 20
        // CopyTimeout is declared but never armed in the C# manager. These idle
        // and overall deadlines are additional local policy, not device protocol.
        var copy: TimeInterval = 20
        var completion: TimeInterval = 20
        var overall: TimeInterval = 30 * 60

        fileprivate var valid: Bool {
            [session, control, copy, completion, overall].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 86400 }
        }
    }

    enum Completion: Equatable {
        // Preserve the other byte even when the source treats it as non-fatal.
        case stateChange(resultCode: UInt8), result(errorCode: UInt8)
    }
    enum State: Equatable {
        case ready, initializingSession, awaitingMTU, awaitingSegment, uploading, awaitingDeviceCompletion
        case completed(Completion), failed(Failure), cancelled
    }
    struct DownloadRequest: Equatable {
        let segmentID: Int
        let offset: Int
        let count: Int
        let nak: Bool
    }

    /// A value-type reducer. Caller supplies monotonic seconds and validated
    /// incoming envelope bodies. Packet output means "would send", never "sent",
    /// received by the device, or installed. There are no callbacks or IO hooks.
    /// Unlike the permissive C# manager, OPEN must succeed before controls or a
    /// completion indication, and MTU/segment selection must precede downloads.
    /// Start a new value for a new session; terminal plans cannot be restarted.
    struct Transfer {
        private(set) var state: State = .ready
        private(set) var mtu: Int?
        private(set) var currentSegmentID: Int?
        private(set) var transferPercent = 0
        private(set) var reportedBytes = 0
        private(set) var lastRequest: DownloadRequest?
        private(set) var deadline: TimeInterval?
        let timeouts: Timeouts
        private var binary: Binary?
        private var phase: TimeoutPhase = .session
        private var lastTime: TimeInterval?
        private var overallDeadline: TimeInterval?

        init(timeouts: Timeouts = Timeouts()) { self.timeouts = timeouts }

        var isActive: Bool {
            switch state {
            case .initializingSession, .awaitingMTU, .awaitingSegment, .uploading, .awaitingDeviceCompletion: return true
            default: return false
            }
        }
        var deviceReportedCompletion: Completion? {
            if case .completed(let completion) = state { return completion }
            return nil
        }

        /// Default eligibility covers only the observed Buds3Pro container profile.
        /// Synthetic plans require an explicit opt-in and prove no installation.
        mutating func begin(_ binary: Binary, targetModel: Model?, at now: TimeInterval,
                            policy: TransferPolicy = .verifiedBuds3ProSingleSegment) throws -> [Packet] {
            guard state == .ready else { throw Failure.inProgress }
            guard timeouts.valid else { throw Failure.invalidTimeouts }
            let intervals = [timeouts.session, timeouts.control, timeouts.copy, timeouts.completion, timeouts.overall]
            guard now.isFinite, now >= 0,
                  intervals.allSatisfy({ (now + $0).isFinite && now + $0 > now }) else { throw Failure.invalidTime }
            try binary.validateTarget(targetModel, policy: policy)
            let table = try binary.serializeTable()
            self.binary = binary; state = .initializingSession
            lastTime = now; overallDeadline = now + timeouts.overall
            arm(.session, now: now)
            return [Packet(command: .open, type: .request, payload: table)]
        }

        /// Malformed/out-of-order input terminates the plan and throws before
        /// emitting data. Remote result failures return their required ACK and
        /// leave a typed .failed state, so an ACK is never lost by throwing.
        mutating func receive(command: UInt8, payload: Data, isFragment: Bool = false,
                              at now: TimeInterval) throws -> [Packet] {
            guard isActive else { return [] } // Idle/terminal unsolicited messages cannot complete a session.
            do {
                try advanceTime(to: now)
                let event = try NativeBudsFirmware.decode(command: command, payload: payload, isFragment: isFragment)
                guard let binary else { throw Failure.unexpectedMessage }
                switch event {
                case .session(let result):
                    guard state == .initializingSession else { throw Failure.unexpectedMessage }
                    // Manager treats zero as success, NOT SessionResultCode.opened (3).
                    if result != 0 { finish(.failed(.sessionFailed(result))); return [] }
                    state = .awaitingMTU; arm(.control, now: now)
                    return []
                case .mtu(let size):
                    guard state == .awaitingMTU else { throw Failure.unexpectedMessage }
                    mtu = size; state = .awaitingSegment; arm(.control, now: now)
                    return [controlResponse(.sendMTU, size)]
                case .ready(let segmentID):
                    guard mtu != nil, state == .awaitingSegment || state == .uploading || state == .awaitingDeviceCompletion else {
                        throw Failure.unexpectedMessage
                    }
                    guard binary.segment(id: segmentID) != nil else { throw Failure.unknownSegment(segmentID) }
                    currentSegmentID = segmentID
                    state = transferPercent == 100 ? .awaitingDeviceCompletion : .uploading
                    arm(transferPercent == 100 ? .completion : .copy, now: now)
                    return [controlResponse(.readyToDownload, segmentID)]
                case .download(let offset, let count, let nak):
                    guard let mtu, let currentSegmentID,
                          state == .uploading || state == .awaitingDeviceCompletion else { throw Failure.unexpectedMessage }
                    let packets = try binary.fragments(segmentID: currentSegmentID, offset: offset, count: count, mtu: mtu)
                    lastRequest = DownloadRequest(segmentID: currentSegmentID, offset: offset, count: count, nak: nak)
                    arm(transferPercent == 100 ? .completion : .copy, now: now)
                    return packets
                case .percent(let percent, _):
                    guard state == .uploading || state == .awaitingDeviceCompletion else { throw Failure.unexpectedMessage }
                    transferPercent = percent
                    reportedBytes = Int((Double(binary.totalSize) * Double(percent) / 100).rounded(.toNearestOrEven))
                    state = percent == 100 ? .awaitingDeviceCompletion : .uploading
                    arm(percent == 100 ? .completion : .copy, now: now)
                    return [] // Upstream does not ACK a Percent indication.
                case .stateChange(let remoteState, let resultCode):
                    guard state != .initializingSession else { throw Failure.unexpectedMessage }
                    let ack = Packet(command: .update, type: .response, payload: Data([1]))
                    if remoteState == 0 { finish(.completed(.stateChange(resultCode: resultCode))) }
                    else { finish(.failed(.copyFailed(resultCode))) }
                    return [ack]
                case .result(let result, let errorCode):
                    guard state != .initializingSession else { throw Failure.unexpectedMessage }
                    let ack = Packet(command: .result, type: .response, payload: Data([1]))
                    if result == 0 { finish(.completed(.result(errorCode: errorCode))) }
                    else { finish(.failed(.verificationFailed(errorCode))) }
                    return [ack]
                }
            } catch let error as Failure {
                finish(.failed(error))
                throw error
            }
        }

        mutating func advanceTime(to now: TimeInterval) throws {
            guard isActive else { return }
            guard now.isFinite, let lastTime, now >= lastTime else {
                finish(.failed(.invalidTime)); throw Failure.invalidTime
            }
            self.lastTime = now
            if let overallDeadline, now >= overallDeadline {
                finish(.failed(.timeout(.overall))); throw Failure.timeout(.overall)
            }
            if let deadline, now >= deadline {
                let expiredPhase = phase
                finish(.failed(.timeout(expiredPhase))); throw Failure.timeout(expiredPhase)
            }
        }

        mutating func cancel() { if isActive { finish(.cancelled) } }
        mutating func disconnected() { if isActive { finish(.failed(.disconnected)) } }
        mutating func transportFailed() { if isActive { finish(.failed(.transportFailure)) } }

        private mutating func arm(_ phase: TimeoutPhase, now: TimeInterval) {
            self.phase = phase
            let interval: TimeInterval
            switch phase {
            case .session: interval = timeouts.session
            case .control: interval = timeouts.control
            case .copy: interval = timeouts.copy
            case .completion: interval = timeouts.completion
            case .overall: interval = timeouts.overall
            }
            deadline = min(now + interval, overallDeadline ?? now + interval)
        }
        private mutating func finish(_ state: State) {
            self.state = state; binary = nil; deadline = nil; overallDeadline = nil
        }
        private func controlResponse(_ id: ControlID, _ parameter: Int) -> Packet {
            Packet(command: .control, type: .response,
                   payload: Data([id.rawValue, UInt8(truncatingIfNeeded: parameter), UInt8(parameter >> 8)]))
        }
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
    private static func signed32(_ bytes: [UInt8], _ index: Int) -> Int {
        Int(Int32(bitPattern: u32(bytes, index)))
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB88320) }
        return value
    }
    static func crc32ISOHDLC<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes { crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(byte)) & 255)] }
        return crc ^ 0xFFFFFFFF
    }
    private static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        return crc
    }
}
