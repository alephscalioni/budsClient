import XCTest
@testable import BudsAutoSwitch

final class SamsungCloudProtocolTests: XCTestCase {
    func testNestedCloudErrorsPreserveCodeWithoutEchoingSensitiveMessages() {
        let data = Data("{\"error\":{\"code\":\"AUTH.INVALID_APP\",\"message\":\"synthetic sensitive token\"}}".utf8)
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: data), "AUTH.INVALID_APP")
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: Data("{\"result\":{\"code\":401}}".utf8)), "401")
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: Data("{\"message\":\"synthetic-token\"}".utf8)), "")
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: Data("{\"error\":\"Bearer synthetic-token\"}".utf8)), "")
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: Data("{\"error\":\"invalid_request\",\"error_code\":\"AUT_1003\",\"error_description\":\"The value of username synthetic-sensitive-account must be present\"}".utf8)), "AUT_1003 / invalid_request")
        XCTAssertEqual(SamsungCloudProtocol.serverErrorCode(from: Data("{\"errorCode\":40100001,\"error\":{\"code\":\"ACCESS_TOKEN_EXPIRED\",\"message\":\"token expired: synthetic-sensitive-token\"}}".utf8)),
                       "40100001 / ACCESS_TOKEN_EXPIRED / TOKEN_EXPIRED")
    }
    private func directory(play: String = "https://play.samsungcloud.com") throws -> SamsungCloudProtocol.Directory {
        try .decode(JSONSerialization.data(withJSONObject: ["default": "https://api.samsungcloud.com", "play": play]))
    }

    func testDirectoryRejectsUntrustedURLsBeforeCredentialsAreUsed() throws {
        XCTAssertEqual(try directory().play.host, "play.samsungcloud.com")
        for url in ["http://play.samsungcloud.com", "https://play.samsungcloud.com.evil.example",
                    "https://user@play.samsungcloud.com", "https://play.samsungcloud.com/unexpected",
                    "https://play.samsungcloud.com:8443", "https://play.samsungcloud.com?redirect=1"] {
            XCTAssertThrowsError(try directory(play: url))
        }
    }

    func testRegistrationUsesAccountHeadersAndExplicitCompatibilityProfile() throws {
        let profile = SamsungCloudProtocol.Profile(installationID: String(repeating: "a", count: 32))
        let request = try profile.registrationRequest(directory: directory(), accessToken: "synthetic-access",
            userID: "synthetic-user", now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(request.url?.absoluteString, "https://play.samsungcloud.com/identity/v2/user/register?deviceCurrentTime=1000000")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sc-access-token"), "synthetic-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sc-uid"), "synthetic-user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sc-app-id"), "zwxnfb7qyh")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let device = try XCTUnwrap(body["device"] as? [String: String])
        XCTAssertEqual(device["osType"], "win")
        XCTAssertEqual(device["type"], "pc")
        XCTAssertEqual(device["alias"], "Galaxy Buds no Mac (compatibilidade)")
    }

    func testInstallationIdentityIsStableAndIndependent() {
        let a = SamsungCloudProtocol.Profile(installationID: String(repeating: "a", count: 32))
        let b = SamsungCloudProtocol.Profile(installationID: String(repeating: "b", count: 32))
        XCTAssertEqual(a.cdid, SamsungCloudProtocol.Profile(installationID: a.installationID).cdid)
        XCTAssertNotEqual(a.cdid, b.cdid)
        XCTAssertNotEqual(a.cdid, a.installationID)
    }

    func testLegacyBluetoothUsesAccountHeadersAndDistinctApplicationID() throws {
        let profile = SamsungCloudProtocol.Profile(installationID: String(repeating: "a", count: 32))
        let request = try SamsungCloudProtocol.legacyBluetoothRequest(directory: directory(),
            accountToken: "synthetic-account-token", userID: "synthetic-user",
            activatedLegacyDeviceID: "synthetic-activated-device", profile: profile)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SC-APP-ID"), "e2akaegdfg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SC-ACCESS-TOKEN"), "synthetic-account-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SC-DVC-ID"), "synthetic-activated-device")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRejectsMissingAccountAndHeaderInjection() throws {
        let profile = SamsungCloudProtocol.Profile(installationID: String(repeating: "a", count: 32))
        for token in ["", "synthetic\r\nOther: injected"] {
            XCTAssertThrowsError(try profile.registrationRequest(directory: directory(), accessToken: token, userID: "synthetic"))
        }
        XCTAssertThrowsError(try profile.registrationRequest(directory: directory(), accessToken: "synthetic", userID: ""))
        XCTAssertThrowsError(try SamsungCloudProtocol.Profile(installationID: "not-a-valid-id")
            .registrationRequest(directory: directory(), accessToken: "synthetic", userID: "synthetic"))
    }
    func testModernBluetoothReadKeepsPamBearerSeparateFromLegacyCredentials() throws {
        let profile = SamsungCloudProtocol.Profile(installationID: String(repeating: "a", count: 32))
        let request = try SamsungCloudProtocol.bluetoothDocumentsRequest(directory: directory(), pamToken: "synthetic-pam", profile: profile)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/data/v3/com.samsung.bluetooth.device_sync/documents")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-pam")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SC-ACCESS-TOKEN"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-SC-DVC-ID"))
        XCTAssertNil(request.httpBody)
        for token in ["", "synthetic\r\nInjected: value"] {
            XCTAssertThrowsError(try SamsungCloudProtocol.bluetoothDocumentsRequest(directory: directory(), pamToken: token, profile: profile))
        }
    }

    func testBluetoothReadCountsDocumentsWithoutTreatingEncryptedDataAsUsable() throws {
        let data = Data(#"{"documents":[{"data":{"record_id":"synthetic"},"needToDecrypt":false},{"data":{"e2ee_data":"synthetic"},"needToDecrypt":true}],"hasNext":true}"#.utf8)
        let snapshot = try SamsungCloudProtocol.BluetoothDocuments.decode(data)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.encryptedCount, 1)
        XCTAssertTrue(snapshot.hasNext)
        XCTAssertEqual(snapshot.data, data)
    }

    func testBluetoothReadRejectsErrorEnvelopeAndIncompletePagination() throws {
        for json in [#"{"errorCode":401}"#, #"{"documents":[]}"#,
                     #"{"documents":[{"data":{},"needToDecrypt":"false"}],"hasNext":false}"#] {
            XCTAssertThrowsError(try SamsungCloudProtocol.BluetoothDocuments.decode(Data(json.utf8)))
        }
        let empty = try SamsungCloudProtocol.BluetoothDocuments.decode(Data(#"{"documents":[],"hasNext":false}"#.utf8))
        XCTAssertEqual(empty.count, 0)
        XCTAssertFalse(empty.hasNext)
    }

}
