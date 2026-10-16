import Foundation
import CoreFoundation

/// Observation display never grants controls. The host has already scoped
/// these fields to the selected physical device/link; no account inference.
enum NativeBudsPanelReadings {
    struct Settings {
        let values: [String: Any]
        let date: Date
        let historical: Bool
        let mayHaveChanged: Bool
    }
    static func settings(_ device: [String: Any], connected: Bool, canControl: Bool, now: Date = Date()) -> Settings? {
        guard connected else { return nil }
        if canControl, boolean(device["model_verified"]) == true, boolean(device["read_fresh"]) == true,
           let date = date(device["observed_at"], now: now) {
            return Settings(values: device, date: date, historical: false, mayHaveChanged: false)
        }
        guard let previous = device["last_observation"] as? [String: Any],
              boolean(previous["model_verified"]) == true, let date = date(previous["observed_at"], now: now) else { return nil }
        return Settings(values: previous, date: date, historical: true,
            mayHaveChanged: boolean(previous["settings_may_have_changed"]) == true)
    }
    static func battery(_ object: [String: Any], key: String, connected: Bool) -> Int? {
        guard connected, let number = number(object[key]), (0...100).contains(number), number.rounded() == number else { return nil }
        return Int(number)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func date(_ value: Any?, now: Date) -> Date? {
        guard let stamp = number(value), stamp >= 0, stamp < 253402300799,
              stamp <= now.timeIntervalSince1970 + 5 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }
}
