import Foundation

/// Static MCFDS 4.6.12.16 reconstruction: android-trust/PROTOCOL.md §§2, 5,
/// anchors A08/A09/A12. These types neither establish trust nor open transport.
enum SamsungPeerWire {
    enum Failure: String, Error { case limit, truncated, varintOverflow, invalidTag, invalidWireType, invalidGroup, invalidUTF8, decoderFailed, invalidSwitch }

    struct Limits {
        let messageBytes: Int
        let fields: Int
        let groupDepth: Int
        init(messageBytes: Int = 1_048_576, fields: Int = 4096, groupDepth: Int = 16) throws {
            guard messageBytes > 0, messageBytes <= 16_777_216,
                  fields > 0, fields <= 65_536, groupDepth >= 0, groupDepth <= 64 else { throw Failure.limit }
            self.messageBytes = messageBytes; self.fields = fields; self.groupDepth = groupDepth
        }
        static let standard = try! Limits()
    }

    struct Packet: Equatable {
        var handlerID: Int32 = 0
        var sequence: Int32 = 0
        var payload = Data()
        var advertisement = Data()
        var revision: Int32?
        var authType: Int32?
        var iv: Data?
        /// Raw unknown fields survive a decode/encode, including groups and wrong-wire known tags.
        private(set) var unknownFields = Data()

        func encoded(limits: Limits = .standard) throws -> Data {
            var w = Writer(limits: limits)
            try w.int(1, handlerID); try w.int(2, sequence); try w.bytes(3, payload)
            try w.bytes(4, advertisement); try w.optionalInt(5, revision)
            try w.optionalInt(6, authType); try w.bytes(7, iv, present: iv != nil)
            try w.raw(unknownFields); return try w.finish()
        }
        static func decode(_ data: Data, limits: Limits = .standard) throws -> Self {
            var r = try Reader(data, limits: limits); var p = Self()
            while let f = try r.next() {
                switch (f.number, f.value) {
                case (1, .integer(let v)): p.handlerID = Int32(truncatingIfNeeded: v)
                case (2, .integer(let v)): p.sequence = Int32(truncatingIfNeeded: v)
                case (3, .bytes(let v)): p.payload = v
                case (4, .bytes(let v)): p.advertisement = v
                case (5, .integer(let v)): p.revision = Int32(truncatingIfNeeded: v)
                case (6, .integer(let v)): p.authType = Int32(truncatingIfNeeded: v)
                case (7, .bytes(let v)): p.iv = v
                default: p.unknownFields.append(f.raw)
                }
            }
            return p
        }
    }

    struct Authentication: Equatable {
        var command: Int32 = 0
        var result: Int32 = 0
        var address = Data()
        var nonce = Data()
        var hash = Data()
        var channels: [String] = []
        var supportTCPKeep = false
        var revision: Int32?
        var memberID: Int32?
        private(set) var unknownFields = Data()

        func encoded(limits: Limits = .standard) throws -> Data {
            var w = Writer(limits: limits)
            try w.int(1, command); try w.int(2, result); try w.bytes(3, address)
            try w.bytes(4, nonce); try w.bytes(5, hash)
            guard channels.count <= limits.fields else { throw Failure.limit }
            for channel in channels {
                guard channel.utf8.count <= limits.messageBytes else { throw Failure.limit }
                try w.bytes(6, Data(channel.utf8), present: true)
            }
            try w.int(7, supportTCPKeep ? 1 : 0); try w.optionalInt(8, revision)
            try w.optionalInt(9, memberID); try w.raw(unknownFields); return try w.finish()
        }
        static func decode(_ data: Data, limits: Limits = .standard) throws -> Self {
            var r = try Reader(data, limits: limits); var a = Self()
            while let f = try r.next() {
                switch (f.number, f.value) {
                case (1, .integer(let v)): a.command = Int32(truncatingIfNeeded: v)
                case (2, .integer(let v)): a.result = Int32(truncatingIfNeeded: v)
                case (3, .bytes(let v)): a.address = v
                case (4, .bytes(let v)): a.nonce = v
                case (5, .bytes(let v)): a.hash = v
                case (6, .bytes(let v)):
                    guard let s = String(data: v, encoding: .utf8) else { throw Failure.invalidUTF8 }
                    a.channels.append(s)
                case (7, .integer(let v)): a.supportTCPKeep = v != 0
                case (8, .integer(let v)): a.revision = Int32(truncatingIfNeeded: v)
                case (9, .integer(let v)): a.memberID = Int32(truncatingIfNeeded: v)
                default: a.unknownFields.append(f.raw)
                }
            }
            return a
        }
    }

