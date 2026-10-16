import XCTest
import Security
import CommonCrypto
@testable import BudsAutoSwitch

final class SamsungAccountWebProtocolTests: XCTestCase {
    func testRefreshKeepsAccountIdentityAndRefreshTokenWhenServerDoesNotRotateIt() throws {
        let account: [String: Any] = ["client_id": SamsungAccountWebProtocol.clientID,
            "obtained_at": 1, "installation_id": "synthetic-installation",
            "token_response": ["access_token": "synthetic-old", "refresh_token": "synthetic-refresh",
                               "userId": "synthetic-user"]]
        let updated = try SamsungAccountWebProtocol.replacingTokens(in: account,
            response: Data("{\"access_token\":\"synthetic-new\",\"expires_in\":3600}".utf8),
            now: Date(timeIntervalSince1970: 100))
        let token = try XCTUnwrap(updated["token_response"] as? [String: Any])
        XCTAssertEqual(token["access_token"] as? String, "synthetic-new")
        XCTAssertEqual(token["refresh_token"] as? String, "synthetic-refresh")
        XCTAssertEqual(token["userId"] as? String, "synthetic-user")
        XCTAssertEqual(updated["client_id"] as? String, SamsungAccountWebProtocol.clientID)
        XCTAssertEqual(updated["obtained_at"] as? Double, 100)
    }

    func testRefreshRotationAndMalformedResponses() throws {
        let account: [String: Any] = ["token_response": ["refresh_token": "synthetic-old"]]
        let updated = try SamsungAccountWebProtocol.replacingTokens(in: account,
            response: Data("{\"access_token\":\"synthetic-new\",\"refresh_token\":\"synthetic-rotated\"}".utf8), now: Date())
        XCTAssertEqual((updated["token_response"] as? [String: Any])?["refresh_token"] as? String, "synthetic-rotated")
        for response in ["{}", "{\"access_token\":\"\"}", "{\"access_token\":\"new\",\"refresh_token\":\"\"}",
                         "{\"access_token\":\"new\",\"refresh_token\":null}"] {
            XCTAssertThrowsError(try SamsungAccountWebProtocol.replacingTokens(in: account,
                response: Data(response.utf8), now: Date()))
        }
    }

    private func keyPair() throws -> (SecKey, SecKey) {
        // Like the cloud-certificate fixtures, generate only synthetic material
        // with local OpenSSL and import it into memory. macOS's default RSA
        // generator can require Keychain access even for nonpersistent keys.
        // This protocol fixture must not depend on the production Keychain
        // backend, ACLs or nonextractable-key creation/migration policy.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["genrsa", "2048"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pem = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Synthetic RSA fixture generation failed")
        let base64 = String(decoding: pem, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        let imported = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        let failure = error?.takeRetainedValue()
        let privateKey = try XCTUnwrap(imported, "Synthetic RSA import failed: \(String(describing: failure))")
        return (privateKey, try XCTUnwrap(SecKeyCopyPublicKey(privateKey)))
    }
    private let attempt = SamsungAccountProtocol.Attempt(state: "0123456789abcdef0123456789abcdef",
                                                        verifier: String(repeating: "V", count: 50))
    func testWindowsAccountUsesPackageSidCallbackInsteadOfGoogleCallback() throws {
        let profile = SamsungAccountWebProtocol.DeviceProfile(installationID: String(repeating: "a", count: 32), country: "BR", systemVersion: "27.0")
        let values = try profile.parameters(attempt: attempt, client: .windowsAccount)
        XCTAssertEqual(values["clientId"], "yfrtglt53o")
        // Independent Python hashlib/struct vector from the signed package PFN.
        XCTAssertEqual(values["redirect_uri"], "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358")
        XCTAssertNotEqual(values["redirect_uri"], "com.saclientforwindows:/")
        XCTAssertEqual(values["deviceModelID"], "960XGL")
        XCTAssertEqual(values["competitorDeviceYNFlag"], "N")
        XCTAssertEqual(values["deviceOSVersion"], "10.0.26100.0")
        XCTAssertEqual(values["clientVer"], "WINSDK2.25.109")
        XCTAssertNil(try profile.parameters(attempt: attempt)["clientVer"])
        let (_, key) = try keyPair()
        let windows = try XCTUnwrap(String(data: entry(publicKey: key), encoding: .utf8)).replacingOccurrences(of: "ANDROIDSDK", with: "WINSDK")
        XCTAssertEqual(try SamsungAccountWebProtocol.EntryPoint.decode(Data(windows.utf8), client: .windowsAccount).signInURL.path, "/accounts/WINSDK/signInGate")
        XCTAssertThrowsError(try SamsungAccountWebProtocol.EntryPoint.decode(Data(windows.utf8)))
    }

    func testWindowsCallbackValidatesItsOwnRouteAndDoesNotAcceptBudsRoute() async throws {
        let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt, client: .windowsAccount)
        do { _ = try await pending.consume(callback()); XCTFail("Buds route accepted for Windows") } catch {}
        let google = try XCTUnwrap(URL(string: callback().absoluteString.replacingOccurrences(of: "sawebsdk://paran.buds.samsungaccount.auth", with: "com.saclientforwindows:/")))
        do { _ = try await pending.consume(google); XCTFail("Google callback accepted for Samsung") } catch {}
        let windows = try XCTUnwrap(URL(string: callback().absoluteString.replacingOccurrences(of: "sawebsdk://paran.buds.samsungaccount.auth", with: SamsungAccountWebProtocol.windowsCallbackURL.absoluteString)))
        let otherPackage = try XCTUnwrap(URL(string: windows.absoluteString.replacingOccurrences(of: "1974417358", with: "1974417359")))
        do { _ = try await pending.consume(otherPackage); XCTFail("Different package SID accepted") } catch {}
        let result = try await pending.consume(windows)
        XCTAssertEqual(result.code, "synthetic-code+with&symbols=1")
        do { _ = try await pending.consume(windows); XCTFail("Callback replay accepted") } catch {}
    }

