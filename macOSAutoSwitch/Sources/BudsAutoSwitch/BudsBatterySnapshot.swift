import Foundation

/// Shared with the existing client's IBasicStatusUpdate; contains no account data.
struct BudsBatterySnapshot: Codable {
    let address: String
    let name: String
    let model: String
    let icon: String?
    let left: Int?
    let right: Int?
    let casePercent: Int?
    let observedAt: TimeInterval
    enum CodingKeys: String, CodingKey {
        case address, name, model, icon, left, right
        case casePercent = "case_percent", observedAt = "observed_at"
    }
    static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BudsAutoSwitch/battery-status.json") }
    static func load(address: String, now: Date = Date()) -> BudsBatterySnapshot? {
        guard let data = try? Data(contentsOf: url), data.count < 8192 else { return nil }
        return decode(data, address: address, now: now)
    }
    /// Presentation cache may outlive five minutes, always with its original
    /// timestamp. This is never evidence of a current connection or permission.
    static func loadCached(address: String, now: Date = Date()) -> BudsBatterySnapshot? {
        guard let data = try? Data(contentsOf: url), data.count < 8192 else { return nil }
        return decode(data, address: address, now: now, maximumAge: nil)
    }
    static func decode(_ data: Data, address: String, now: Date) -> BudsBatterySnapshot? {
        decode(data, address: address, now: now, maximumAge: 300)
    }
    static func decode(_ data: Data, address: String, now: Date, maximumAge: TimeInterval?) -> BudsBatterySnapshot? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isCurrent(address: address, now: now, maximumAge: maximumAge) else { return nil }
        return value
    }
    /// Apply the same freshness rules to in-memory readings and decoded files.
    /// HUD callers can supply snapshots directly, bypassing `decode`.
    func isCurrent(address: String, now: Date = Date(), maximumAge: TimeInterval? = 300) -> Bool {
        isFor(address: address, now: now)
            && (maximumAge.map { $0.isFinite && $0 >= 0 && now.timeIntervalSince1970 - observedAt <= $0 } ?? true)
            && [left, right, casePercent].allSatisfy { $0 == nil || (0...100).contains($0!) }
    }
    func isFor(address: String, now: Date = Date()) -> Bool {
        Self.normalize(self.address) == Self.normalize(address) && Self.normalize(address).count == 12
            && observedAt.isFinite && observedAt >= 0 && now.timeIntervalSince1970 - observedAt >= -5
    }
    /// Public panel contract intentionally excludes address, icon and model IDs.
    var panelFields: [String: Any] {
        func percent(_ value: Int?) -> Any {
            guard let value, (0...100).contains(value) else { return NSNull() }
            return value
        }
        return ["left": percent(left), "right": percent(right), "case": percent(casePercent),
            "observed_at": observedAt.isFinite && observedAt >= 0
                ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: observedAt)) as Any : NSNull()]
    }
    static func normalize(_ address: String) -> String { address.lowercased().filter(\.isHexDigit) }
    /// Shared by the live HUD's first frame and subsequent updates. Invalid,
    /// expired and empty readings cannot hide a useful native observation, and
    /// an older file cannot replace a newer in-memory value.
    static func newestCurrent(_ candidates: [BudsBatterySnapshot?], address: String,
                              now: Date = Date()) -> BudsBatterySnapshot? {
        candidates.compactMap { $0 }
            .filter { $0.isCurrent(address: address, now: now)
                && [$0.left, $0.right, $0.casePercent].contains(where: { $0 != nil }) }
            .max { $0.observedAt < $1.observedAt }
    }
    var iconPrefix: String? {
        guard let icon, icon.range(of: "^[A-Za-z][A-Za-z0-9]{1,63}\\z", options: .regularExpression) != nil else { return nil }
        return icon
    }
}
