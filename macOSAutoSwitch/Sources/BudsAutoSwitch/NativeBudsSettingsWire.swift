import Foundation
import CoreFoundation

/// Private pipes only. No shell, network listener or arbitrary SDK commands.
enum NativeBudsSettingsWire {
    static let flag = "--buds-settings-session"
    static let maximumID: UInt = 9_007_199_254_740_991
    static func encode(_ value: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 4096 else { throw NativeBudsError(message: "Mensagem de ajustes excedeu o limite.") }
        return data + Data([10])
    }
    static func integer(_ value: Any?, maximum: UInt = maximumID) -> UInt? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= Double(maximumID), number.doubleValue <= Double(maximum),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.uintValue
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func frame(_ value: [String: Any]) -> SamsungBudsSettingsPacket.Frame? {
        guard let command = integer(value["command"], maximum: 255), [0x61, 0x42, 0x77, 0x9E, 0xA1, 0xA3, 0x60, 0x69, 0xB4].contains(command),
              let encoded = value["payload"] as? String, encoded.utf8.count <= 1360,
              let payload = Data(base64Encoded: encoded), payload.count <= 1020 else { return nil }
        return .init(command: UInt8(command), payload: payload, isFragment: false)
    }
    static func permittedWrite(_ data: Data) -> Bool {
        guard let frame = SamsungBudsSettingsPacket.decodeCompleteFrame(data), !frame.isFragment else { return false }
        let payload = [UInt8](frame.payload)
        // Read-only metadata/custom-curve queries and the Buds3 nine-band curve.
        // Firmware transfer commands deliberately remain outside this service.
        if [UInt8(0x69), 0xB4].contains(frame.command) { return payload.isEmpty }
        if frame.command == 0x89 {
            return payload.count == 10 && payload[0] == 9
                && payload.dropFirst().allSatisfy { (-10...10).contains(Int(Int8(bitPattern: $0))) }
        }
        if frame.command == 0x86, payload == [7] { return true }
        return NativeBudsToolsPacket.permits(frame) || SamsungBudsSettingsPacket.acknowledges(
            .init(command: 0x42, payload: Data([frame.command] + payload), isFragment: false),
            command: frame.command, payload: payload)
    }
    struct Lines {
        private var buffer = Data()
        mutating func append(_ data: Data) throws -> [[String: Any]] {
            guard data.count <= 65536 else { throw NativeBudsError(message: "Fluxo de ajustes excedeu o limite.") }
            buffer.append(data)
            var values: [[String: Any]] = []
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard line.count <= 4096,
                      let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw NativeBudsError(message: "Resposta inválida do serviço de ajustes.")
                }
                values.append(value)
            }
            guard buffer.count <= 4096 else { throw NativeBudsError(message: "Resposta incompleta excedeu o limite.") }
            return values
        }
    }
}

/// Copies pipe chunks before hopping to MainActor, retaining EOF and byte order.
final class NativeBudsSettingsPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var lines = NativeBudsSettingsWire.Lines()
    private let receive: @MainActor ([[String: Any]]?) -> Void
    init(receive: @escaping @MainActor ([[String: Any]]?) -> Void) { self.receive = receive }
    func stop() { lock.lock(); active = false; lock.unlock() }
    func append(_ data: Data) {
        lock.lock()
        guard active else { lock.unlock(); return }
        let batch: [[String: Any]]?
        do {
            if data.isEmpty { batch = nil; active = false }
            else { batch = try lines.append(data) }
        } catch { batch = nil; active = false }
        // Queue under the lock to keep concurrent ingress/EOF ordered.
        DispatchQueue.main.async { [self] in receive(batch) }
        lock.unlock()
    }
}