    struct Command: Equatable {
        var commandID: Int32 = 0
        var type: Int32 = 0
        var payload = Data()
        private(set) var unknownFields = Data()
        func encoded(limits: Limits = .standard) throws -> Data {
            var w = Writer(limits: limits)
            try w.int(1, commandID); try w.int(2, type); try w.bytes(3, payload)
            try w.raw(unknownFields); return try w.finish()
        }
        static func decode(_ data: Data, limits: Limits = .standard) throws -> Self {
            var r = try Reader(data, limits: limits); var c = Self()
            while let f = try r.next() {
                switch (f.number, f.value) {
                case (1, .integer(let v)): c.commandID = Int32(truncatingIfNeeded: v)
                case (2, .integer(let v)): c.type = Int32(truncatingIfNeeded: v)
                case (3, .bytes(let v)): c.payload = v
                default: c.unknownFields.append(f.raw)
                }
            }
            return c
        }
    }

    static func frame(_ packet: Packet, limits: Limits = .standard) throws -> Data {
        let body = try packet.encoded(limits: limits)
        return varint(UInt64(body.count)) + body
    }

    /// One bounded partial frame, no unbounded array of output messages. The callback
    /// consumes each packet synchronously. Any error poisons this decoder; replace it
    /// with a fresh instance on a new transport. Never resynchronize encrypted streams.
    struct FrameDecoder {
        private let limits: Limits
        private var length: UInt64 = 0
        private var prefixBytes = 0
        private var expected: Int?
        private var body = Data()
        private var failed = false
        init(limits: Limits = .standard) { self.limits = limits }
        var bufferedByteCount: Int { body.count + prefixBytes }

        mutating func append(_ bytes: Data, onPacket: (Packet) throws -> Void) throws {
            guard !failed else { throw Failure.decoderFailed }
            do {
                var index = bytes.startIndex
                while index < bytes.endIndex {
                    if let count = expected {
                        let take = min(count - body.count, bytes.distance(from: index, to: bytes.endIndex))
                        let end = bytes.index(index, offsetBy: take)
                        body.append(contentsOf: bytes[index..<end]); index = end
                        if body.count == count {
                            let packet = try Packet.decode(body, limits: limits)
                            body.removeAll(keepingCapacity: true); expected = nil
                            try onPacket(packet)
                        }
                    } else {
                        let byte = bytes[index]; index = bytes.index(after: index)
                        guard prefixBytes < 10, prefixBytes != 9 || byte <= 1 else { throw Failure.varintOverflow }
                        length |= UInt64(byte & 127) << (7 * prefixBytes); prefixBytes += 1
                        if byte & 128 == 0 {
                            guard length <= UInt64(limits.messageBytes) else { throw Failure.limit }
                            let count = Int(length); length = 0; prefixBytes = 0
                            if count == 0 { try onPacket(Packet()) } else { expected = count }
                        } else if prefixBytes == 10 { throw Failure.varintOverflow }
                    }
                }
            } catch { failed = true; body.removeAll(); throw error }
        }
        mutating func finish() throws {
            guard !failed else { throw Failure.decoderFailed }
            guard expected == nil, prefixBytes == 0 else { failed = true; body.removeAll(); throw Failure.truncated }
        }
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value; var out = Data()
        while v >= 128 { out.append(UInt8(v & 127) | 128); v >>= 7 }
        out.append(UInt8(v)); return out
    }

    private struct Writer {
        let limits: Limits
        var data = Data()
        private var count = 0
        init(limits: Limits) { self.limits = limits }
        func finish() throws -> Data {
            // Unknown fields can have been decoded under larger limits. Apply
            // this writer's field/depth budget to retained bytes as well.
            var reader = try Reader(data, limits: limits)
            while reader.index < reader.bytes.count {
                let (number, wire) = try reader.tag()
                try reader.skip(number, wire, depth: 0)
            }
            return data
        }
        mutating func raw(_ bytes: Data) throws {
            guard bytes.count <= limits.messageBytes - data.count else { throw Failure.limit }
            data.append(bytes)
        }
        mutating func tag(_ number: UInt64, _ type: UInt64) throws {
            count += 1; guard count <= limits.fields else { throw Failure.limit }
            try raw(varint(number << 3 | type))
        }
        mutating func int(_ field: UInt64, _ value: Int32, present: Bool = false) throws {
            if value != 0 || present {
                try tag(field, 0); try raw(varint(UInt64(bitPattern: Int64(value))))
            }
        }
        mutating func optionalInt(_ field: UInt64, _ value: Int32?) throws {
            if let value { try int(field, value, present: true) }
        }
        mutating func bytes(_ field: UInt64, _ value: Data?, present: Bool = false) throws {
            guard let value, !value.isEmpty || present else { return }
            guard value.count <= limits.messageBytes else { throw Failure.limit }
            try tag(field, 2); try raw(varint(UInt64(value.count))); try raw(value)
        }
    }

