import Foundation
import CoreFoundation
import CoreAudio
import AudioToolbox

/// HAL effects only: constructing this environment never probes Bluetooth or
/// changes routing, mute, or any device other than the explicitly checked ID.
@MainActor struct NativeBudsVolumeEnvironment {
    struct Endpoint: Equatable {
        var uid: String
        var transport: UInt32
        var alive: Bool
        var output: Bool
    }
    enum Property: CaseIterable {
        case virtualMain, mainScalar

        var address: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: self == .virtualMain
                ? kAudioHardwareServiceDeviceProperty_VirtualMainVolume : kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        }
    }
    var defaultOutput: () throws -> AudioObjectID
    var endpoint: (AudioObjectID) throws -> Endpoint
    /// nil means absent; false means present but read-only. Main element only.
    var writable: (AudioObjectID, Property) throws -> Bool?
    var read: (AudioObjectID, Property) throws -> Float32
    var write: (AudioObjectID, Property, Float32) throws -> Void

    static func live() -> Self {
        Self(defaultOutput: {
            try integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        }, endpoint: { id in
            var uidAddress = global(kAudioDevicePropertyDeviceUID)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout.size(ofValue: uid))
            try check(AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid))
            guard let uid = uid?.takeRetainedValue() as String? else {
                throw Failure(message: "Identidade de áudio indisponível.")
            }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &size))
            return Endpoint(uid: uid, transport: try integer(id, kAudioDevicePropertyTransportType),
                alive: try integer(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                output: size >= MemoryLayout<AudioStreamID>.size)
        }, writable: { id, property in
            var address = property.address
            guard AudioObjectHasProperty(id, &address) else { return nil }
            var settable: DarwinBoolean = false
            try check(AudioObjectIsPropertySettable(id, &address, &settable))
            return settable.boolValue
        }, read: { id, property in
            var address = property.address, value: Float32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: value))
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
            guard size == MemoryLayout<Float32>.size else {
                throw Failure(message: "Leitura de volume inválida.")
            }
            return value
        }, write: { id, property, scalar in
            var address = property.address, value = scalar
            try check(AudioObjectSetPropertyData(id, &address, 0, nil,
                UInt32(MemoryLayout.size(ofValue: value)), &value))
        })
    }

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
    private static func integer(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = global(selector), value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        guard size == MemoryLayout<UInt32>.size else { throw Failure(message: "Leitura de áudio inválida.") }
        return value
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure(message: "Falha no volume do Mac (CoreAudio: \(status)).") }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

@MainActor final class NativeBudsVolume {
    struct Permission: Equatable {
        var selectedAddress: String
        var canSet: Bool
    }
    private struct Observation {
        let id: AudioObjectID
        let endpoint: NativeBudsVolumeEnvironment.Endpoint
        let property: NativeBudsVolumeEnvironment.Property
        let writable: Bool
        let scalar: Float32
    }
    private typealias Failure = NativeBudsVolumeEnvironment.Failure
    private let environment: NativeBudsVolumeEnvironment
    private let permission: () -> Permission
    private(set) var error: String?

    init(environment: NativeBudsVolumeEnvironment? = nil, permission: @escaping () -> Permission) {
        self.environment = environment ?? .live()
        self.permission = permission
    }

    /// Accept complete MAC UIDs (with the HAL output suffix where supplied).
    /// Never strip arbitrary UID text or match a substring, name or account ID.
    static func bluetoothAddress(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        let hex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if bytes.count == 12, bytes.allSatisfy(hex) { return value.uppercased() }
        guard bytes.count == 17, bytes[2] == 58 || bytes[2] == 45 else { return nil }
        let separator = bytes[2]
        for index in bytes.indices {
            if index % 3 == 2 {
                guard bytes[index] == separator else { return nil }
            } else if !hex(bytes[index]) { return nil }
        }
        return value.replacingOccurrences(of: String(UnicodeScalar(separator)), with: "").uppercased()
    }

