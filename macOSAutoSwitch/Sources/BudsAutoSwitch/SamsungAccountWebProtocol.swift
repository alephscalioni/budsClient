import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Experimental compatibility with the Buds3 Pro Android web SDK. Public client
/// identifiers are not secrets. This is not a newly registered Samsung client.
enum SamsungAccountWebProtocol {
    enum Failure: Error { case invalidEntryPoint, crypto, invalidCallback, inactive, invalidResponse, rejected(Int, String) }

    static let clientID = "7q62lro19z"
    static let callbackURL = URL(string: "sawebsdk://paran.buds.samsungaccount.auth")!

    /// WebAuthenticationBroker's callback is derived from the package identity,
    /// not from the app's Google sign-in callback. Package SIDs use seven LE
    /// UInt32 words from SHA256(lowercase PFN encoded as UTF-16LE).
    static let windowsPackageFamily = "SAMSUNGELECTRONICSCO.LTD.SamsungAccount_3c1yjt4zspk6g"
    // SAClient 1.26.6021.0 sets BrowserUrl.clientVer to this exact SDK version.
    static let windowsSDKVersion = "WINSDK2.25.109"
    static var windowsCallbackURL: URL {
        let name = Data(windowsPackageFamily.lowercased().utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        let digest = Array(SHA256.hash(data: name))
        let words = stride(from: 0, to: 28, by: 4).map { offset -> String in
            let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(digest[offset + $1]) << (8 * $1) }
            return String(value)
        }
        return URL(string: "ms-app://s-1-15-2-" + words.joined(separator: "-"))!
    }

    enum Client: Sendable {
        case buds, windowsAccount
        var id: String { self == .buds ? clientID : "yfrtglt53o" }
        var callback: URL { self == .buds ? callbackURL : windowsCallbackURL }
        var channel: String { self == .buds ? "ANDROIDSDK" : "WINSDK" }
    }

    struct EntryPoint {
        let signInURL: URL
        let challengeNumber: String
        let publicKey: SecKey
        let iterations: UInt32

        static func decode(_ data: Data, client: Client = .buds) throws -> EntryPoint {
            struct Reply: Decodable {
                let signInURI: String
                let chkDoNum: String
                let pkiPublicKey: String
                let pbeKySpcIters: String
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            guard reply.signInURI == "https://account.samsung.com/accounts/\(client.channel)/signInGate",
                  !reply.chkDoNum.isEmpty, reply.chkDoNum.utf8.count <= 1024,
                  let iterations = UInt32(reply.pbeKySpcIters), (1...100_000).contains(iterations),
                  reply.pkiPublicKey.utf8.count <= 8192,
                  let der = Data(base64Encoded: reply.pkiPublicKey),
                  let key = SecKeyCreateWithData(der as CFData,
                    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
                  SecKeyGetBlockSize(key) >= 128, SecKeyGetBlockSize(key) <= 512,
                  SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else { throw Failure.invalidEntryPoint }
            return EntryPoint(signInURL: URL(string: reply.signInURI)!, challengeNumber: reply.chkDoNum,
                              publicKey: key, iterations: iterations)
        }
    }

    /// A separate installation identity. Never copies the phone's identifier,
    /// Windows device IDs, account credentials or Bluetooth link keys.
    struct DeviceProfile {
        let installationID: String
        let country: String
        let systemVersion: String

        func parameters(attempt: SamsungAccountProtocol.Attempt, client: Client = .buds) throws -> [String: String] {
            guard installationID.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil,
                  country.range(of: "^[A-Z]{2}\\z", options: .regularExpression) != nil,
                  !systemVersion.isEmpty, systemVersion.count <= 64 else { throw Failure.invalidEntryPoint }
            // Explicit Windows wire compatibility profile, consistent with PAM
            // registration. These values do not describe the physical Mac.
            let windows = client == .windowsAccount
            var parameters = ["clientId": client.id, "state": attempt.state, "scope": "offline.access",
                "deviceType": "APP", "deviceModelID": windows ? "960XGL" : "Mac", "deviceUniqueID": "PCID:" + installationID,
                "devicePhysicalAddressText": installationID, "deviceOSVersion": windows ? "10.0.26100.0" : systemVersion,
                "competitorDeviceYNFlag": windows ? "N" : "Y", "redirect_uri": client.callback.absoluteString,
                "countryCode": country, "responseEncryptionYNFlag": "Y", "responseEncryptionType": "1",
                "code_challenge": attempt.challenge, "code_challenge_method": "S256",
                "replaceableClientConnectYN": "N",
                // The server interprets this as an SDK browser contract. The
                // actual UI is ASWebAuthenticationSession on macOS, not Chrome.
                "deviceInfo": windows ? "SAMSUNG|com.android.chrome" : "Apple|com.android.chrome"]
            if windows { parameters["clientVer"] = windowsSDKVersion }
            return parameters
        }
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.crypto }
        return Data(bytes)
    }

