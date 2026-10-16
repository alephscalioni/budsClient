import XCTest
@testable import BudsAutoSwitch

final class SamsungCertificateSchemaDiagnosticsTests: XCTestCase {
    func testResponseMetadataNeverPublishesValuesOrUnknownFieldNames() throws {
        let secret = "DO_NOT_PUBLISH_ACCOUNT_TOKEN"
        let object: [String:Any] = ["userCertificate": secret,"userFingerprint":secret,
            "userAesKeyList":[["aes256Key":secret,"expireTime":123]],secret:secret,
            "deviceInfoList":[["dvcId":secret,"deviceName":secret,"btAddr":secret,"irk":secret]]]
        SamsungCertificateSchemaDiagnostics.begin(try JSONSerialization.data(withJSONObject:object))
        let diagnostic = SamsungCertificateSchemaDiagnostics.snapshot
        let json = String(decoding:try JSONSerialization.data(withJSONObject:diagnostic),as:UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertEqual(diagnostic["unknown_field_count"] as? Int,1)
        XCTAssertEqual(diagnostic["stage"] as? String,"json")
    }
    func testUntrustedDecodingPathAndErrorDescriptionAreRedacted() throws {
        struct Key:CodingKey {let stringValue:String;let intValue:Int?=nil;init?(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){return nil}}
        let secret="DO_NOT_PUBLISH_USER_IDENTIFIER"
        SamsungCertificateSchemaDiagnostics.begin(Data("{}".utf8))
        let error=DecodingError.keyNotFound(Key(stringValue:secret)!, .init(codingPath:[],debugDescription:secret))
        SamsungCertificateSchemaDiagnostics.decodingFailure(error)
        let snapshot=SamsungCertificateSchemaDiagnostics.snapshot
        XCTAssertEqual(snapshot["decoding_path"] as? [String],["other"])
        let json=String(decoding:try JSONSerialization.data(withJSONObject:snapshot),as:UTF8.self)
        XCTAssertFalse(json.contains(secret))
    }
}
