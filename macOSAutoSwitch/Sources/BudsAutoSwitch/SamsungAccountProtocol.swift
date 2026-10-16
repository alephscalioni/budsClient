import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Recovered SASDK wire primitives. These do not start sign-in, register a client,
/// store credentials, or grant access to Samsung Cloud Bluetooth records.
enum SamsungAccountProtocol {
    enum Failure: Error { case malformedServerDirectory, invalidParameter, invalidEncryptedValue, randomGeneration, invalidHTTPResponse, invalidCallback, callbackInactive }

    struct Servers: Equatable, Sendable {
        let apiHost: String
        let authHost: String
        let identityHost: String
        var tokenURL: URL { URL(string: "https://\(authHost)/auth/oauth2/token")! }

        private init(apiHost: String, authHost: String, identityHost: String) {
            self.apiHost = apiHost; self.authHost = authHost; self.identityHost = identityHost
        }

        static func decode(_ data: Data) throws -> Servers {
            struct Reply: Decodable {
                let api_server_url: String
                let auth_server_url: String
                let idm_server_url: String
            }
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            func validHost(_ value: String, suffixes: [String]) -> Bool {
                guard value == value.lowercased(), value.utf8.count <= 253,
                      value.range(of: "^[a-z0-9]+(?:[a-z0-9.-]*[a-z0-9])?\\z", options: .regularExpression) != nil,
                      !value.contains("..") else { return false }
                return suffixes.contains { value == $0 || value.hasSuffix("." + $0) }
            }
            let authSuffixes = ["samsungosp.com", "samsungosp.com.cn"]
            guard validHost(reply.api_server_url, suffixes: authSuffixes),
                  validHost(reply.auth_server_url, suffixes: authSuffixes),
                  reply.idm_server_url == "account.samsung.com" else { throw Failure.malformedServerDirectory }
            return Servers(apiHost: reply.api_server_url, authHost: reply.auth_server_url,
                           identityHost: reply.idm_server_url)
        }
    }

    struct Attempt: Sendable {
        let state: String
        let verifier: String
        var challenge: String { SamsungAccountProtocol.challenge(for: verifier) }

        static func fresh() throws -> Attempt {
            // Match the inspected Settings consumer's 32/50 character lengths.
            func randomString(_ count: Int) throws -> String {
                let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
                var random = [UInt8](repeating: 0, count: count)
                let status = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
                guard status == errSecSuccess else { throw Failure.randomGeneration }
                return String(decoding: random.map { alphabet[Int($0 & 63)] }, as: UTF8.self)
            }
            return try Attempt(state: randomString(32), verifier: randomString(50))
        }
    }

    struct AuthorizedCode: Sendable {
        let code: String
        let verifier: String
        let servers: Servers
    }

