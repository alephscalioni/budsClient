import Foundation
import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SamsungAccountProfileProtocol {
    enum Failure: Error { case malformed, rejected(Int, String) }
    struct Profile {
        let name: String?
        let email: String?
        let avatar: Data?
    }
    static func request(account: [String: Any]) throws -> URLRequest {
        guard let host = account["api_host"] as? String,
              let client = account["client_id"] as? String,
              let response = account["token_response"] as? [String: Any],
              let token = response["access_token"] as? String, !token.isEmpty,
              let userID = (response["userId"] ?? response["user_id"]) as? String, !userID.isEmpty,
              userID.range(of: "^[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil,
              !token.contains(where: \.isNewline) else { throw Failure.malformed }
        let servers = try SamsungAccountProtocol.Servers.decode(JSONSerialization.data(withJSONObject: [
            "auth_server_url": host, "api_server_url": host, "idm_server_url": "account.samsung.com"]))
        var request = URLRequest(url: URL(string: "https://" + servers.apiHost + "/v2/profile/user/user/" + userID)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "x-osp-appId")
        request.setValue(userID, forHTTPHeaderField: "x-osp-userid")
        return request
    }
    static func avatarURL(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil,
              ["samsung.com", "samsungosp.com", "samsungcloud.com", "samsungcloudplatform.com", "samsungusercontent.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return parts.url
    }
    static func fetch(account: [String: Any]) async throws -> Profile {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = try request(account: account)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url, data.count < 1_000_000 else { throw Failure.malformed }
        guard (200...299).contains(http.statusCode) else { throw Failure.rejected(http.statusCode, SamsungCloudProtocol.serverErrorCode(from: data)) }
        let root: [String: Any]
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { root = json }
        else {
            let reader = ProfileXML()
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = reader
            guard parser.parse(), !reader.values.isEmpty else { throw Failure.malformed }
            root = reader.values
        }
        var object: [String: Any] = [:]
        let fields: Set<String> = ["firstName", "first_name", "given_name", "givenName", "lastName", "last_name", "family_name", "familyName", "name", "displayName", "nickname", "email", "emailLoginID", "emailLoginId", "loginId", "login_id", "profileImageUrl", "profile_image_url", "picture", "profileImage", "photoUrl", "photo_url", "profile_image", "imageUrl"]
        func collect(_ value: Any, depth: Int) {
            guard depth <= 8 else { return }
            if let dictionary = value as? [String: Any] {
                for (key, item) in dictionary {
                    if fields.contains(key), object[key] == nil, item is String { object[key] = item }
                    if item is [String: Any] || item is [Any] { collect(item, depth: depth + 1) }
                }
            } else if let array = value as? [Any] { for item in array.prefix(4) { collect(item, depth: depth + 1) } }
        }
        collect(root, depth: 0)
        func value(_ names: [String]) -> String? {
            for name in names { if let value = object[name] as? String, !value.isEmpty, value.count <= 512 { return value } }
            return nil
        }
        let first = value(["firstName", "first_name", "given_name", "givenName"])
        let last = value(["lastName", "last_name", "family_name", "familyName"])
        let name = value(["name", "displayName", "nickname"]) ?? [first, last].compactMap { $0 }.joined(separator: " ")
        let email = value(["email", "emailLoginID", "emailLoginId", "loginId", "login_id"])
        var avatar: Data?
        if let text = value(["profileImageUrl", "profile_image_url", "picture", "profileImage", "photoUrl", "photo_url", "profile_image", "imageUrl"]), let url = avatarURL(text) {
            // Never attach Account credentials to the photo request.
            if let (image, response) = try? await session.data(for: URLRequest(url: url)),
               let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
               image.count < 8_000_000, let bitmap = NSBitmapImageRep(data: image),
               bitmap.pixelsWide <= 4096, bitmap.pixelsHigh <= 4096 { avatar = image }
        }
        guard !name.isEmpty || email != nil || avatar != nil else { throw Failure.malformed }
        return Profile(name: name.isEmpty ? nil : name, email: email, avatar: avatar)
    }
    static func fetchCloudAvatar(account: [String: Any]) async throws -> Profile {
        let data = try await SamsungCloudProtocol.readProfileImageDocuments(account: account)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let documents = root["documents"] as? [[String: Any]] else { throw Failure.malformed }
        // The profile-image table is account-owned. Inspect only image references,
        // never print arbitrary record values or attach a bearer to a CDN URL.
        var candidates: [URL] = []
        func find(_ item: Any, depth: Int) {
            guard depth <= 6, candidates.count < 4 else { return }
            if let object = item as? [String: Any] {
                for key in ["url", "imageUrl", "profileImageUrl", "downloadUrl", "href", "reference"] {
                    if let text = object[key] as? String, let url = avatarURL(text) { candidates.append(url) }
                }
                for key in ["data", "files", "image", "photo", "profileImage"] { if let value = object[key] { find(value, depth: depth + 1) } }
            } else if let array = item as? [Any] { for value in array.prefix(4) { find(value, depth: depth + 1) } }
        }
        for document in documents.prefix(4) { find(document, depth: 0) }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for url in candidates {
            if let (image, response) = try? await session.data(for: URLRequest(url: url)),
               let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url,
               image.count < 8_000_000, let bitmap = NSBitmapImageRep(data: image),
               bitmap.pixelsWide <= 4096, bitmap.pixelsHigh <= 4096 { return Profile(name: nil, email: nil, avatar: image) }
        }
        throw Failure.malformed
    }

    private final class ProfileXML: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var text = ""
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { text = "" }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 16384 { text += string } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { values[elementName] = value }; text = ""
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
