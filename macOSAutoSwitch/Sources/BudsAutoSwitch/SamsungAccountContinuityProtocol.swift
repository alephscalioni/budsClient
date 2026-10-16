import Foundation

/// Selected native Windows Account contract: browser code -> UAT -> per-client
/// authorization code -> OAuth token. This is separate from Buds web OAuth.
enum SamsungAccountContinuityProtocol {
    enum Failure: Error { case malformed, consentRequired, missingUsername }
    enum Consumer: String { case cloud = "zwxnfb7qyh", profile = "yfrtglt53o" }

    /// A validated browser code may briefly wait for an identifier the browser
    /// did not return. Keep it in memory, bounded and consumable only once.
    actor PendingIdentity {
        private var code: SamsungAccountProtocol.AuthorizedCode?
        private let deadline: ContinuousClock.Instant
        init(code: SamsungAccountProtocol.AuthorizedCode,
             deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(120))) {
            self.code = code; self.deadline = deadline
        }
        func consume(identifier: String) throws -> (SamsungAccountProtocol.AuthorizedCode, String) {
            guard ContinuousClock.now < deadline, let code else { self.code = nil; throw Failure.malformed }
            let username = try SamsungAccountContinuityProtocol.loginIdentifier(identifier)
            self.code = nil
            return (code, username)
        }
        func cancel() { code = nil }
    }

    static func loginIdentifier(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 320, !value.contains(where: \.isNewline) else { throw Failure.missingUsername }
        if value.contains("@") {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
                  !value.contains(where: \.isWhitespace) else { throw Failure.missingUsername }
            return value
        }
        let phone = value.filter { !" ()-".contains($0) }
        guard phone.range(of: "^\\+?[0-9]{6,20}\\z", options: .regularExpression) != nil else { throw Failure.missingUsername }
        return phone
    }

    static func userAuthRequest(code: SamsungAccountProtocol.AuthorizedCode,
                                physicalAddress: String, username: String?) throws -> URLRequest {
        guard let username, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.count <= 1024, !username.contains(where: \.isNewline) else { throw Failure.missingUsername }
        let original = try SamsungAccountProtocol.authorizationCodeRequest(servers: code.servers,
            clientID: SamsungAccountWebProtocol.Client.windowsAccount.id, code: code.code, verifier: code.verifier)
        var request = original
        request.url = URL(string: "https://\(code.servers.authHost)/auth/oauth2/authenticate")!
        let extra = try form([("physical_address_text", physicalAddress), ("serviceType", "M"), ("username", username)])
        request.httpBody?.append(Data(("&" + extra).utf8))
        return request
    }

    static func clientAuthorizationRequest(servers: SamsungAccountProtocol.Servers, userAuthToken: String,
                                            attempt: SamsungAccountProtocol.Attempt, physicalAddress: String, consumer: Consumer = .cloud) throws -> URLRequest {
        let body = try form([("response_type", "code"), ("serviceType", "M"),
            ("client_id", consumer.rawValue), ("userauth_token", userAuthToken),
            ("code_challenge", attempt.challenge), ("code_challenge_method", "S256"),
            ("physical_address_text", physicalAddress), ("scope", "offline.access")])
        var request = URLRequest(url: URL(string: "https://\(servers.authHost)/auth/oauth2/v2/authorize")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    private static func form(_ values: [(String, String)]) throws -> String {
        guard values.allSatisfy({ $0.1.count <= 16384 && !$0.1.contains(where: \.isNewline) }) else { throw Failure.malformed }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return values.map { $0.0 + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    }

    static func acquireUserAuth(code: SamsungAccountProtocol.AuthorizedCode, physicalAddress: String,
                                username: String?) async throws -> [String: Any] {
        let response = try await SamsungAccountWebProtocol.perform(userAuthRequest(code: code,
            physicalAddress: physicalAddress, username: username))
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let token = object["userauth_token"] as? String, !token.isEmpty else { throw Failure.malformed }
        return object
    }

    static func acquireCloudAccount(userAuth: [String: Any], servers: SamsungAccountProtocol.Servers,
                                     installationID: String, consumer: Consumer = .cloud) async throws -> [String: Any] {
        guard let uat = userAuth["userauth_token"] as? String, !uat.isEmpty else { throw Failure.malformed }
        let attempt = try SamsungAccountProtocol.Attempt.fresh()
        let data = try await SamsungAccountWebProtocol.perform(clientAuthorizationRequest(servers: servers,
            userAuthToken: uat, attempt: attempt, physicalAddress: installationID, consumer: consumer))
        let code = try authorizationCode(from: data)
        var request = try SamsungAccountProtocol.authorizationCodeRequest(servers: servers,
            clientID: consumer.rawValue, code: code, verifier: attempt.verifier)
        request.httpBody?.append(Data(("&" + (try form([("physical_address_text", installationID)]))).utf8))
        let response = try await SamsungAccountWebProtocol.perform(request)
        guard let token = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              !(token["access_token"] as? String ?? "").isEmpty,
              !(token["refresh_token"] as? String ?? "").isEmpty else { throw Failure.malformed }
        return ["client_id": consumer.rawValue, "auth_host": servers.authHost,
            "api_host": servers.apiHost, "installation_id": installationID,
            "token_response": token, "obtained_at": Date().timeIntervalSince1970,
            "root_account_session": userAuth]
    }

    static func authorizationCode(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
        for key in ["requireTncAccepted", "requireChildAccountGraduated"] {
            if let value = object[key] as? String, ["Y", "true"].contains(value) { throw Failure.consentRequired }
            if let value = object[key] as? Bool, value { throw Failure.consentRequired }
        }
        if let value = object["privacyAccepted"] as? String, ["N", "false"].contains(value) { throw Failure.consentRequired }
        if let value = object["privacyAccepted"] as? Bool, !value { throw Failure.consentRequired }
        guard let code = object["code"] as? String, !code.isEmpty, code.count <= 16384,
              !code.contains(where: \.isNewline) else { throw Failure.malformed }
        return code
    }
}
