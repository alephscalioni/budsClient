import XCTest
@testable import BudsAutoSwitch

final class SamsungAccountProtocolTests: XCTestCase {
    private let syntheticState = "0123456789abcdef0123456789abcdef"
    private let stateCipher = "72727e881edcfd0100a718687909b56572727e881edcfd0100a718687909b565377222e061a924c591cd9c27ea163ed4"
    private let codeCipher = "3391411672638de85218099788496e714d539709bed015a4fa69d2ba539a99b8"
    private let hostCipher = "aa4748578dfadd7f28238286efacd8b80b2fa1db2883f4eba54c391fa759fe68"

    private func callback(state: String? = nil, scheme: String = "buds-account-test", result: String = "true", extra: String = "") -> URL {
        URL(string: "\(scheme):/?action=authorize&result=\(result)&state=\(state ?? stateCipher)&auth_code=\(codeCipher)&auth_server_url=\(hostCipher)&api_server_url=\(hostCipher)\(extra)")!
    }

    private func pending() throws -> SamsungAccountProtocol.PendingServiceSignIn {
        try SamsungAccountProtocol.PendingServiceSignIn(attempt: .init(state: syntheticState,
            verifier: String(repeating: "V", count: 50)), callbackScheme: "buds-account-test")
    }

    func testConsumesRecoveredSyntheticServiceCallbackExactlyOnce() async throws {
        let session = try pending()
        let accepted = try await session.consume(callback())
        XCTAssertEqual(accepted.code, "synthetic-code+with&symbols=1")
        XCTAssertEqual(accepted.servers.authHost, "us-auth2.samsungosp.com")
        do { _ = try await session.consume(callback()); XCTFail("Callback replay was accepted") } catch { }
    }

    func testRejectsWrongStateWithoutConsumingTheValidAttempt() async throws {
        let session = try pending()
        let wrong = "9b4caa9ea4e06d627f3d15c8f6380e436a9ebd5571b10230a14c9dd4b83c20754eff82c2cc816225ae734d5073e204bc"
        do { _ = try await session.consume(callback(state: wrong)); XCTFail("Mismatched state was accepted") } catch { }
        _ = try await session.consume(callback())
    }

    func testRejectsCancelledAndExpiredAttempts() async throws {
        let cancelled = try pending()
        await cancelled.cancel()
        do { _ = try await cancelled.consume(callback()); XCTFail("Cancelled attempt was accepted") } catch { }
        let expired = try SamsungAccountProtocol.PendingServiceSignIn(attempt: .init(state: syntheticState,
            verifier: String(repeating: "V", count: 50)), callbackScheme: "buds-account-test",
            expiresAt: .now.advanced(by: .seconds(-1)))
        do { _ = try await expired.consume(callback()); XCTFail("Expired attempt was accepted") } catch { }
    }

    func testRejectsWrongRouteFailureAndDuplicateCallbackParameters() async throws {
        for value in [callback(scheme: "other-app"), callback(result: "false"), callback(extra: "&state=duplicate"),
                      URL(string: callback().absoluteString.replacingOccurrences(of: ":/?", with: "://wrong-host/?"))!] {
            let session = try pending()
            do { _ = try await session.consume(value); XCTFail("Invalid callback was accepted") } catch { }
        }
    }

    private let directory = Data("""
    {"api_server_url":"us-auth2.samsungosp.com","auth_server_url":"us-auth2.samsungosp.com","idm_server_url":"account.samsung.com"}
    """.utf8)

    func testDecodesObservedSamsungBootstrapReply() throws {
        let servers = try SamsungAccountProtocol.Servers.decode(directory)
        XCTAssertEqual(servers.tokenURL.absoluteString, "https://us-auth2.samsungosp.com/auth/oauth2/token")
        XCTAssertEqual(servers.identityHost, "account.samsung.com")
    }

