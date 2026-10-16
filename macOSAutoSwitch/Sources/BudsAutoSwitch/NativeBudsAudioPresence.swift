import Foundation
import CoreAudio

/// Presentation evidence only. HAL getters never open Bluetooth, start streams,
/// change routing or grant settings/volume/continuity ownership.
enum NativeBudsAudioPresence {
    struct Endpoint {
        let uid: String
        let transport: UInt32
        let alive: Bool
        let input: Bool
        let output: Bool
        let running: Bool
    }
    struct Environment {
        var devices: () -> [AudioObjectID]?
        var defaultInput: () -> AudioObjectID?
        var defaultOutput: () -> AudioObjectID?
        var endpoint: (AudioObjectID) -> Endpoint?
    }

    static func read(address: String, environment: Environment = live()) -> Bool? {
        guard let selected = NativeConnectionBannerPolicy.normalizedAddress(address) else { return nil }
        let input = environment.defaultInput(), output = environment.defaultOutput()
        let devices = environment.devices()
        var candidates = Set(devices ?? [])
        for id in [input, output].compactMap({ $0 }) where id != kAudioObjectUnknown { candidates.insert(id) }
        var unknown = devices == nil || input == nil || output == nil
        for id in candidates where id != kAudioObjectUnknown {
            guard let endpoint = environment.endpoint(id) else { unknown = true; continue }
            guard endpoint.alive,
                  [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(endpoint.transport) else { continue }
            let suffix: String?
            if endpoint.uid.hasSuffix(":input") { suffix = ":input" }
            else if endpoint.uid.hasSuffix(":output") { suffix = ":output" }
            else { suffix = nil }
            let uid = suffix.map { String(endpoint.uid.dropLast($0.count)) } ?? endpoint.uid
            guard NativeConnectionBannerPolicy.normalizedAddress(uid) == selected else { continue }
            let hasInput = endpoint.input && suffix != ":output"
            let hasOutput = endpoint.output && suffix != ":input"
            // Calls may use HFP input, or choose an app-specific endpoint while
            // the system's default media output remains somewhere else.
            if (id == input && hasInput) || (id == output && hasOutput)
                || (endpoint.running && (hasInput || hasOutput)) { return true }
        }
        return unknown ? nil : false
    }

    static func live() -> Environment {
        func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }
        func integer(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
            var address = property(selector), value: UInt32 = 0, size: UInt32 = 4
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, size == 4 else { return nil }
            return value
        }
        func streams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool? {
            var address = property(kAudioDevicePropertyStreams, scope: scope), size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
            return size >= MemoryLayout<AudioStreamID>.size
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        return .init(devices: {
            var address = property(kAudioHardwarePropertyDevices), size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
            guard size > 0 else { return [] }
            guard Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { return nil }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
            guard status == noErr else { return nil }
            return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }, defaultInput: { integer(system, kAudioHardwarePropertyDefaultInputDevice) },
           defaultOutput: { integer(system, kAudioHardwarePropertyDefaultOutputDevice) }, endpoint: { id in
            // Read transport/liveness first; unrelated devices require no UID
            // or stream inspection beyond these passive properties.
            guard let transport = integer(id, kAudioDevicePropertyTransportType),
                  let alive = integer(id, kAudioDevicePropertyDeviceIsAlive) else { return nil }
            guard alive == 1, [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport) else {
                return Endpoint(uid: "", transport: transport, alive: alive == 1, input: false, output: false, running: false)
            }
            var address = property(kAudioDevicePropertyDeviceUID), uid: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout.size(ofValue: uid))
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr,
                  let uid = uid?.takeRetainedValue() as String?, let input = streams(id, kAudioDevicePropertyScopeInput),
                  let output = streams(id, kAudioDevicePropertyScopeOutput),
                  let running = integer(id, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return nil }
            return Endpoint(uid: uid, transport: transport, alive: true, input: input, output: output, running: running != 0)
        })
    }
}

