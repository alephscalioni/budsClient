import Foundation
import CoreAudio
import AppKit
import IOBluetooth

struct AudioActivity {
    var output = false
    var input = false
    var applications: [String] = []
}

/// Kept with AudioActivity, outside the standalone playback observer sources.
/// CoreAudio process objects can disappear between enumeration and a property
/// read. Retry one complete snapshot; an unknown surviving process still fails
/// closed and can never be reported as silent.
enum MacAudioActivityReader {
    struct Sample {
        let output: Bool?
        let input: Bool?
        let application: String
    }
    enum Failure: Error { case unavailable }
    static func read(processes: () throws -> [AudioObjectID], sample: (AudioObjectID) -> Sample?) throws -> AudioActivity {
        func snapshot() throws -> AudioActivity {
            var result = AudioActivity()
            for id in try processes() {
                guard let value = sample(id) else { continue }
                guard let output = value.output, let input = value.input else { throw Failure.unavailable }
                result.output = result.output || output
                result.input = result.input || input
                if output { result.applications.append(value.application) }
            }
            return result
        }
        do { return try snapshot() }
        catch { return try snapshot() }
    }
}

struct MacAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = property(selector)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw BridgeError.message("CoreAudio: \(status)") }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        if values.isEmpty { return [] }
        let read = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        guard read == noErr else { throw BridgeError.message("CoreAudio: \(read)") }
        return Array(values.prefix(Int(size) / 4))
    }
    static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector), value: UInt32 = 0, size: UInt32 = 4
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value?.takeRetainedValue() as String? : nil
    }
    static func activity() throws -> AudioActivity {
        guard #available(macOS 14.2, *) else { throw BridgeError.message("macOS 14.2+") }
        var applications: [NSRunningApplication] = []
        do { return try MacAudioActivityReader.read(processes: {
            applications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            return try ids(system, kAudioHardwarePropertyProcessObjectList)
        }, sample: { process in
            guard let pid = integer(process, kAudioProcessPropertyPID), pid > 0, pid <= UInt32(Int32.max),
                  pid != UInt32(ProcessInfo.processInfo.processIdentifier) else { return nil }
            let processBundle = string(process, kAudioProcessPropertyBundleID) ?? ""
            let running = NSRunningApplication(processIdentifier: pid_t(pid))
            let app = running?.activationPolicy == .regular ? running : applications.first { app in
                guard let bundle = app.bundleIdentifier else { return false }
                return processBundle == bundle || processBundle.hasPrefix(bundle + ".")
            }
            let isWebContent = processBundle.hasPrefix("com.apple.WebKit.")
            guard app != nil || isWebContent else { return nil }
            // Only visible applications, excluding system sound daemons. Keeping silent
            // audio streams open is still possible; the UI explains this limitation.
            return MacAudioActivityReader.Sample(
                output: integer(process, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 },
                input: integer(process, kAudioProcessPropertyIsRunningInput).map { $0 != 0 },
                application: app?.localizedName ?? L("Conteúdo da web", "Web content"))
        }) } catch MacAudioActivityReader.Failure.unavailable {
            throw BridgeError.message(L("Não foi possível ler a atividade de áudio.", "Cannot read audio activity."))
        }
    }
    static func outputDevices() throws -> [AudioObjectID] {
        try ids(system, kAudioHardwarePropertyDevices).filter { device in
            var address = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
                && integer(device, kAudioDevicePropertyDeviceIsAlive) == 1
        }
    }
    static func playbackActivity(client: String) throws -> (clientOutput: Bool?, anyAppOutput: Bool) {
        try MacPlaybackProcessActivity.read(client: client)
    }
    static func isBluetoothConnected(_ mac: String) async throws -> Bool {
        // Legacy IOBluetooth objects and HAL outputs can retain stale state on macOS 27.
        let result = try await runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 5)
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else {
            throw BridgeError.message("Cannot confirm the Bluetooth connection")
        }
        return controllers.contains { controller in
            let entries = controller["device_connected"] as? [[String: [String: Any]]] ?? []
            return entries.contains { entry in entry.values.contains { detail in
                (detail["device_address"] as? String).map { normalize($0) == normalize(mac) } == true
            }}
        }
    }
    static func waitingOutput(excluding buds: AudioObjectID?) throws -> AudioObjectID? {
        let outputs = try outputDevices().filter { $0 != buds }
        if let current = defaultOutput(), current != buds, outputs.contains(current) { return current }
        if let alerts = integer(system, kAudioHardwarePropertyDefaultSystemOutputDevice),
           alerts != buds, outputs.contains(alerts) { return alerts }
        return outputs.first { integer($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
    }
    static func defaultOutput() -> AudioObjectID? { integer(system, kAudioHardwarePropertyDefaultOutputDevice) }
    static func setOutput(_ device: AudioObjectID) async throws {
        var address = property(kAudioHardwarePropertyDefaultOutputDevice), value = device
        let status = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
        guard status == noErr else { throw BridgeError.message("CoreAudio output: \(status)") }
        // CoreAudio property writes can complete asynchronously.
        for _ in 0..<30 {
            if defaultOutput() == device { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError.message("Audio route was not confirmed within three seconds")
    }
    static func normalize(_ string: String) -> String {
        string.lowercased().filter { $0.isHexDigit }
    }
    /// UID/transport identity is available before HAL publishes output streams.
    /// This only recognizes an automatic route; it never proves audio readiness.
    static func outputBelongsToBuds(_ device: AudioObjectID, address: String) -> Bool {
        guard normalize(address).count == 12,
              let transport = integer(device, kAudioDevicePropertyTransportType),
              [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport),
              let uid = string(device, kAudioDevicePropertyDeviceUID) else { return false }
        return normalize(uid).contains(normalize(address))
    }
    static func output(for mac: String) throws -> AudioObjectID? {
        let matching = try outputDevices().filter { outputBelongsToBuds($0, address: mac) }
        if let current = defaultOutput(), matching.contains(current) { return current }
        return matching.first
    }
    /// Enumerating IOBluetoothDevice.pairedDevices() in this process resets the
    /// cached live state of existing device objects on the tested macOS 27 host.
    /// Read the OS catalog in a child process; isPaired checks the exact selected
    /// address without re-enumerating or creating a radio connection.
    @MainActor static func pairedBuds() async throws -> [(address: String, name: String)] {
        let result = try await runCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 5)
        guard result.code == 0 else { throw BridgeError.message("Não foi possível ler os dispositivos Bluetooth pareados.") }
        return try pairedBuds(from: Data(result.output.utf8), isPaired: { address in
            IOBluetoothDevice(addressString: address)?.isPaired() == true
        })
    }
    static func pairedBuds(from data: Data, isPaired: (String) -> Bool) throws -> [(address: String, name: String)] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else {
            throw BridgeError.message("Não foi possível ler os dispositivos Bluetooth pareados.")
        }
        var seen = Set<String>()
        var result: [(address: String, name: String)] = []
        for controller in controllers {
            for group in ["device_connected", "device_not_connected"] {
                for entry in controller[group] as? [[String: [String: Any]]] ?? [] {
                    for (name, detail) in entry.sorted(by: { $0.key < $1.key }) {
                        guard name.localizedCaseInsensitiveContains("buds"),
                              let raw = detail["device_address"] as? String else { continue }
                        let compact = normalize(raw)
                        guard compact.count == 12,
                              raw.filter({ $0 != ":" && $0 != "-" }).lowercased() == compact else { continue }
                        let address = stride(from: 0, to: 12, by: 2).map { offset in
                            let start = compact.index(compact.startIndex, offsetBy: offset)
                            return String(compact[start..<compact.index(start, offsetBy: 2)])
                        }.joined(separator: ":").uppercased()
                        guard !seen.contains(compact), isPaired(address) else { continue }
                        seen.insert(compact)
                        result.append((address, name))
                    }
                }
            }
        }
        return result
    }
    static func open(_ mac: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let device = IOBluetoothDevice(addressString: mac) else {
                    continuation.resume(throwing: BridgeError.message("Bluetooth device unavailable")); return
                }
                if device.isConnected() { continuation.resume(); return }
                // HCI page timeout uses 0.625 ms units; 12,800 is eight seconds.
                let status = device.openConnection(nil, withPageTimeout: 12800, authenticationRequired: true)
                if status == kIOReturnSuccess || device.isConnected() { continuation.resume() }
                else { continuation.resume(throwing: BridgeError.message("Bluetooth connect: \(status)")) }
            }
        }
    }
    /// Submit the SDK close off the main actor. Its return is advisory: a
    /// freshly-created macOS 27 object may say "not open" after ACL disappearance.
    /// The full-release controller must still obtain a fresh linked()==false.
    static func requestClose(_ mac: String) async throws -> IOReturn {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IOReturn, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let device = IOBluetoothDevice(addressString: mac) else {
                    continuation.resume(throwing: BridgeError.message("Bluetooth device unavailable")); return
                }
                continuation.resume(returning: device.closeConnection())
            }
        }
    }
    static func close(_ mac: String) async throws {
        let status = try await requestClose(mac)
        guard status == kIOReturnSuccess else {
            throw BridgeError.message("Bluetooth disconnect: \(status)")
        }
    }
}