    static func deriveKey(challengeNumber: String, salt: Data, iterations: UInt32) throws -> Data {
        guard salt.count == 16, (1...100_000).contains(iterations) else { throw Failure.crypto }
        let password = Data(SHA256.hash(data: Data(challengeNumber.utf8))).base64EncodedString()
        var key = [UInt8](repeating: 0, count: 16)
        let result = password.withCString { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBuffer, password.utf8.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &key, key.count)
            }
        }
        guard result == kCCSuccess else { throw Failure.crypto }
        return Data(key)
    }

    static func encryptParameters(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16, data.count <= 32768 else { throw Failure.crypto }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                data.withUnsafeBytes { inputBuffer in
                    output.withUnsafeMutableBytes { outputBuffer in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress, inputBuffer.baseAddress, data.count,
                            outputBuffer.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.crypto }
        return Data(output.prefix(written))
    }

    static func authorizationURL(entry: EntryPoint, attempt: SamsungAccountProtocol.Attempt,
                                 profile: DeviceProfile, locale: String = "pt_BR", client: Client = .buds) throws -> URL {
        let parameters = try profile.parameters(attempt: attempt, client: client)
        let key = try deriveKey(challengeNumber: entry.challengeNumber, salt: randomBytes(16), iterations: entry.iterations)
        let iv = try randomBytes(16)
        let plain = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let encrypted = try encryptParameters(plain, key: key, iv: iv)
        // RSA encrypts Base64(key), not the raw AES key.
        guard let wrapped = SecKeyCreateEncryptedData(entry.publicKey, .rsaEncryptionPKCS1,
            Data(key.base64EncodedString().utf8) as CFData, nil) as Data? else { throw Failure.crypto }
        let envelope = try JSONSerialization.data(withJSONObject: ["chkDoNum": entry.challengeNumber,
            "svcEncParam": encrypted.base64EncodedString(), "svcEncKY": wrapped.base64EncodedString(),
            "svcEncIV": iv.map { String(format: "%02X", $0) }.joined()], options: [.sortedKeys])
        // Encode each value exactly once. '+' in Base64 must be escaped.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var url = URLComponents(url: entry.signInURL, resolvingAgainstBaseURL: false)!
        url.percentEncodedQuery = [("locale", locale), ("svcParam", envelope.base64EncodedString()), ("mode", "C")]
            .map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
        guard let result = url.url else { throw Failure.invalidEntryPoint }
        return result
    }

    actor PendingWebSignIn {
        private let attempt: SamsungAccountProtocol.Attempt
        private let deadline: ContinuousClock.Instant
        private let client: Client
        private let fallbackServers: SamsungAccountProtocol.Servers?
        private(set) var username: String?
        private(set) var fieldPresence: [String: Bool] = [:]
        private var active = true

        init(attempt: SamsungAccountProtocol.Attempt,
             client: Client = .buds, fallbackServers: SamsungAccountProtocol.Servers? = nil,
             deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(600))) {
            self.attempt = attempt; self.deadline = deadline; self.client = client; self.fallbackServers = fallbackServers
        }
        func cancel() { active = false }

        func consume(_ callback: URL) throws -> SamsungAccountProtocol.AuthorizedCode {
            guard active, ContinuousClock.now < deadline else { active = false; throw Failure.inactive }
            guard callback.absoluteString.utf8.count <= 65536,
                  let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  parts.scheme == client.callback.scheme, parts.host == client.callback.host, parts.path == client.callback.path,
                  parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
                  let items = parts.queryItems, items.count <= 24 else { throw Failure.invalidCallback }
            var fields: [String: String] = [:]
            for item in items {
                guard fields[item.name] == nil, let value = item.value else { throw Failure.invalidCallback }
                fields[item.name] = value
            }
            guard fields["result"] != "false", fields["error"] == nil,
                  let state = fields["state"], let code = fields["code"],
                  try SamsungAccountProtocol.decryptServiceValue(state, state: attempt.state) == attempt.state
            else { throw Failure.invalidCallback }
            // Fixed field names and booleans only. No callback URL or values.
            fieldPresence = Dictionary(uniqueKeysWithValues:
                ["retValue", "retvalue", "login_id", "loginId", "username", "user_id", "userId", "uid", "id"].map {
                    ("callback_has_" + $0, fields[$0] != nil)
                })
            let codeValue = try SamsungAccountProtocol.decryptServiceValue(code, state: attempt.state)
            let servers: SamsungAccountProtocol.Servers
            if let auth = fields["auth_server_url"], let api = fields["api_server_url"] {
                let authHost = try SamsungAccountProtocol.decryptServiceValue(auth, state: attempt.state)
                let apiHost = try SamsungAccountProtocol.decryptServiceValue(api, state: attempt.state)
                let directory = try JSONSerialization.data(withJSONObject: ["auth_server_url": authHost,
                    "api_server_url": apiHost, "idm_server_url": "account.samsung.com"])
                servers = try SamsungAccountProtocol.Servers.decode(directory)
            } else if client == .windowsAccount, fields["auth_server_url"] == nil,
                      fields["api_server_url"] == nil, let fallbackServers {
                servers = fallbackServers
            } else { throw Failure.invalidCallback }
            if client == .windowsAccount {
                // Native ParseSignInResult decrypts retValue and forwards that
                // exact value as username to GetUserAuthToken. It is not the
                // username/login_id alias assumed by the first implementation.
                let identities = try ["retValue", "username", "login_id"].compactMap { key -> String? in
                    guard let encrypted = fields[key] else { return nil }
                    let value = try SamsungAccountProtocol.decryptServiceValue(encrypted, state: attempt.state)
                    guard !value.isEmpty, value.count <= 1024, !value.contains(where: \.isNewline) else { throw Failure.invalidCallback }
                    return value
                }
                guard Set(identities).count <= 1 else { throw Failure.invalidCallback }
                username = identities.first
            }
            active = false
            return .init(code: codeValue, verifier: attempt.verifier, servers: servers)
        }
    }

    static func discoverEntryPoint(country: String = "BR", client: Client = .buds) async throws -> EntryPoint {
        guard country.range(of: "^[A-Z]{2}\\z", options: .regularExpression) != nil else { throw Failure.invalidEntryPoint }
        var request = URLRequest(url: URL(string: "https://account.samsung.com/accounts/\(client.channel)/getEntryPoint?countryCode=\(country)")!)
        request.setValue(client.id, forHTTPHeaderField: "x-osp-appId")
        return try EntryPoint.decode(await perform(request), client: client)
    }

    /// Public application/redirect validation performed by Samsung's v3 sign-in
    /// frontend. This sends no account identifiers, password, token or cookie.
    /// A legacy gate redirect alone is not evidence of a registered callback.
    static func applicationValidationRequest(client: Client, attempt: SamsungAccountProtocol.Attempt,
                                             country: String = "BR") throws -> URLRequest {
        guard country.range(of: "^[A-Z]{2}\\z", options: .regularExpression) != nil else { throw Failure.invalidEntryPoint }
        var request = URLRequest(url: URL(string: "https://v3.account.samsung.com/api/v1/auths/applications")!)
        request.httpMethod = "POST"
        for (header, value) in ["Content-Type": "application/json", "x-app-id": "yj5i8j79cw",
            "x-locale": "pt-BR", "x-page-name": "/legacy/authorize",
            "Origin": "https://v3.account.samsung.com", "Referer": "https://v3.account.samsung.com/iam/legacy/authorize",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"] {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["clientId": client.id,
            "redirectUri": client.callback.absoluteString, "responseType": "code", "state": attempt.state,
            "scope": "offline.access", "authType": "legacy", "countryCode": country,
            "languageCode": "pt", "action": "signin"])
        return request
    }

    static func validateRegisteredCallback(client: Client, attempt: SamsungAccountProtocol.Attempt) async throws {
        _ = try await perform(applicationValidationRequest(client: client, attempt: attempt))
    }

    /// The caller must keep the returned response in memory or Keychain only.
    static func exchangeCode(_ code: SamsungAccountProtocol.AuthorizedCode, physicalAddress: String) async throws -> Data {
        guard physicalAddress.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        var request = try SamsungAccountProtocol.authorizationCodeRequest(servers: code.servers,
            clientID: clientID, code: code.code, verifier: code.verifier)
        request.httpBody?.append(Data("&physical_address_text=\(physicalAddress)".utf8))
        let data = try await perform(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String, !token.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty else { throw Failure.invalidResponse }
        return data
    }

    /// Refresh with the original client only. A refresh token does not grant
    /// permission to impersonate another Samsung application.
    static func refresh(account: [String: Any], now: Date = Date()) async throws -> [String: Any] {
        guard let originalClient = account["client_id"] as? String,
              [clientID, SamsungCloudProtocol.appID, Client.windowsAccount.id].contains(originalClient),
              let previous = account["token_response"] as? [String: Any],
              let refreshToken = previous["refresh_token"] as? String, !refreshToken.isEmpty,
              let authHost = account["auth_host"] as? String,
              let apiHost = account["api_host"] as? String,
              let physicalAddress = account["installation_id"] as? String,
              physicalAddress.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        let directory = try JSONSerialization.data(withJSONObject: ["auth_server_url": authHost,
            "api_server_url": apiHost, "idm_server_url": "account.samsung.com"])
        let servers = try SamsungAccountProtocol.Servers.decode(directory)
        var request = try SamsungAccountProtocol.refreshRequest(servers: servers, clientID: originalClient, refreshToken: refreshToken)
        request.httpBody?.append(Data("&physical_address_text=\(physicalAddress)".utf8))
        return try replacingTokens(in: account, response: await perform(request), now: now)
    }

    static func replacingTokens(in account: [String: Any], response: Data, now: Date) throws -> [String: Any] {
        guard let previous = account["token_response"] as? [String: Any],
              let replacement = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let token = replacement["access_token"] as? String, !token.isEmpty,
              !token.contains(where: \.isNewline),
              replacement["refresh_token"] == nil || !(replacement["refresh_token"] as? String ?? "").isEmpty
        else { throw Failure.invalidResponse }
        var updated = account
        updated["token_response"] = previous.merging(replacement) { _, new in new }
        updated["obtained_at"] = now.timeIntervalSince1970
        return updated
    }

    static func perform(_ input: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = input; request.timeoutInterval = 25
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url, data.count <= 65536 else { throw Failure.invalidResponse }
        guard http.statusCode == 200 else {
            // Public machine codes only; never retain a body or description
            // that could echo an authorization code or account identifier.
            throw Failure.rejected(http.statusCode, SamsungCloudProtocol.serverErrorCode(from: data))
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
