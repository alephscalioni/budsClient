import Foundation
import CryptoKit

/// Experimental Windows Cloud wire compatibility. No Windows binary is run.
enum SamsungCloudProtocol {
    static let appID = "zwxnfb7qyh"
    enum Failure: Error { case malformed, missingAccount, rejected(Int, String) }

    struct Directory {
        let api: URL
        let play: URL
        private init(api: URL, play: URL) { self.api = api; self.play = play }
        static func decode(_ data: Data) throws -> Directory {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw Failure.malformed }
            func trusted(_ value: String?) throws -> URL {
                guard let value = value, let parts = URLComponents(string: value), parts.scheme == "https",
                      let host = parts.host, host == host.lowercased(),
                      ["samsungcloud.com", "samsungcloudplatform.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                      parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
                      parts.path.isEmpty || parts.path == "/", let url = parts.url else { throw Failure.malformed }
                return url
            }
            return try Directory(api: trusted(object["default"]), play: trusted(object["play"]))
        }
    }

    struct Profile {
        let installationID: String
        // Explicit protocol compatibility profile. This is not observed Mac hardware.
        let model = "960XGL"
        let osType = "win"
        let osVersion = "10"
        let platformVersion = "10.0.26100.0"
        var cdid: String { Data(SHA256.hash(data: Data((appID + ":" + installationID).utf8))).map { String(format: "%02x", $0) }.joined() }
        var userAgent: String { "960XGL; Samsung; GalaxyBudsAccountResearch=0.1; windows sdk=10.0.26100.0; sw=10; [SCWSDK]SCWindowsSDK_PAM=3.1.5.0;" }

