import Foundation

/// Presentation capabilities only. Neither a paired alias nor the cache
/// authorizes a command: the settings driver verifies the physical model.
struct NativeBudsProfile {
    let model: String?
    let title: String
    let artworkPrefixes: Set<String>
    let nativeSettingsImplemented: Bool
    let handoffValidated: Bool

    static func resolve(model: String?, name: String) -> Self {
        let known = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = name.lowercased().filter { $0.isLetter || $0.isNumber }
        let hint = known.flatMap { $0.isEmpty ? nil : $0 } ?? (
            alias.hasPrefix("galaxybuds4pro") || alias.hasPrefix("buds4pro") ? "Buds4Pro" :
            alias.hasPrefix("galaxybuds4") || alias.hasPrefix("buds4") ? "Buds4" :
            alias.hasPrefix("galaxybuds3pro") || alias.hasPrefix("buds3pro") ? "Buds3Pro" : nil)
        switch hint {
        case "Buds3Pro": return .init(model: hint, title: "Galaxy Buds3 Pro", artworkPrefixes: ["Buds3ProSilver", "Buds3ProWhite"], nativeSettingsImplemented: true, handoffValidated: true)
        case "Buds4": return .init(model: hint, title: "Galaxy Buds4", artworkPrefixes: ["Buds4Black", "Buds4White"], nativeSettingsImplemented: true, handoffValidated: false)
        case "Buds4Pro": return .init(model: hint, title: "Galaxy Buds4 Pro", artworkPrefixes: ["Buds4ProBlack", "Buds4ProWhite", "Buds4ProApricot"], nativeSettingsImplemented: true, handoffValidated: false)
        default:
            let profile = SamsungBudsModelProfile.resolve(model: hint, name: name)
            return .init(model: profile?.rawValue ?? hint, title: profile?.title ?? "Galaxy Buds", artworkPrefixes: [], nativeSettingsImplemented: profile != nil, handoffValidated: false)
        }
    }

    func artwork(_ prefix: String?) -> String? {
        prefix.flatMap { artworkPrefixes.contains($0) ? $0 : nil }
    }

    /// Representative artwork only; a fallback color never grants capabilities.
    var defaultArtwork: String? {
        switch model {
        case "Buds3Pro": return "Buds3ProSilver"
        case "Buds4": return "Buds4White"
        case "Buds4Pro": return "Buds4ProWhite"
        default: return nil
        }
    }

    var fields: [String: Any] {
        ["model": model as Any? ?? NSNull(), "title": title,
         "native_settings_implemented": nativeSettingsImplemented,
         "handoff_validated": handoffValidated,
         "compatibility": handoffValidated ? "" : "Os ajustes disponíveis dependem do modelo e da versão dos Buds."]
    }
}
