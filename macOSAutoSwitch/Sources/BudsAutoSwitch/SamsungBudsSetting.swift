import Foundation

extension SamsungBudsSettingsPacket {
    /// Original GalaxyBudsClient command IDs and common Buds3 Pro status
    /// offsets (SppMessageEnums / ExtendedStatusUpdateDecoder).
    /// These are absolute scalar commands; they never rewrite another setting.
    enum Setting: String, CaseIterable {
        case conversationDetection = "conversation_detection"
        case conversationTimeout = "conversation_timeout"
        case oneEarbudNoiseControl = "one_earbud_noise_control"
        case sidetone
        case callAudioToBuds = "call_audio_to_buds"
        case stereoBalance = "stereo_balance"

        var command: UInt8 {
            switch self {
            case .conversationDetection: return 122 // SET_DETECT_CONVERSATIONS
            case .conversationTimeout: return 123 // SET_DETECT_CONVERSATIONS_DURATION
            case .oneEarbudNoiseControl: return 111 // SET_ANC_WITH_ONE_EARBUD
            case .sidetone: return 139 // SET_SIDETONE
            case .callAudioToBuds: return 110 // SET_CALL_PATH_CONTROL
            case .stereoBalance: return 143 // SET_HEARING_ENHANCEMENTS (EqualizerPageViewModel)
            }
        }
        var statusOffset: Int {
            switch self {
            case .conversationDetection: return 26
            case .conversationTimeout: return 27
            case .oneEarbudNoiseControl: return 28
            case .sidetone: return 33
            case .callAudioToBuds: return 34
            case .stereoBalance: return 25
            }
        }
        var isBoolean: Bool {
            switch self {
            case .conversationTimeout, .stereoBalance: return false
            case .conversationDetection, .oneEarbudNoiseControl, .sidetone, .callAudioToBuds: return true
            }
        }
        var values: ClosedRange<Int> {
            switch self {
            case .conversationTimeout: return 0...2
            case .stereoBalance: return 0...32 // EqualizerPage.axaml: StereoBalance slider
            case .conversationDetection, .oneEarbudNoiseControl, .sidetone, .callAudioToBuds: return 0...1
            }
        }
        func wireValue(_ value: Int) -> UInt8? {
            guard values.contains(value) else { return nil }
            // Upstream AdvancedPageViewModel inverts call-path control.
            return UInt8(self == .callAudioToBuds ? 1 - value : value)
        }
        func observedValue(_ payload: [UInt8]) -> Int? {
            guard payload.indices.contains(statusOffset), values.contains(Int(payload[statusOffset])) else { return nil }
            let value = Int(payload[statusOffset])
            return self == .callAudioToBuds ? 1 - value : value
        }
        static func observed(_ payload: [UInt8]) -> [Self: Int] {
            guard let revision = payload.first, (1...4).contains(revision) else { return [:] }
            return Dictionary(uniqueKeysWithValues: allCases.compactMap { setting in
                setting.observedValue(payload).map { (setting, $0) }
            })
        }
        static func forCommand(_ command: UInt8) -> Self? { allCases.first { $0.command == command } }
    }
}