    private enum Value { case integer(UInt64), bytes(Data), unknown }
    private struct Field { let number: UInt64; let value: Value; let raw: Data }
    private struct Reader {
        let bytes: [UInt8]
        let limits: Limits
        var index = 0
        var count = 0
        init(_ data: Data, limits: Limits) throws {
            guard data.count <= limits.messageBytes else { throw Failure.limit }
            self.bytes = Array(data); self.limits = limits
        }
        mutating func integer() throws -> UInt64 {
            var value: UInt64 = 0
            for n in 0..<10 {
                guard index < bytes.count else { throw Failure.truncated }
                let b = bytes[index]; index += 1
                guard n != 9 || b <= 1 else { throw Failure.varintOverflow }
                value |= UInt64(b & 127) << (n * 7)
                if b & 128 == 0 { return value }
            }
            throw Failure.varintOverflow
        }
        mutating func tag() throws -> (UInt64, UInt64) {
            count += 1; guard count <= limits.fields else { throw Failure.limit }
            let key = try integer(); let number = key >> 3
            guard number > 0, number <= 0x1fff_ffff else { throw Failure.invalidTag }
            return (number, key & 7)
        }
        mutating func advance(_ amount: UInt64) throws {
            guard amount <= UInt64(bytes.count - index) else { throw Failure.truncated }
            index += Int(amount)
        }
        mutating func skip(_ number: UInt64, _ wire: UInt64, depth: Int) throws {
            switch wire {
            case 0: _ = try integer()
            case 1: try advance(8)
            case 2: let n = try integer(); try advance(n)
            case 3:
                guard depth < limits.groupDepth else { throw Failure.limit }
                while true {
                    let (child, type) = try tag()
                    if type == 4 {
                        guard child == number else { throw Failure.invalidGroup }; return
                    }
                    try skip(child, type, depth: depth + 1)
                }
            case 4: throw Failure.invalidGroup
            case 5: try advance(4)
            default: throw Failure.invalidWireType
            }
        }
        mutating func next() throws -> Field? {
            guard index < bytes.count else { return nil }
            let start = index; let (number, wire) = try tag(); let value: Value
            switch wire {
            case 0: value = .integer(try integer())
            case 2:
                let n = try integer(); let begin = index; try advance(n)
                value = .bytes(Data(bytes[begin..<index]))
            default: try skip(number, wire, depth: 0); value = .unknown
            }
            return Field(number: number, value: value, raw: Data(bytes[start..<index]))
        }
    }
}

/// Displayed-address byte order, not CoreBluetooth UUIDs or inferred controller identity.
struct SamsungPeerAddress: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: Data
    init(bytes: Data) throws {
        guard bytes.count == 6 else { throw SamsungPeerWire.Failure.invalidSwitch }
        self.bytes = Data(bytes)
    }
    var advertisingID: UInt16 { UInt16(bytes.reduce(0, ^)) << 8 | UInt16(bytes.last!) }
    var description: String { "SamsungPeerAddress(redacted)" }
    var debugDescription: String { description }
}

enum SamsungPeerBudsSwitch: Equatable {
    enum Reason: UInt8 { case media = 1, call = 2 }
    case request(advertisingID: UInt16, address: SamsungPeerAddress, reason: Reason)
    case response(success: UInt8, advertisingID: UInt16, address: SamsungPeerAddress)
    static let handlerID: Int32 = 1

    /// The request builder accepts the observed Buds ID independently of its address:
    /// Android receives by ID and does not demonstrate an address cross-check (A12/A13).
    func command() -> SamsungPeerWire.Command {
        let id: UInt16; let address: SamsungPeerAddress; let suffix: UInt8; let type: Int32
        var payload = Data()
        switch self {
        case .request(let i, let a, let r): id = i; address = a; suffix = r.rawValue; type = 1
        case .response(let s, let i, let a): id = i; address = a; suffix = s; type = 2; payload.append(suffix)
        }
        payload.append(UInt8(id >> 8)); payload.append(UInt8(id & 255)); payload.append(address.bytes)
        if type == 1 { payload.append(suffix) }
        return .init(commandID: 1, type: type, payload: payload)
    }
    static func successResponse(address: SamsungPeerAddress) -> Self {
        .response(success: 1, advertisingID: address.advertisingID, address: address)
    }
    static func decode(handlerID: Int32, command: SamsungPeerWire.Command) throws -> Self {
        guard handlerID == 1, command.commandID == 1, command.payload.count == 9 else { throw SamsungPeerWire.Failure.invalidSwitch }
        let p = Array(command.payload)
        switch command.type {
        case 1:
            guard let reason = Reason(rawValue: p[8]) else { throw SamsungPeerWire.Failure.invalidSwitch }
            return .request(advertisingID: UInt16(p[0]) << 8 | UInt16(p[1]),
                            address: try .init(bytes: Data(p[2..<8])), reason: reason)
        case 2:
            return .response(success: p[0], advertisingID: UInt16(p[1]) << 8 | UInt16(p[2]),
                             address: try .init(bytes: Data(p[3..<9])))
        default: throw SamsungPeerWire.Failure.invalidSwitch
        }
    }
}
