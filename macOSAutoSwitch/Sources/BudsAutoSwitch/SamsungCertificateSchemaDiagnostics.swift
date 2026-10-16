import Foundation

/// Closed, value-free schema diagnostics. Never retains a response, identities,
/// certificates, addresses, fingerprint, key bytes, tokens, or error descriptions.
enum SamsungCertificateSchemaDiagnostics {
    enum Stage: String { case json, peerAES, revisionFingerprintCardinality, certificates, userKeys, peers, peerIdentity, peerAddress, peerIRK, peerCertificate, peerExpiry, peerCreation, valid }
    private final class Storage { let lock = NSLock(); var fields: [String:Any] = [:] }
    private static let storage = Storage()
    private static let names: Set<String> = ["userFingerprint", "userCertificate", "serverCertificate", "userAesKeyList", "deviceInfoList", "revision", "aes128Key", "aes256Key", "expireTime", "dvcId", "deviceModel", "deviceName", "deviceType", "btAddr", "irk", "certificate", "keyExpireTime", "createTime", "data", "result", "certificateInfo", "code", "errorCode", "message"]
    static var snapshot: [String:Any] { storage.lock.lock(); defer {storage.lock.unlock()}; return storage.fields }
    static func begin(_ data: Data) {
        var out: [String:Any] = ["stage":Stage.json.rawValue,"body_bytes":min(data.count,2_000_001)]
        if data.count <= 2_000_000, let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            out["known_fields"] = root.filter { names.contains($0.key) }.mapValues { shape($0) }
            out["unknown_field_count"] = min(root.keys.filter { !names.contains($0) }.count,1024)
        }
        storage.lock.lock(); storage.fields = out; storage.lock.unlock()
    }
    private static func shape(_ value: Any) -> [String:Any] {
        if value is NSNull { return ["type":"null"] }
        if let text=value as? String {
            return ["type":"string","length":min(text.utf8.count,2_000_001),
                    "canonical_base64":Data(base64Encoded:text).map { $0.base64EncodedString()==text } ?? false,
                    "base64_bytes":Data(base64Encoded:text).map { min($0.count,2_000_001) } ?? -1,
                    "hex_syntax":text.range(of:"^(?:[A-Fa-f0-9]{2})+$",options:.regularExpression) != nil,
                    "pem_certificate":text.hasPrefix("-----BEGIN CERTIFICATE-----")]
        }
        if let rows=value as? [[String:Any]] {
            return ["type":"array","count":min(rows.count,4096),"first_row":rows.first.map { $0.filter { names.contains($0.key) }.mapValues { shape($0) } } ?? [:]]
        }
        if let rows=value as? [Any] {return ["type":"array","count":min(rows.count,4096)]}
        if value is NSNumber {return ["type":"number"]}
        if let object=value as? [String:Any] {return ["type":"object","known_keys":object.keys.filter { names.contains($0) }.sorted(),"field_count":min(object.count,1024)]}
        return ["type":"other"]
    }
    static func stage(_ stage: Stage) { storage.lock.lock(); storage.fields["stage"] = stage.rawValue; storage.lock.unlock() }
    static func decodingFailure(_ error: Error) {
        let kind:String; let path:[CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key,let context): kind="missing_key";path=context.codingPath+[key]
        case DecodingError.typeMismatch(_,let context):kind="type_mismatch";path=context.codingPath
        case DecodingError.valueNotFound(_,let context):kind="null_value";path=context.codingPath
        case DecodingError.dataCorrupted(let context):kind="invalid_value";path=context.codingPath
        default:kind="other";path=[]
        }
        let safe=path.prefix(16).map { key in key.intValue.map { "index_\(max(0,min($0,4096)))" } ?? (names.contains(key.stringValue) ? key.stringValue : "other") }
        storage.lock.lock(); storage.fields["decoding_failure"] = kind;storage.fields["decoding_path"] = safe;storage.lock.unlock()
    }
}
