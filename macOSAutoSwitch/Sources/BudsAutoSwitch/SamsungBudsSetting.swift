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
        /// Source-backed offset and minimum status revision. No modern offset
        /// is reused for Buds/Plus/Live/Pro merely because the packet is long.
        func observation(model: String, revision: Int) -> Int? {
            guard let profile = SamsungBudsModelProfile(rawValue: model) else { return nil }
            let entry: (offset: Int, minimum: Int)?
            switch profile {
            case .buds: entry = nil
            case .budsPlus:
                switch self {
                case .sidetone: entry = (19, 8)
                case .callAudioToBuds: entry = (23, 13)
                default: entry = nil
                }
            case .budsLive:
                switch self {
                case .stereoBalance: entry = (22, 7)
                case .callAudioToBuds: entry = (23, 8)
                default: entry = nil
                }
            case .budsPro:
                switch self {
                case .conversationDetection: entry = (26, 0)
                case .conversationTimeout: entry = (27, 0)
                case .stereoBalance: entry = (29, 5)
                case .oneEarbudNoiseControl: entry = (32, 8)
                case .sidetone: entry = (36, 9)
                case .callAudioToBuds: entry = (37, 10)
                }
            case .buds2:
                switch self {
                case .stereoBalance: entry = (25, 0)
                case .oneEarbudNoiseControl: entry = (28, 3)
                case .sidetone: entry = (33, 6)
                case .callAudioToBuds: entry = (34, 7)
                default: entry = nil
                }
            case .buds2Pro:
                entry = (statusOffset, self == .sidetone || self == .callAudioToBuds ? 1 : 0)
            default:
                guard (1...4).contains(revision) else { return nil }
                if (self == .conversationDetection || self == .conversationTimeout)
                    && ![.buds3Pro, .buds4Pro].contains(profile) { entry = nil }
                else { entry = (statusOffset, 1) }
            }
            guard let entry, revision >= entry.minimum else { return nil }
            return entry.offset
        }
        func observedValue(_ payload: [UInt8], model: String = "Buds3Pro") -> Int? {
            guard let revision = payload.first, let offset = observation(model: model, revision: Int(revision)),
                  payload.indices.contains(offset), values.contains(Int(payload[offset])) else { return nil }
            let value = Int(payload[offset])
            return self == .callAudioToBuds ? 1 - value : value
        }
        static func observed(_ payload: [UInt8], model: String = "Buds3Pro") -> [Self: Int] {
            Dictionary(uniqueKeysWithValues: allCases.compactMap { setting in
                setting.observedValue(payload, model: model).map { (setting, $0) }
            })
        }
        static func forCommand(_ command: UInt8) -> Self? { allCases.first { $0.command == command } }
    }
}