    /// Consumes the recovered *service* callback, not the still-unrecovered web
    /// authorization redirect. The future broker must register a compatible URI.
    actor PendingServiceSignIn {
        private let attempt: Attempt
        private let callbackScheme: String
        private let expiresAt: ContinuousClock.Instant
        private var active = true

        // Five minutes is our local attempt lifetime, not a recovered Samsung
        // code lifetime. The future broker must cancel superseded attempts.
        init(attempt: Attempt, callbackScheme: String,
             expiresAt: ContinuousClock.Instant = .now.advanced(by: .seconds(300))) throws {
            guard callbackScheme.range(of: "^[a-z][a-z0-9.+-]{1,127}\\z", options: .regularExpression) != nil else { throw Failure.invalidParameter }
            self.attempt = attempt; self.callbackScheme = callbackScheme
            self.expiresAt = expiresAt
        }

        func cancel() { active = false }

        func consume(_ callback: URL) throws -> AuthorizedCode {
            guard active else { throw Failure.callbackInactive }
            guard ContinuousClock.now < expiresAt else {
                active = false
                throw Failure.callbackInactive
            }
            guard callback.absoluteString.utf8.count <= 65536,
                  let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  components.scheme == callbackScheme, components.host == nil,
                  components.user == nil, components.password == nil, components.port == nil,
                  components.path == "/", components.fragment == nil,
                  let items = components.queryItems, items.count <= 24 else { throw Failure.invalidCallback }
            var fields: [String: String] = [:]
            for item in items {
                guard fields[item.name] == nil, let value = item.value else { throw Failure.invalidCallback }
                fields[item.name] = value
            }
            guard fields["action"] == "authorize", fields["result"] == "true",
                  let stateHex = fields["state"], let codeHex = fields["auth_code"],
                  let authHex = fields["auth_server_url"], let apiHex = fields["api_server_url"] else { throw Failure.invalidCallback }
            let state = try decryptServiceValue(stateHex, state: attempt.state)
            guard state == attempt.state else { throw Failure.invalidCallback }
            let code = try decryptServiceValue(codeHex, state: attempt.state)
            let auth = try decryptServiceValue(authHex, state: attempt.state)
            let api = try decryptServiceValue(apiHex, state: attempt.state)
            let directory = try JSONSerialization.data(withJSONObject: ["api_server_url": api,
                "auth_server_url": auth, "idm_server_url": "account.samsung.com"])
            let servers = try Servers.decode(directory)
            active = false
            return AuthorizedCode(code: code, verifier: attempt.verifier, servers: servers)
        }
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SASDK Util.Decrypt: hex ciphertext, AES-128 ECB/PKCS7, first 16 UTF-8 state
    /// bytes as key. Return an error on invalid input rather than accepting empty text.
    static func decryptServiceValue(_ hex: String, state: String) throws -> String {
        let input = Array(hex.utf8)
        guard !input.isEmpty, input.count <= 32768, input.count % 32 == 0,
              state.utf8.count >= 16 else { throw Failure.invalidEncryptedValue }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var ciphertext = [UInt8](); ciphertext.reserveCapacity(input.count / 2)
        for offset in stride(from: 0, to: input.count, by: 2) {
            guard let hi = nibble(input[offset]), let lo = nibble(input[offset + 1]) else { throw Failure.invalidEncryptedValue }
            ciphertext.append((hi << 4) | lo)
        }
        let key = Array(state.utf8.prefix(16))
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { keyBuffer in
            ciphertext.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), keyBuffer.baseAddress,
                            kCCKeySizeAES128, nil, inputBuffer.baseAddress, ciphertext.count,
                            outputBuffer.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess, written > 0,
              let result = String(bytes: output.prefix(written), encoding: .utf8) else { throw Failure.invalidEncryptedValue }
        return result
    }

    static func authorizationCodeRequest(servers: Servers, clientID: String, code: String, verifier: String) throws -> URLRequest {
        guard !clientID.isEmpty, !code.isEmpty, (43...128).contains(verifier.utf8.count),
              verifier.range(of: "^[A-Za-z0-9._~-]+\\z", options: .regularExpression) != nil else { throw Failure.invalidParameter }
        return formRequest(url: servers.tokenURL, values: [("grant_type", "authorization_code"),
            ("client_id", clientID), ("code", code), ("code_verifier", verifier)])
    }

    static func refreshRequest(servers: Servers, clientID: String, refreshToken: String) throws -> URLRequest {
        guard !clientID.isEmpty, !refreshToken.isEmpty else { throw Failure.invalidParameter }
        return formRequest(url: servers.tokenURL, values: [("grant_type", "refresh_token"),
            ("client_id", clientID), ("refresh_token", refreshToken)])
    }

    private static func formRequest(url: URL, values: [(String, String)]) -> URLRequest {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = values.map { key, value in key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 20
        return request
    }

    /// This unauthenticated discovery GET is the only live account request wired
    /// here. Token request builders above are deliberately not executed yet.
    static func discoverServers() async throws -> Servers {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://auth2.samsungosp.com/v2/license/open/whoareyou")!)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == request.url, data.count <= 65536 else { throw Failure.invalidHTTPResponse }
        return try Servers.decode(data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
