import Foundation
import CoreAudio
import AppKit
import Darwin

/// A local HAL snapshot; never captures samples, media metadata or user input.
/// Helper ownership is resolved by the system responsibility SPI, not by the
/// name WebKit. ABI reference: Chromium base/process/process_info_mac.mm.
enum MacPlaybackProcessActivity {
    struct ProcessSample {
        let bundle: String
        let responsibleBundle: String?
        let output: Bool?
        let eligible: Bool
    }
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsiblePID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsiblePID.self)
    }()
    static func classify(client: String, samples: [ProcessSample]) -> (clientOutput: Bool?, anyAppOutput: Bool) {
        var matching = false, any = false, unknown = false
        for sample in samples {
            let match = sample.bundle == client || sample.bundle.hasPrefix(client + ".") || sample.responsibleBundle == client
            guard match || sample.eligible else { continue }
            if let output = sample.output {
                any = any || output
                if match { matching = matching || output }
            } else { unknown = true }
        }
        return (matching ? true : unknown ? nil : false, any)
    }
    static func read(client: String) throws -> (clientOutput: Bool?, anyAppOutput: Bool) {
        guard #available(macOS 14.2, *), !client.isEmpty else { return (nil, false) }
        func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
            var a = property(selector), value: UInt32 = 0, size: UInt32 = 4
            return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value : nil
        }
        func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var a = property(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr ? value?.takeRetainedValue() as String? : nil
        }
        var a = property(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        guard status == noErr, size % 4 == 0 else { throw NSError(domain: "BudsLocalPlayback", code: Int(status)) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        if !ids.isEmpty {
            status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
            guard status == noErr else { throw NSError(domain: "BudsLocalPlayback", code: Int(status)) }
        }
        var samples: [ProcessSample] = []
        for id in ids.prefix(Int(size) / 4) {
            guard let rawPID = integer(id, kAudioProcessPropertyPID), rawPID > 0, rawPID <= UInt32(Int32.max), rawPID != UInt32(getpid()) else { continue }
            let pid = pid_t(rawPID), bundle = string(id, kAudioProcessPropertyBundleID) ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            let responsible = (responsiblePID?(pid)).flatMap { $0 > 0 ? NSRunningApplication(processIdentifier: $0) : nil }
            samples.append(ProcessSample(bundle: bundle, responsibleBundle: responsible?.bundleIdentifier,
                output: integer(id, kAudioProcessPropertyIsRunningOutput).map { $0 != 0 },
                eligible: app?.activationPolicy == .regular || responsible?.activationPolicy == .regular || bundle.hasPrefix("com.apple.WebKit.")))
        }
        return classify(client: client, samples: samples)
    }
}