    func testApplicationPreflightUsesSameClientAndCallbackWithoutAccountCredentials() throws {
        let request = try SamsungAccountWebProtocol.applicationValidationRequest(client: .windowsAccount, attempt: attempt)
        XCTAssertEqual(request.url?.absoluteString, "https://v3.account.samsung.com/api/v1/auths/applications")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app-id"), "yj5i8j79cw")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(values["clientId"], "yfrtglt53o")
        XCTAssertEqual(values["redirectUri"], SamsungAccountWebProtocol.windowsCallbackURL.absoluteString)
        XCTAssertEqual(values["authType"], "legacy")
        XCTAssertEqual(Set(values.keys), ["clientId", "redirectUri", "responseType", "state", "scope", "authType", "countryCode", "languageCode", "action"])
    }

    func testWindowsRetValueIsDecryptedAsUatUsername() async throws {
        // Independent Python cryptography AES/ECB/PKCS7 fixture. No real account.
        let encrypted = "283f2699e35d590097b8b2410e84fedb5a48458a264a67fc9dbf06f8932f1743"
        let url = try XCTUnwrap(URL(string: callback(extra: "&retValue=" + encrypted).absoluteString.replacingOccurrences(
            of: "sawebsdk://paran.buds.samsungaccount.auth", with: SamsungAccountWebProtocol.windowsCallbackURL.absoluteString)))
        let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt, client: .windowsAccount)
        let code = try await pending.consume(url)
        let username = await pending.username
        XCTAssertEqual(username, "synthetic-user@example.invalid")
        let diagnostic = await pending.fieldPresence
        XCTAssertEqual(diagnostic["callback_has_retValue"], true)
        XCTAssertEqual(diagnostic["callback_has_user_id"], false)
        XCTAssertTrue(diagnostic.keys.allSatisfy { $0.hasPrefix("callback_has_") })
        let request = try SamsungAccountContinuityProtocol.userAuthRequest(code: code,
            physicalAddress: "synthetic-installation", username: username)
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8))
        let fields = try XCTUnwrap(URLComponents(string: "https://example.invalid?" + body)?.queryItems)
        XCTAssertEqual(fields.first(where: { $0.name == "username" })?.value, "synthetic-user@example.invalid")
    }

    func testWindowsCallbackRejectsConflictingIdentityAliases() async throws {
        let retValue = "283f2699e35d590097b8b2410e84fedb5a48458a264a67fc9dbf06f8932f1743"
        let other = "3391411672638de85218099788496e714d539709bed015a4fa69d2ba539a99b8"
        let url = try XCTUnwrap(URL(string: callback(extra: "&retValue=" + retValue + "&login_id=" + other).absoluteString.replacingOccurrences(
            of: "sawebsdk://paran.buds.samsungaccount.auth", with: SamsungAccountWebProtocol.windowsCallbackURL.absoluteString)))
        let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt, client: .windowsAccount)
        do { _ = try await pending.consume(url); XCTFail("Conflicting identities accepted") } catch {}
    }
    private func entry(publicKey: SecKey) throws -> Data {
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        return try JSONSerialization.data(withJSONObject: [
            "signInURI": "https://account.samsung.com/accounts/ANDROIDSDK/signInGate", "chkDoNum": "synthetic-challenge",
            "pkiPublicKey": der.base64EncodedString(), "pbeKySpcIters": "200"])
    }

    func testEntryPointUsesValidatedHostPathAndPublicRSAKey() throws {
        let (_, publicKey) = try keyPair()
        let decoded = try SamsungAccountWebProtocol.EntryPoint.decode(entry(publicKey: publicKey))
        XCTAssertEqual(decoded.iterations, 200)
        XCTAssertEqual(decoded.challengeNumber, "synthetic-challenge")
        let valid = String(data: try entry(publicKey: publicKey), encoding: .utf8)!
        XCTAssertThrowsError(try SamsungAccountWebProtocol.EntryPoint.decode(Data(valid.replacingOccurrences(
            of: "account.samsung.com", with: "account.samsung.com.evil.example").utf8)))
        XCTAssertThrowsError(try SamsungAccountWebProtocol.EntryPoint.decode(Data(valid.replacingOccurrences(
            of: "\"200\"", with: "\"0\"").utf8)))
    }

    func testPBKDF2MatchesIndependentPythonVector() throws {
        let key = try SamsungAccountWebProtocol.deriveKey(challengeNumber: "synthetic-challenge",
            salt: Data(0..<16), iterations: 200)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "53ba8cb53ea111e5e8ce142a282ea3c5")
        XCTAssertThrowsError(try SamsungAccountWebProtocol.deriveKey(challengeNumber: "synthetic", salt: Data(), iterations: 200))
    }

    func testCBCMatchesIndependentCryptographyVector() throws {
        let encrypted = try SamsungAccountWebProtocol.encryptParameters(Data("{\"synthetic\":true}".utf8),
            key: Data(0..<16), iv: Data(16..<32))
        XCTAssertEqual(encrypted.map { String(format: "%02x", $0) }.joined(),
                       "438008befb94b77f7b7c4e3f58006d36ba5ba2358c2b5b0002c73d74f2708864")
    }

    func testEnvelopeRoundTripWithSyntheticRSAKeyAndFreshRandomness() throws {
        let (privateKey, publicKey) = try keyPair()
        let ep = try SamsungAccountWebProtocol.EntryPoint.decode(entry(publicKey: publicKey))
        let profile = SamsungAccountWebProtocol.DeviceProfile(installationID: String(repeating: "a", count: 32),
            country: "BR", systemVersion: "27.0")
        let url = try SamsungAccountWebProtocol.authorizationURL(entry: ep, attempt: attempt, profile: profile)
        let second = try SamsungAccountWebProtocol.authorizationURL(entry: ep, attempt: attempt, profile: profile)
        XCTAssertNotEqual(url, second)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let svcParam = try XCTUnwrap(query.first { $0.name == "svcParam" }?.value)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: svcParam))) as? [String: String])
        let wrapped = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["svcEncKY"])))
        let wrappedPlain = try XCTUnwrap(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, wrapped as CFData, nil) as Data?)
        let key = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(String(data: wrappedPlain, encoding: .utf8))))
        let ivHex = try XCTUnwrap(envelope["svcEncIV"])
        let iv = Data(stride(from: 0, to: ivHex.count, by: 2).map { offset -> UInt8 in
            let first = ivHex.index(ivHex.startIndex, offsetBy: offset)
            return UInt8(ivHex[first..<ivHex.index(first, offsetBy: 2)], radix: 16)!
        })
        let cipher = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["svcEncParam"])))
        var output = [UInt8](repeating: 0, count: cipher.count + 16)
        var written = 0; let capacity = output.count
        let status = key.withUnsafeBytes { keyBuffer in iv.withUnsafeBytes { ivBuffer in
            cipher.withUnsafeBytes { inputBuffer in output.withUnsafeMutableBytes { outputBuffer in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBuffer.baseAddress, key.count, ivBuffer.baseAddress, inputBuffer.baseAddress, cipher.count,
                    outputBuffer.baseAddress, capacity, &written)
            } }
        } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        let plain = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.prefix(written))) as? [String: String])
        XCTAssertEqual(plain, try profile.parameters(attempt: attempt))
        XCTAssertNil(plain["code_verifier"])
        XCTAssertEqual(plain["competitorDeviceYNFlag"], "Y")
    }

    private func callback(host: String = "paran.buds.samsungaccount.auth", extra: String = "") -> URL {
        let state = "72727e881edcfd0100a718687909b56572727e881edcfd0100a718687909b565377222e061a924c591cd9c27ea163ed4"
        let code = "3391411672638de85218099788496e714d539709bed015a4fa69d2ba539a99b8"
        let server = "aa4748578dfadd7f28238286efacd8b80b2fa1db2883f4eba54c391fa759fe68"
        return URL(string: "sawebsdk://\(host)?state=\(state)&code=\(code)&auth_server_url=\(server)&api_server_url=\(server)\(extra)")!
    }

    func testWebCallbackUsesCodeAndConsumesOnlyOnce() async throws {
        let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt)
        let code = try await pending.consume(callback())
        XCTAssertEqual(code.code, "synthetic-code+with&symbols=1")
        do { _ = try await pending.consume(callback()); XCTFail("Replay accepted") } catch { }
    }

    func testRejectsOtherCallbackRoutesDuplicatesAndFailure() async throws {
        for url in [callback(host: "other-app.example"), callback(extra: "&state=duplicate"),
                    callback(extra: "&result=false"), callback(extra: "&error=denied")] {
            let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt)
            do { _ = try await pending.consume(url); XCTFail("Invalid callback accepted") } catch { }
        }
    }

    func testCancelledAndExpiredWebAttemptsStayInactive() async throws {
        let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt)
        await pending.cancel()
        do { _ = try await pending.consume(callback()); XCTFail("Cancelled callback accepted") } catch { }
        let expired = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt, deadline: .now.advanced(by: .seconds(-1)))
        do { _ = try await expired.consume(callback()); XCTFail("Expired callback accepted") } catch { }
    }
}
