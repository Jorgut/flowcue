import XCTest
import Foundation
import CryptoKit
#if SWIFT_PACKAGE
@testable import CodexIdeaDockCore
#endif

final class LicenseTests: XCTestCase {
    func testVerifiesSignedLicense() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let payload: [String: Any] = [
            "v": 1,
            "id": "lic_test",
            "email": "test@example.com",
            "product": "mac-pro",
            "seat": 7,
            "tier": 1,
            "issued_at": "2026-11-24T00:00:00Z"
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try key.signature(for: body)
        let token = "FC1-\(base64URL(body)).\(base64URL(signature))"

        let license = LicenseVerifier.verify(token, publicKeyBase64: publicKey)
        XCTAssertEqual(license?.seat, 7)
        XCTAssertEqual(license?.product, "mac-pro")
        XCTAssertEqual(license?.email, "test@example.com")
    }

    func testRejectsTamperedLicense() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let body = Data(#"{"v":1,"id":"lic_test","product":"mac-pro","seat":7,"tier":1,"issued_at":"2026-11-24T00:00:00Z"}"#.utf8)
        let signature = try key.signature(for: body)
        let tamperedBody = Data(((String(data: body, encoding: .utf8) ?? "") + " ").utf8)
        let token = "FC1-\(base64URL(tamperedBody)).\(base64URL(signature))"
        XCTAssertNil(LicenseVerifier.verify(token, publicKeyBase64: publicKey))
    }

    func testRejectsWrongProduct() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let body = Data(#"{"v":1,"id":"lic_test","product":"other","seat":7,"tier":1,"issued_at":"2026-11-24T00:00:00Z"}"#.utf8)
        let signature = try key.signature(for: body)
        let token = "FC1-\(base64URL(body)).\(base64URL(signature))"
        XCTAssertNil(LicenseVerifier.verify(token, publicKeyBase64: publicKey))
    }

    func testProductionKeyWhenProvided() throws {
        guard let token = ProcessInfo.processInfo.environment["FLOWCUE_TEST_LICENSE"] else {
            throw XCTSkip("Set FLOWCUE_TEST_LICENSE to verify the production key")
        }
        let license = LicenseVerifier.verify(token)
        XCTAssertNotNil(license)
        XCTAssertEqual(license?.product, "mac-pro")
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