    private func matches(_ endpoint: NativeBudsVolumeEnvironment.Endpoint, selected: String) -> Bool {
        let uid = endpoint.uid.hasSuffix(":output") ? String(endpoint.uid.dropLast(7)) : endpoint.uid
        return endpoint.alive && endpoint.output
            && [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(endpoint.transport)
            && Self.bluetoothAddress(uid) == Self.bluetoothAddress(selected)
            && Self.bluetoothAddress(selected) != nil
    }

    private func observe(_ selected: String) throws -> Observation {
        guard Self.bluetoothAddress(selected) != nil else { throw Failure(message: "Selecione os Buds para ler o volume.") }
        let id = try environment.defaultOutput()
        let endpoint = try environment.endpoint(id)
        guard id != kAudioObjectUnknown, matches(endpoint, selected: selected) else {
            throw Failure(message: "Os Buds selecionados não são a saída de áudio do Mac.")
        }
        // Prefer virtual main; the only fallback is an existing main scalar.
        // Never split a write across channel controls or retry a failed write.
        for property in NativeBudsVolumeEnvironment.Property.allCases {
            guard let writable = try environment.writable(id, property) else { continue }
            let scalar = try environment.read(id, property)
            guard scalar.isFinite, (0...1).contains(scalar) else { throw Failure(message: "Leitura de volume inválida.") }
            guard try environment.defaultOutput() == id, try environment.endpoint(id) == endpoint else {
                throw Failure(message: "A saída de áudio mudou. Tente novamente.")
            }
            return Observation(id: id, endpoint: endpoint, property: property, writable: writable, scalar: scalar)
        }
        throw Failure(message: "Esta saída não oferece controle de volume principal.")
    }

    /// Every poll reads HAL afresh, including changes made outside this app.
    /// A requested value is never cached or presented as an observed value.
    var snapshot: [String: Any] {
        let selected = permission()
        var state: [String: Any] = ["available": false, "can_set": false, "level": NSNull()]
        var status: String
        do {
            let observed = try observe(selected.selectedAddress)
            let current = permission()
            guard current.selectedAddress == selected.selectedAddress else {
                throw Failure(message: "A seleção dos Buds mudou. Tente novamente.")
            }
            state["available"] = true
            state["can_set"] = current.canSet && observed.writable
            state["level"] = Double(observed.scalar) * 100
            status = !observed.writable ? "Volume somente para leitura."
                : current.canSet ? "Volume do Mac." : "Aguarde os Buds assumirem o áudio do Mac."
        } catch { status = error.localizedDescription }
        state["status"] = error ?? status
        state["error"] = error.map { $0 as Any } ?? NSNull()
        return state
    }

    /// Called on the native main actor by the asynchronous UI dispatch. All
    /// failures remain in the next snapshot instead of escaping across the ABI.
    func perform(level: Any?) {
        error = nil
        do {
            guard let number = level as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100).contains(number.doubleValue) else {
                throw Failure(message: "Volume inválido. Use um número de 0 a 100.")
            }
            let scalar = Float32(number.doubleValue / 100)
            let selected = permission()
            guard selected.canSet else { throw Failure(message: "Volume indisponível durante alternância, recuperação ou chamada.") }
            let observed = try observe(selected.selectedAddress)
            guard observed.writable else { throw Failure(message: "Volume somente para leitura.") }

            // No suspension or other work between this fence and the one HAL
            // write. Recheck selection, ownership/call/guard, full UID, transport,
            // liveness, output streams, property permission and default route.
            guard permission() == selected,
                  try environment.endpoint(observed.id) == observed.endpoint,
                  matches(observed.endpoint, selected: selected.selectedAddress),
                  try environment.writable(observed.id, observed.property) == true,
                  try environment.defaultOutput() == observed.id,
                  permission() == selected else {
                throw Failure(message: "A saída ou a permissão de volume mudou. Tente novamente.")
            }
            try environment.write(observed.id, observed.property, scalar)
            let readback = try observe(selected.selectedAddress)
            guard permission() == selected, readback.id == observed.id, readback.endpoint == observed.endpoint,
                  readback.property == observed.property, readback.writable,
                  abs(readback.scalar - scalar) <= 0.005 else {
                throw Failure(message: "O Mac ainda não confirmou o volume solicitado.")
            }
        } catch { self.error = error.localizedDescription }
    }
}