    func testRejectsUntrustedOrURLShapedHostsBeforeBuildingTokenRequests() {
        for host in ["samsungosp.com.evil.example", "us-auth2.samsungosp.com@evil.example",
                     "https://us-auth2.samsungosp.com", "us-auth2.samsungosp.com:443",
                     "us-auth2.samsungosp.com/other", "us-auth2.samsungosp.com?x=1"] {
            let json = "{\"api_server_url\":\"us-auth2.samsungosp.com\",\"auth_server_url\":\"\(host)\",\"idm_server_url\":\"account.samsung.com\"}"
            XCTAssertThrowsError(try SamsungAccountProtocol.Servers.decode(Data(json.utf8)))
        }
    }

    func testPKCEReferenceVector() {
        XCTAssertEqual(SamsungAccountProtocol.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testFreshAttemptsDoNotReuseStateOrVerifier() throws {
        let a = try SamsungAccountProtocol.Attempt.fresh()
        let b = try SamsungAccountProtocol.Attempt.fresh()
        XCTAssertEqual(a.state.count, 32)
        XCTAssertEqual(a.verifier.count, 50)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNil(a.challenge.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testDecryptsIndependentOpenSSLCallbackVector() throws {
        let state = "0123456789abcdef0123456789abcdef"
        // Synthetic plaintext encrypted independently with OpenSSL AES-128-ECB,
        // PKCS7, key = UTF-8 state[0..<16]. No user credentials are fixtures.
        let encrypted = "3391411672638de85218099788496e714d539709bed015a4fa69d2ba539a99b8"
        XCTAssertEqual(try SamsungAccountProtocol.decryptServiceValue(encrypted, state: state),
                       "synthetic-code+with&symbols=1")
        XCTAssertThrowsError(try SamsungAccountProtocol.decryptServiceValue(encrypted, state: String(repeating: "z", count: 32)))
    }

    func testRejectsMalformedEncryptedCallbacks() {
        for hex in ["", "00", String(repeating: "g", count: 32), String(repeating: "0", count: 32)] {
            XCTAssertThrowsError(try SamsungAccountProtocol.decryptServiceValue(hex, state: "0123456789abcdef0123456789abcdef"))
        }
        XCTAssertThrowsError(try SamsungAccountProtocol.decryptServiceValue(String(repeating: "0", count: 32), state: "short"))
    }

    func testAuthorizationCodeBodyMatchesRecoveredHTTPContractAndEscapesValues() throws {
        let servers = try SamsungAccountProtocol.Servers.decode(directory)
        let verifier = String(repeating: "V", count: 50)
        let request = try SamsungAccountProtocol.authorizationCodeRequest(servers: servers,
            clientID: "synthetic-client", code: "synthetic+code&next=1", verifier: verifier)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8),
            "grant_type=authorization_code&client_id=synthetic-client&code=synthetic%2Bcode%26next%3D1&code_verifier=\(verifier)")
    }

    func testRefreshBodyDoesNotIncludeAuthorizationCodeOrVerifier() throws {
        let request = try SamsungAccountProtocol.refreshRequest(servers: .decode(directory),
            clientID: "synthetic-client", refreshToken: "synthetic+refresh")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8),
                       "grant_type=refresh_token&client_id=synthetic-client&refresh_token=synthetic%2Brefresh")
    }

    func testRejectsMissingCredentialsAndMalformedVerifier() throws {
        let servers = try SamsungAccountProtocol.Servers.decode(directory)
        XCTAssertThrowsError(try SamsungAccountProtocol.authorizationCodeRequest(servers: servers, clientID: "", code: "synthetic", verifier: String(repeating: "V", count: 50)))
        for verifier in ["", "short", String(repeating: "x", count: 129), String(repeating: "!", count: 50),
                         String(repeating: "V", count: 50) + "\n", String(repeating: "V", count: 50) + "\r\n"] {
            XCTAssertThrowsError(try SamsungAccountProtocol.authorizationCodeRequest(servers: servers, clientID: "synthetic", code: "synthetic", verifier: verifier))
        }
        XCTAssertThrowsError(try SamsungAccountProtocol.refreshRequest(servers: servers, clientID: "synthetic", refreshToken: ""))
        XCTAssertThrowsError(try SamsungAccountProtocol.PendingServiceSignIn(attempt: .init(state: syntheticState,
            verifier: String(repeating: "V", count: 50)), callbackScheme: "buds-account-test\n"))
    }
}
