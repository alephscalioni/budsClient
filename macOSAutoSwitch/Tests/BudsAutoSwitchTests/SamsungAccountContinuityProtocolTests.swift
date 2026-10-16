import XCTest
@testable import BudsAutoSwitch

final class SamsungAccountContinuityProtocolTests: XCTestCase {
    private func servers() throws -> SamsungAccountProtocol.Servers {
        try .decode(Data("{\"auth_server_url\":\"us-auth2.samsungosp.com\",\"api_server_url\":\"us-auth2.samsungosp.com\",\"idm_server_url\":\"account.samsung.com\"}".utf8))
    }
    private func fields(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        return Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(string: "https://example.invalid?" + body)?.queryItems).map { ($0.name, $0.value ?? "") })
    }
    func testUserAuthIssuanceIsSeparateFromOAuthTokenExchange() throws {
        let code = SamsungAccountProtocol.AuthorizedCode(code: "synthetic-code", verifier: String(repeating: "V", count: 50), servers: try servers())
        let request = try SamsungAccountContinuityProtocol.userAuthRequest(code: code,
            physicalAddress: "synthetic-installation", username: "synthetic+user@example.invalid")
        XCTAssertEqual(request.url?.path, "/auth/oauth2/authenticate")
        XCTAssertEqual(request.httpMethod, "POST")
        let values = try fields(request)
        XCTAssertEqual(values["client_id"], "yfrtglt53o")
        XCTAssertEqual(values["grant_type"], "authorization_code")
        XCTAssertEqual(values["serviceType"], "M")
        XCTAssertEqual(values["username"], "synthetic+user@example.invalid")
        XCTAssertNil(values["access_token"])
    }
    func testCloudAuthorizationUsesUatAndNewPkceForCloudClient() throws {
        let attempt = SamsungAccountProtocol.Attempt(state: "synthetic-state", verifier: String(repeating: "V", count: 50))
        let request = try SamsungAccountContinuityProtocol.clientAuthorizationRequest(servers: servers(),
            userAuthToken: "synthetic-uat", attempt: attempt, physicalAddress: "synthetic-installation")
        let values = try fields(request)
        XCTAssertEqual(request.url?.path, "/auth/oauth2/v2/authorize")
        XCTAssertEqual(values["client_id"], "zwxnfb7qyh")
        XCTAssertEqual(values["userauth_token"], "synthetic-uat")
        XCTAssertEqual(values["code_challenge"], attempt.challenge)
        XCTAssertEqual(values["scope"], "offline.access")
        XCTAssertNil(values["code_verifier"])
        XCTAssertNil(values["access_token"])
    }
    func testMissingOrInvalidUsernameStopsBeforeTokenRequest() throws {
        let code = SamsungAccountProtocol.AuthorizedCode(code: "synthetic-code", verifier: String(repeating: "V", count: 50), servers: try servers())
        for username in [nil, "", "   ", "synthetic\r\nuser"] as [String?] {
            XCTAssertThrowsError(try SamsungAccountContinuityProtocol.userAuthRequest(code: code,
                physicalAddress: "synthetic-installation", username: username))
        }
    }
    func testConfirmedIdentifierIsValidatedWithoutChangingEmail() throws {
        XCTAssertEqual(try SamsungAccountContinuityProtocol.loginIdentifier("  synthetic+user@example.invalid  "), "synthetic+user@example.invalid")
        XCTAssertEqual(try SamsungAccountContinuityProtocol.loginIdentifier("+55 (84) 99999-9999"), "+5584999999999")
        for value in ["", "synthetic", "@example.invalid", "synthetic@", "synthetic @example.invalid", "synthetic\n@example.invalid"] {
            XCTAssertThrowsError(try SamsungAccountContinuityProtocol.loginIdentifier(value))
        }
    }
    func testWaitingForIdentifierDoesNotConsumeCodeOnInputErrorAndPreventsReplay() async throws {
        let code = SamsungAccountProtocol.AuthorizedCode(code: "synthetic-code", verifier: String(repeating: "V", count: 50), servers: try servers())
        let pending = SamsungAccountContinuityProtocol.PendingIdentity(code: code)
        do { _ = try await pending.consume(identifier: "invalid"); XCTFail("Invalid identifier accepted") } catch {}
        let (authorized, username) = try await pending.consume(identifier: "synthetic@example.invalid")
        XCTAssertEqual(authorized.code, "synthetic-code")
        XCTAssertEqual(username, "synthetic@example.invalid")
        do { _ = try await pending.consume(identifier: username); XCTFail("Authorization reused") } catch {}
    }
    func testWaitingIdentityExpiresAndCanBeCancelled() async throws {
        let code = SamsungAccountProtocol.AuthorizedCode(code: "synthetic-code", verifier: String(repeating: "V", count: 50), servers: try servers())
        let expired = SamsungAccountContinuityProtocol.PendingIdentity(code: code, deadline: .now.advanced(by: .seconds(-1)))
        do { _ = try await expired.consume(identifier: "synthetic@example.invalid"); XCTFail("Expired authorization accepted") } catch {}
        let cancelled = SamsungAccountContinuityProtocol.PendingIdentity(code: code)
        await cancelled.cancel()
        do { _ = try await cancelled.consume(identifier: "synthetic@example.invalid"); XCTFail("Cancelled authorization accepted") } catch {}
    }
    func testConsentRequirementsPreventSilentTokenExchange() throws {
        XCTAssertEqual(try SamsungAccountContinuityProtocol.authorizationCode(from: Data("{\"code\":\"synthetic-code\",\"privacyAccepted\":true}".utf8)), "synthetic-code")
        for response in ["{\"code\":\"synthetic\",\"requireTncAccepted\":true}",
                         "{\"code\":\"synthetic\",\"privacyAccepted\":\"N\"}",
                         "{\"code\":\"synthetic\",\"requireChildAccountGraduated\":\"Y\"}", "{}"] {
            XCTAssertThrowsError(try SamsungAccountContinuityProtocol.authorizationCode(from: Data(response.utf8)))
        }
    }
}
