import Foundation
import Security
import CryptoKit

/// Static Android contract: REPORT §§6–7, PROTOCOL §9, A05/A06/A21/A25.
/// Local validation is deliberately stricter than Gson's nullable models.
enum SamsungCloudCertificate {
    static let feature = "certificate_v1"
    static let keychainID = "KC01"
    enum Failure: String, Error { // Fixed codes only; never include server bodies, IDs or secrets.
        case malformed, missingAccount, missingCloudIdentity, missingCloudToken
        case missingBluetoothIdentity, missingCoherentIRK, missingDeviceMetadata
        case explicitConsentRequired, privateKeyUnavailable, existingCertificateWithoutOwnedKey
        case invalidCSR, invalidCertificate, keyMismatch, expired, revisionRollback, peerRosterMismatch
        case authRejected, unsupported, serverRejected, transportFailure, keychainUnavailable
        case continuityIdentityMismatch, continuityIdentityUnavailable
    }

    /// Avoid reflection/debug descriptions exposing token or provisioned material.
    protocol Redacted: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {}
    struct Session: Redacted {
        let deviceID: String
        let storageID: String
        fileprivate let bearer: String
        static func account(_ account: [String: Any]) throws -> Session {
            guard let response = account["token_response"] as? [String: Any],
                  let uid = (response["userId"] ?? response["user_id"]) as? String else { throw Failure.missingAccount }
            try text(uid)
            guard let registration = account["cloud_registration"] as? [String: Any],
                  let id = registration["dvcId"] as? String else { throw Failure.missingCloudIdentity }
            try text(id)
            guard let tokens = registration["tokens"] as? [[String: Any]],
                  let token = tokens.first(where: { ($0["type"] as? String) == "user" })?["accessToken"] as? String else { throw Failure.missingCloudToken }
            return try Session(deviceID: id, accountID: uid, cloudUserToken: token)
        }
        init(deviceID: String, accountID: String, cloudUserToken: String) throws {
            try text(deviceID); try text(accountID)
            let token = cloudUserToken.hasPrefix("Bearer ") ? String(cloudUserToken.dropFirst(7)) : cloudUserToken
            guard token.range(of: "^[A-Za-z0-9._~+/=-]{1,16384}\\z", options: .regularExpression) != nil else { throw Failure.missingCloudToken }
            self.deviceID = deviceID
            self.bearer = "Bearer " + token
            // Length framing prevents account/device concatenation collisions.
            self.storageID = SHA256.hash(data: Data("\(accountID.utf8.count):\(accountID)\(deviceID.utf8.count):\(deviceID)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    enum IdentityMode: String, Codable {
        case controllerCoherent = "controller_coherent_irk"
        case outgoingClassicApplication = "outgoing_classic_application"
    }
    /// Provenance is explicit: application continuity identity is never a BLE
    /// controller IRK and must never be used for advertising or RPA resolution.
    struct LocalIdentity: Redacted {
        let address: String
        fileprivate let irk: Data
        let mode: IdentityMode
        var outgoingOnly: Bool { mode == .outgoingClassicApplication }
        init(verifiedLocalBluetoothAddress: String, controllerCoherentIRK: Data) throws {
            guard validAddress(verifiedLocalBluetoothAddress) else { throw Failure.missingBluetoothIdentity }
            guard controllerCoherentIRK.count == 16 else { throw Failure.missingCoherentIRK }
            address = verifiedLocalBluetoothAddress.uppercased(); irk = controllerCoherentIRK
            mode = .controllerCoherent
        }
        private init(address: String, applicationKey: Data) {
            self.address = address; irk = applicationKey; mode = .outgoingClassicApplication
        }
        static func outgoingClassicApplication(ownClassicAddress: String, applicationIdentity: Data) throws -> LocalIdentity {
            guard validAddress(ownClassicAddress), let first = UInt8(ownClassicAddress.prefix(2), radix: 16), first & 1 == 0 else { throw Failure.missingBluetoothIdentity }
            guard applicationIdentity.count == 16, applicationIdentity.contains(where: { $0 != 0 }) else {
                throw Failure.continuityIdentityUnavailable
            }
            return LocalIdentity(address: ownClassicAddress.uppercased(), applicationKey: applicationIdentity)
        }
    }

    struct Device {
        let model: String
        let name: String
        let type: String
        let identity: LocalIdentity
        var body: [String: String] {
            ["deviceModel": model, "deviceName": name, "deviceType": type,
             "btAddr": identity.address, "irk": identity.irk.base64EncodedString()]
        }
        func validate() throws {
            do { try text(model); try text(name); try text(type) }
            catch { throw Failure.missingDeviceMetadata }
        }
    }

    struct Context {
        let directory: SamsungCloudProtocol.Directory
        let userAgent: String // Actual registered SDK context; no guessed audience.
        var network = "unknown" // A21 networkHeader: wifi/mobile/unknown.
        var invoker: String? = nil // Already serialized by the caller; optional.
        func request(session: Session, method: String, device: Device? = nil,
                     csr: Data? = nil, revision: Int? = nil, patch: Patch? = nil) throws -> URLRequest {
            try text(userAgent, maximum: 2048)
            guard ["wifi", "unknown"].contains(network) else { throw Failure.malformed }
            guard ["GET", "POST", "PATCH"].contains(method),
                  revision == nil || (revision! > 0 && revision! <= Int(Int32.max)),
                  method == "GET" || revision == nil else { throw Failure.malformed }
            var parts = URLComponents(url: directory.api, resolvingAgainstBaseURL: false)!
            parts.path = method == "PATCH" ? "/ca/v1/device" : "/ca/v1/certificates"
            parts.queryItems = [.init(name: "kcid", value: keychainID)]
            if let revision { parts.queryItems!.append(.init(name: "revision", value: String(revision))) }
            var request = URLRequest(url: parts.url!)
            request.httpMethod = method
            request.setValue(session.bearer, forHTTPHeaderField: "Authorization")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(network, forHTTPHeaderField: "x-sc-network")
            if let invoker { try text(invoker, maximum: 2048); request.setValue(invoker, forHTTPHeaderField: "x-sc-agent-invoker") }
            if method == "POST" {
                guard let device, let csr, patch == nil else { throw Failure.malformed }
                try device.validate(); try SamsungCloudCertificateDER.validateCSR(csr, deviceID: session.deviceID)
                request.httpBody = try JSONSerialization.data(withJSONObject: ["csr": csr.base64EncodedString(), "deviceInfo": device.body], options: [.sortedKeys])
            } else if method == "PATCH" {
                guard let patch, device == nil, csr == nil else { throw Failure.malformed }
                request.httpBody = try JSONSerialization.data(withJSONObject: patch.body(), options: [.sortedKeys])
            } else if device != nil || csr != nil || patch != nil { throw Failure.malformed }
            if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return request
        }
    }
    enum Patch {
        case deviceName(String), bluetoothAddress(LocalIdentity), irk(LocalIdentity)
        func body() throws -> [String: String] {
            switch self {
            case .deviceName(let name): try text(name); return ["deviceName": name]
            // CertificatePatchDeviceJobImpl uses ScspCertificate.BT_ADDRESS,
            // whose literal is btAddress (POST/response use btAddr).
            case .bluetoothAddress(let identity): return ["btAddress": identity.address]
            case .irk(let identity): return ["irk": identity.irk.base64EncodedString()]
            }
        }
    }

    struct UserKey: Codable, Redacted {
        fileprivate let aes128Key: String
        fileprivate let aes256Key: String
        let expireTime: Int64
    }
    struct Peer: Codable, Redacted {
        let dvcId: String
        let deviceModel: String?
        let deviceName: String?
        let deviceType: String?
        let btAddr: String?
        fileprivate let irk: String?
        fileprivate let certificate: String?
        let keyExpireTime: Int64?
        let createTime: Int64?
        // Per-device AES keys deliberately aren't retained (A06/o.java).
    }
    struct Material: Codable, Redacted {
        fileprivate let userFingerprint: String
        fileprivate let userCertificate: String
        fileprivate let serverCertificate: String?
        fileprivate let userAesKeyList: [UserKey]
        let deviceInfoList: [Peer]
        let revision: Int

        static func decode(_ data: Data, now: Date, minimumRevision: Int? = nil) throws -> Material {
            SamsungCertificateSchemaDiagnostics.begin(data)
            guard data.count <= 2_000_000 else { throw Failure.malformed }
            let value: Material
            do { value = try JSONDecoder().decode(Material.self, from: data) }
            catch { SamsungCertificateSchemaDiagnostics.decodingFailure(error); throw Failure.malformed } // No raw error context.
            // A06 also declares per-device AES fields. Validate supplied fields
            // before discarding them; never copy them into persisted roster data.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let peers = root["deviceInfoList"] as? [[String: Any]] else { throw Failure.malformed }
            SamsungCertificateSchemaDiagnostics.stage(.peerAES)
            for peer in peers {
                for (name, length) in [("aes128Key", 16), ("aes256Key", 32)] {
                    if let raw = peer[name], !(raw is NSNull) {
                        guard let value = raw as? String, try base64(value).count == length else { throw Failure.malformed }
                    }
                }
            }
            SamsungCertificateSchemaDiagnostics.stage(.revisionFingerprintCardinality)
            guard value.revision >= 0, value.revision <= Int(Int32.max),
                  value.userFingerprint.range(of: "^(?:[A-Fa-f0-9]{2}){1,256}\\z", options: .regularExpression) != nil,
                  !value.userAesKeyList.isEmpty, value.userAesKeyList.count <= 128,
                  value.deviceInfoList.count <= 1000 else { throw Failure.malformed }
            if let minimumRevision, value.revision < minimumRevision { throw Failure.revisionRollback }
            SamsungCertificateSchemaDiagnostics.stage(.certificates)
            _ = try certificate(value.userCertificate, now: now)
            if let server = value.serverCertificate, !server.isEmpty { _ = try certificate(server, now: now) }
            let milliseconds = now.timeIntervalSince1970 * 1000
            SamsungCertificateSchemaDiagnostics.stage(.userKeys)
            var expiries = Set<Int64>()
            for key in value.userAesKeyList {
                guard try base64(key.aes128Key).count == 16, try base64(key.aes256Key).count == 32,
                      key.expireTime > 0, expiries.insert(key.expireTime).inserted else { throw Failure.malformed }
            }
            guard value.userAesKeyList.contains(where: { Double($0.expireTime) > milliseconds }) else { throw Failure.expired }
            SamsungCertificateSchemaDiagnostics.stage(.peers)
            var ids = Set<String>()
            for peer in value.deviceInfoList {
                SamsungCertificateSchemaDiagnostics.stage(.peerIdentity)
                try text(peer.dvcId)
                for field in [peer.deviceModel, peer.deviceName, peer.deviceType] {
                    if let field, !field.isEmpty { try text(field) }
                }
                guard ids.insert(peer.dvcId).inserted else { throw Failure.malformed }
                SamsungCertificateSchemaDiagnostics.stage(.peerAddress)
                if let address = peer.btAddr, !address.isEmpty, !validAddress(address) { throw Failure.malformed }
                // Android consumer rejects >16, not universally !=16. Short
                // remote IRKs remain schema-valid, but cannot prove local radio readiness.
                SamsungCertificateSchemaDiagnostics.stage(.peerIRK)
                // A06/i9.r admits remote members individually. An unsupported
                // remote IRK cannot invalidate the entire authenticated dataset.
                // The typed phone loader below excludes invalid/empty/>16
                // records; containsThisDevice still requires exact own 16 bytes.
                // No remote identity becomes trusted merely by being persisted.
                SamsungCertificateSchemaDiagnostics.stage(.peerCertificate)
                if let cert = peer.certificate, !cert.isEmpty {
                    // An old remote device may have an expired certificate.
                    // Only the owned device cert governs local key readiness.
                    _ = try SamsungCloudCertificateDER.certificate(base64(cert), now: now, requireCurrentValidity: false)
                }
                SamsungCertificateSchemaDiagnostics.stage(.peerExpiry)
                if let expiry = peer.keyExpireTime, expiry <= 0 { throw Failure.malformed }
                SamsungCertificateSchemaDiagnostics.stage(.peerCreation)
                if let created = peer.createTime, created < 0 { throw Failure.malformed }
                if let created = peer.createTime, let expiry = peer.keyExpireTime, created >= expiry { throw Failure.malformed }
            }
            SamsungCertificateSchemaDiagnostics.stage(.valid)
            return value
        }

        func containsThisDevice(_ id: String, identity: LocalIdentity?) -> Bool {
            guard let identity else { return false }
            return deviceInfoList.contains { $0.dvcId == id && $0.btAddr?.uppercased() == identity.address &&
                $0.irk.flatMap { Data(base64Encoded: $0) } == identity.irk }
        }
        func validateOwnedKey(_ publicKey: Data?, deviceID: String, now: Date) throws {
            guard let publicKey else { throw Failure.existingCertificateWithoutOwnedKey }
            guard let peer = deviceInfoList.first(where: { $0.dvcId == deviceID }),
                  let cert = peer.certificate, let expiry = peer.keyExpireTime else { throw Failure.invalidCertificate }
            guard Double(expiry) > now.timeIntervalSince1970 * 1000 else { throw Failure.expired }
            let certificate = try SamsungCloudCertificate.certificate(cert, now: now)
            guard let key = SecCertificateCopyKey(certificate),
                  let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data?, bytes == publicKey else { throw Failure.keyMismatch }
        }
        func encodedForKeychain() throws -> Data { try JSONEncoder().encode(self) }
    }

    /// Internal, typed handoff only. Never Codable, embedded JSON or diagnostics.
    struct PeerMaterial: Redacted {
        let ownClassicAddress: String
        let accountKey: AccountAES256Key
        let revision: Int
        let phones: [PhonePeer]
        let identityMode: IdentityMode
        var accountFingerprint: AccountFingerprint? = nil
        var outgoingOnly: Bool { identityMode == .outgoingClassicApplication }
    }
    /// Provisioned certificate HEX bytes, never a base64/identifier derivation.
    struct AccountFingerprint: Redacted {
        let bytes: Data
        fileprivate init(validatedHex: String) throws {
            let hex = Array(validatedHex.utf8)
            guard !hex.isEmpty, hex.count <= 512, hex.count % 2 == 0 else { throw Failure.malformed }
            func nibble(_ c: UInt8) -> UInt8? {
                switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil }
            }
            var decoded = Data()
            for i in stride(from: 0, to: hex.count, by: 2) {
                guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { throw Failure.malformed }
                decoded.append(hi << 4 | lo)
            }
            bytes = decoded
        }
    }
    struct AccountAES256Key: Redacted {
        let bytes: Data
        let expireTime: Int64
        fileprivate init(bytes: Data, expireTime: Int64) { self.bytes = bytes; self.expireTime = expireTime }
    }
    struct PhonePeer: Redacted {
        let address: String
        let name: String
        let model: String
    }
    static func preparedPeerMaterial(session: Session, identity: LocalIdentity,
                                     vault: SamsungCloudCertificateVault, now: Date = Date()) throws -> PeerMaterial {
        guard identity.mode == .outgoingClassicApplication else { throw Failure.continuityIdentityMismatch }
        guard let data = try vault.readMaterial() else { throw Failure.invalidCertificate }
        let material = try Material.decode(data, now: now)
        try material.validateOwnedKey(vault.publicKey(), deviceID: session.deviceID, now: now)
        guard material.containsThisDevice(session.deviceID, identity: identity) else { throw Failure.peerRosterMismatch }
        // Android scloud.keystore.h picks the FIRST unexpired entry, not max expiry.
        guard let active = material.userAesKeyList.first(where: { Double($0.expireTime) > now.timeIntervalSince1970 * 1000 }) else {
            throw Failure.expired
        }
        // MCFDS i9.r/da.c index identities by Classic address and replace older
        // registrations using server createTime. A phone may have several Cloud
        // registrations after resets; these are not separate Bluetooth targets.
        var groups: [String:[Peer]] = [:], order: [String] = []
        for peer in material.deviceInfoList {
            guard peer.dvcId != session.deviceID, peer.deviceType == "phone",
                  let address = peer.btAddr, validAddress(address), address.uppercased() != identity.address,
                  let irk = peer.irk, let irkData = Data(base64Encoded: irk), !irkData.isEmpty, irkData.count <= 16,
                  let name = peer.deviceName, (try? text(name)) != nil,
                  let model = peer.deviceModel, (try? text(model)) != nil else { continue }
            let canonical = address.uppercased()
            if groups[canonical] == nil { order.append(canonical) }
            groups[canonical, default:[]].append(peer)
        }
        let phones = order.compactMap { address -> PhonePeer? in
            guard let rows = groups[address], let newestTime = rows.map({ $0.createTime ?? 0 }).max() else { return nil }
            let newest = rows.filter { ($0.createTime ?? 0) == newestTime }
            guard let first = newest.first, let name = first.deviceName, let model = first.deviceModel else { return nil }
            // Equal-time conflicting identities remain quarantined. A unique
            // newer server record can supersede an older registration; zero is
            // not promoted into freshness and cannot break a conflicting tie.
            guard newest.allSatisfy({ $0.deviceModel == model && $0.irk.flatMap({Data(base64Encoded:$0)}) == first.irk.flatMap({Data(base64Encoded:$0)}) }) else { return nil }
            return PhonePeer(address:address,name:name,model:model)
        }
        return PeerMaterial(ownClassicAddress: identity.address,
            accountKey: AccountAES256Key(bytes: try base64(active.aes256Key), expireTime: active.expireTime),
            revision: material.revision, phones: phones, identityMode: identity.mode,
            accountFingerprint: try AccountFingerprint(validatedHex: material.userFingerprint))
    }

    struct Diagnostics {
        var accountAuthenticated = false
        var cloudIdentityRegistered = false
        var certificateKeychainReady = false
        var peerRosterContainsThisDevice = false
        // Only a completed peer handshake can ever assert this; this module cannot.
        var publicValues: [String: Bool] {
            ["account_authenticated": accountAuthenticated, "cloud_identity_registered": cloudIdentityRegistered,
             "certificate_keychain_ready": certificateKeychainReady,
             "peer_roster_contains_this_device": peerRosterContainsThisDevice, "peer_authenticated": false]
        }
    }

    static func text(_ value: String, maximum: Int = 512) throws {
        guard !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Failure.malformed }
    }
    static func validAddress(_ value: String) -> Bool {
        value.range(of: "^(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}\\z", options: .regularExpression) != nil &&
            value != "00:00:00:00:00:00" && value.uppercased() != "FF:FF:FF:FF:FF:FF" && value != "02:00:00:00:00:00"
    }
    fileprivate static func base64(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= 100_000, let bytes = Data(base64Encoded: value),
              bytes.base64EncodedString() == value else { throw Failure.malformed }
        return bytes
    }
    private static func certificate(_ value: String, now: Date) throws -> SecCertificate {
        try SamsungCloudCertificateDER.certificate(base64(value), now: now)
    }
}

extension SamsungCloudCertificate.Redacted {
    var description: String { "[certificate material redacted]" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(reflecting: description) }
}
