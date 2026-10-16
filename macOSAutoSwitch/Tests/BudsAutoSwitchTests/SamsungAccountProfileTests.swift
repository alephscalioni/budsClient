import XCTest
@testable import BudsAutoSwitch

final class SamsungAccountProfileTests: XCTestCase {
    private func account(host: String = "us-auth2.samsungosp.com", user: String = "synthetic-user") -> [String: Any] {
        ["api_host": host, "client_id": "zwxnfb7qyh", "token_response": ["access_token": "synthetic-token", "userId": user]]
    }
    func testProfileRequestUsesUserResourceAndKeepsCredentialsInHeaders() throws {
        let request = try SamsungAccountProfileProtocol.request(account: account())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v2/profile/user/user/synthetic-user")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-osp-userid"), "synthetic-user")
    }
    func testProfileRejectsForeignHostAndUserPathInjection() {
        XCTAssertThrowsError(try SamsungAccountProfileProtocol.request(account: account(host: "evil.example")))
        XCTAssertThrowsError(try SamsungAccountProfileProtocol.request(account: account(user: "../other")))
    }
    func testAvatarNeverFollowsForeignOrInsecureUrls() {
        XCTAssertNotNil(SamsungAccountProfileProtocol.avatarURL("https://cdn.samsung.com/profile.png"))
        for url in ["http://cdn.samsung.com/a", "https://samsung.com.evil.example/a", "https://user@cdn.samsung.com/a", "https://cdn.samsung.com:8443/a"] {
            XCTAssertNil(SamsungAccountProfileProtocol.avatarURL(url))
        }
    }
}