        func registrationRequest(directory: Directory, accessToken: String, userID: String, now: Date = Date()) throws -> URLRequest {
            guard installationID.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil,
                  !accessToken.isEmpty, accessToken.count <= 16384, !accessToken.contains(where: \.isNewline),
                  !userID.isEmpty, userID.count <= 512, !userID.contains(where: \.isNewline) else { throw Failure.malformed }
            var url = URLComponents(url: directory.play.appendingPathComponent("identity/v2/user/register"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "deviceCurrentTime", value: String(Int64(now.timeIntervalSince1970 * 1000)))]
            var request = URLRequest(url: url.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(appID, forHTTPHeaderField: "x-sc-app-id")
            request.setValue(cdid, forHTTPHeaderField: "x-sc-cdid")
            request.setValue("GBC-" + installationID, forHTTPHeaderField: "x-sc-serial")
            request.setValue(accessToken, forHTTPHeaderField: "x-sc-access-token")
            request.setValue(userID, forHTTPHeaderField: "x-sc-uid")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "app": ["version": "2.2.5.0", "sdkVersion": "3.1.5.0", "e2eeType": "non"],
                "device": ["osType": osType, "osVersion": osVersion, "platformVersion": platformVersion,
                    "type": "pc", "countryCode": "BRA", "modelName": model, "modelCode": model,
                    "alias": "Galaxy Buds no Mac (compatibilidade)", "osUserId": "macos-" + installationID]
            ], options: [.sortedKeys])
            return request
        }
    }

    static func discover(profile: Profile) async throws -> Directory {
        var request = URLRequest(url: URL(string: "https://ers.samsungcloud.com/ers/v1/endpoints")!)
        for (key, value) in ["x-sc-app-id": appID, "x-sc-device-model": profile.model,
            "x-sc-os-type": profile.osType, "x-sc-os-version": profile.osVersion, "x-sc-device-cc": "BRA"] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try Directory.decode(await perform(request))
    }

    /// A05/A21/A25: certificate_v1 uses ERS's API/default domain and the
    /// existing Cloud user token. No legacy audience or Account token exchange.
    /// Runtime only; called by an explicit account action, never at startup.
    @MainActor
    static func prepareCertificates(account: [String: Any],
                                    action: SamsungCloudCertificateEnrollment.Action = .retrieve,
                                    identity: SamsungCloudCertificate.LocalIdentity? = nil,
                                    transport: @escaping SamsungCloudCertificateEnrollment.Transport = certificateHTTP,
                                    vault: ((SamsungCloudCertificate.Session) -> SamsungCloudCertificateVault)? = nil) async -> SamsungCloudCertificateEnrollment.Result {
        typealias C = SamsungCloudCertificate
        var stage: SamsungCloudCertificateEnrollment.Stage? = nil
        var httpStatus: Int?
        var serviceCode: String?
        do {
            let session = try C.Session.account(account)
            let profile = try certificateProfile(account)
            // ERS uses the registered common Cloud context. No token exchange,
            // feature-specific client guess, redirects or legacy raw-token headers.
            stage = .ers
            let (data, status) = try await transport(certificateDirectoryRequest(profile: profile))
            httpStatus = status
            guard status == 200 else {
                serviceCode = SamsungCloudCertificateEnrollment.serviceCode(data)
                throw [401,403].contains(status) ? C.Failure.authRejected : C.Failure.serverRejected
            }
            let directory = try Directory.decode(data)
            let enrollment = SamsungCloudCertificateEnrollment(session: session,
                context: C.Context(directory: directory, userAgent: profile.userAgent),
                vault: vault?(session) ?? SamsungCloudCertificateKeychain(session: session), transport: transport)
            return await enrollment.prepare(action, identity: identity)
        } catch {
            let blocker: C.Failure
            if let failure = error as? C.Failure { blocker = failure }
            else if case Failure.malformed = error { blocker = .malformed }
            else { blocker = .transportFailure }
            return .init(diagnostics: certificateAccountDiagnostics(account),
                blocker: blocker,
                httpStatus: httpStatus, stage: stage, serviceCode: serviceCode, identityMode: identity?.mode)
        }
    }

    private static func certificateProfile(_ account: [String: Any]) throws -> Profile {
        guard let installation = account["installation_id"] as? String,
              installation.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil else {
            throw SamsungCloudCertificate.Failure.missingAccount
        }
        return Profile(installationID: installation)
    }

    /// Explicit account.enroll_continuity only. Uses this installation's new
    /// application identity, NOT a macOS controller IRK or a copied phone record.
    @MainActor
    static func enrollContinuity(account: [String: Any],
        address: @escaping SamsungContinuityLocalIdentity.AddressProvider = SamsungContinuityLocalIdentityKeychain.ownClassicAddress,
        identityStore: SamsungContinuityIdentityStore = SamsungContinuityLocalIdentityKeychain(),
        random: @escaping SamsungContinuityLocalIdentity.RandomProvider = SamsungContinuityLocalIdentityKeychain.randomIdentity,
        name: () -> String = { Host.current().localizedName ?? "Mac" },
        transport: @escaping SamsungCloudCertificateEnrollment.Transport = certificateHTTP,
        vault: ((SamsungCloudCertificate.Session) -> SamsungCloudCertificateVault)? = nil) async -> SamsungCloudCertificateEnrollment.Result {
        typealias C = SamsungCloudCertificate
        do {
            let session = try C.Session.account(account), profile = try certificateProfile(account)
            let provider = try SamsungContinuityLocalIdentity(session: session, installationID: profile.installationID,
                address: address, store: identityStore, random: random)
            let identity = try provider.load(create: true)
            let hostName = name()
            // 960XGL is the EXISTING registered Windows compatibility profile,
            // not an assertion about this Mac's actual hardware model.
            let device = C.Device(model: profile.model, name: hostName.isEmpty ? "Mac" : hostName, type: "pc", identity: identity)
            try device.validate()
            var result = await prepareCertificates(account: account, action: .enroll(device), identity: identity,
                                                    transport: transport, vault: vault)
            result.identityMode = .outgoingClassicApplication
            return result
        } catch {
            return .init(diagnostics: certificateAccountDiagnostics(account), blocker: (error as? C.Failure) ?? .continuityIdentityUnavailable,
                         identityMode: .outgoingClassicApplication)
        }
    }

    /// On-demand protected read for the parent peer transport. No HTTP, identity
    /// creation, account mutation or UI polling. Raw keys never enter public JSON.
    static func loadPreparedPeerMaterial(account: [String: Any],
        address: @escaping SamsungContinuityLocalIdentity.AddressProvider = SamsungContinuityLocalIdentityKeychain.ownClassicAddress,
        identityStore: SamsungContinuityIdentityStore = SamsungContinuityLocalIdentityKeychain(),
        vault: ((SamsungCloudCertificate.Session) -> SamsungCloudCertificateVault)? = nil,
        now: Date = Date()) throws -> SamsungCloudCertificate.PeerMaterial {
        let session = try SamsungCloudCertificate.Session.account(account), profile = try certificateProfile(account)
        let provider = try SamsungContinuityLocalIdentity(session: session, installationID: profile.installationID,
            address: address, store: identityStore, random: { throw SamsungCloudCertificate.Failure.continuityIdentityUnavailable })
        let identity = try provider.load(create: false)
        return try SamsungCloudCertificate.preparedPeerMaterial(session: session, identity: identity,
            vault: vault?(session) ?? SamsungCloudCertificateKeychain(session: session), now: now)
    }

    static func certificateAccountDiagnostics(_ account: [String: Any]) -> SamsungCloudCertificate.Diagnostics {
        let authenticated = (account["token_response"] as? [String: Any])?["access_token"] as? String
        let id = (account["cloud_registration"] as? [String: Any])?["dvcId"] as? String ?? ""
        let registered = (try? SamsungCloudCertificate.text(id)) != nil
        return .init(accountAuthenticated: !(authenticated ?? "").isEmpty, cloudIdentityRegistered: registered)
    }

    static func certificateDirectoryRequest(profile: Profile) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://ers.samsungcloud.com/ers/v1/endpoints")!)
        for (key, value) in ["x-sc-app-id": appID, "x-sc-device-model": profile.model,
            "x-sc-os-type": profile.osType, "x-sc-os-version": profile.osVersion,
            "x-sc-device-cc": "BRA", "User-Agent": profile.userAgent] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func certificateHTTP(_ input: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = input; request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url,
              data.count <= 2_000_000 else { throw SamsungCloudCertificate.Failure.malformed }
        // Do not propagate response bodies or server diagnostics containing keys.
        return (data, http.statusCode)
    }

    static func register(account: [String: Any], profile: Profile, directory: Directory) async throws -> Data {
        guard let response = account["token_response"] as? [String: Any],
              let token = response["access_token"] as? String,
              let userID = (response["userId"] ?? response["user_id"]) as? String else { throw Failure.missingAccount }
        let request = try profile.registrationRequest(directory: directory, accessToken: token, userID: userID)
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["dvcId"] as? String, !id.isEmpty,
              let tokens = object["tokens"] as? [[String: Any]],
              tokens.contains(where: { ($0["type"] as? String) == "user" && !($0["accessToken"] as? String ?? "").isEmpty }) else { throw Failure.malformed }
        return data
    }

    /// Read-only DAPI v3 experiment. The table name is recovered from the
    /// Bluetooth client's legacy path; its availability in v3 is not assumed.
    static func bluetoothDocumentsRequest(directory: Directory, pamToken: String, profile: Profile) throws -> URLRequest {
        guard !pamToken.isEmpty, pamToken.count <= 16384,
              !pamToken.contains(where: \.isNewline) else { throw Failure.malformed }
        var url = URLComponents(url: directory.api.appendingPathComponent("data/v3/com.samsung.bluetooth.device_sync/documents"), resolvingAgainstBaseURL: false)!
        // CommonDapiQuery defaults recovered from the Cloud Platform SDK.
        url.queryItems = [.init(name: "limit", value: "1000"), .init(name: "schemaRevision", value: "0")]
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + pamToken, forHTTPHeaderField: "Authorization")
        return request
    }

    struct BluetoothDocuments {
        let data: Data
        let count: Int
        let encryptedCount: Int
        let hasNext: Bool
        static func decode(_ data: Data) throws -> BluetoothDocuments {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let documents = object["documents"] as? [[String: Any]],
                  let hasNext = object["hasNext"] as? Bool,
                  documents.count <= 1000,
                  documents.allSatisfy({ $0["data"] is [String: Any] && $0["needToDecrypt"] is Bool }) else { throw Failure.malformed }
            return BluetoothDocuments(data: data, count: documents.count,
                encryptedCount: documents.filter { ($0["needToDecrypt"] as? Bool) == true }.count, hasNext: hasNext)
        }
    }

    static func readProfileImageDocuments(account: [String: Any]) async throws -> Data {
        guard let installation = account["installation_id"] as? String,
              let registration = account["cloud_registration"] as? [String: Any],
              let tokens = registration["tokens"] as? [[String: Any]],
              let token = tokens.first(where: { ($0["type"] as? String) == "user" })?["accessToken"] as? String else { throw Failure.missingAccount }
        let profile = Profile(installationID: installation)
        let directory = try await discover(profile: profile)
        var request = try bluetoothDocumentsRequest(directory: directory, pamToken: token, profile: profile)
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.path = "/data/v3/com.samsung.account.profile_image/documents"
        request.url = parts.url
        return try await perform(request)
    }

    static func readBluetoothDocuments(account: [String: Any], directory: Directory, profile: Profile) async throws -> BluetoothDocuments {
        guard let registration = account["cloud_registration"] as? [String: Any],
              let tokens = registration["tokens"] as? [[String: Any]],
              let token = tokens.first(where: { ($0["type"] as? String) == "user" })?["accessToken"] as? String else { throw Failure.missingAccount }
        let request = try bluetoothDocumentsRequest(directory: directory, pamToken: token, profile: profile)
        return try BluetoothDocuments.decode(await perform(request))
    }

    /// Recovered legacy request builder only. Its e2akaegdfg device activation is
    /// distinct from PAM enrollment; a PAM dvcId must not be substituted here.
    static func legacyBluetoothRequest(directory: Directory, accountToken: String, userID: String,
                                       activatedLegacyDeviceID: String, profile: Profile) throws -> URLRequest {
        guard !accountToken.isEmpty, !userID.isEmpty, !activatedLegacyDeviceID.isEmpty,
              ![accountToken, userID, activatedLegacyDeviceID].contains(where: { $0.contains(where: \.isNewline) }) else { throw Failure.malformed }
        var url = URLComponents(url: directory.api.appendingPathComponent("data/v2/com.samsung.bluetooth.device_sync"), resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "table_ver", value: "1"), .init(name: "include_deleted_items", value: "false")]
        var request = URLRequest(url: url.url!)
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("e2akaegdfg", forHTTPHeaderField: "X-SC-APP-ID")
        request.setValue(accountToken, forHTTPHeaderField: "X-SC-ACCESS-TOKEN")
        request.setValue(userID, forHTTPHeaderField: "X-SC-UID")
        request.setValue(activatedLegacyDeviceID, forHTTPHeaderField: "X-SC-DVC-ID")
        return request
    }

    private static func perform(_ input: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = input; request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url, data.count <= 2_000_000 else { throw Failure.malformed }
        guard (200...299).contains(http.statusCode) else {
            throw Failure.rejected(http.statusCode, serverErrorCode(from: data))
        }
        return data
    }

    /// Error codes only, including nested Cloud error envelopes. Never returns a
    /// message/body that could echo an authorization header or account identifier.
    static func serverErrorCode(from data: Data) -> String {
        guard data.count <= 2_000_000, let root = try? JSONSerialization.jsonObject(with: data) else { return "" }
        var codes: [String] = []
        func find(_ value: Any, depth: Int) {
            guard depth <= 4, codes.count < 8 else { return }
            if let object = value as? [String: Any] {
                for key in ["rcode", "errorCode", "error_code", "resultCode", "code", "error"] {
                    let candidate = object[key] as? String ?? (object[key] as? NSNumber)?.stringValue ?? ""
                    if candidate.range(of: "^[A-Za-z0-9_.-]{1,100}\\z", options: .regularExpression) != nil,
                       !codes.contains(candidate), codes.count < 8 { codes.append(candidate) }
                }
                // Classify selected server wording without ever retaining the
                // raw message, which could contain a token or account ID.
                for key in ["message", "errorMessage", "error_description", "errorDesc"] {
                    guard let message = object[key] as? String else { continue }
                    let text = message.lowercased()
                    let classification: String?
                    if text.contains("token") && text.contains("expir") { classification = "TOKEN_EXPIRED" }
                    else if text.contains("token") && text.contains("invalid") { classification = "TOKEN_INVALID" }
                    else if text.contains("app") && (text.contains("invalid") || text.contains("mismatch")) { classification = "APP_INVALID_OR_MISMATCH" }
                    else { classification = nil }
                    if let classification, !codes.contains(classification), codes.count < 8 { codes.append(classification) }
                }
                for key in ["error", "result", "header", "errors", "response"] {
                    if let child = object[key] { find(child, depth: depth + 1) }
                }
            } else if let array = value as? [Any] {
                for child in array.prefix(16) { find(child, depth: depth + 1) }
            }
        }
        find(root, depth: 0)
        return codes.joined(separator: " / ")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
