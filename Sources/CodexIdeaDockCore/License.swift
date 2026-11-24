import Foundation
import CryptoKit

/// Offline Mac Pro license issued by the founding Worker after a Paddle payment.
/// Format: `FC1-<base64url(payload JSON)>.<base64url(Ed25519 signature)>`.
public struct FlowCueLicense: Codable, Equatable, Sendable {
    public let v: Int
    public let id: String
    public let email: String?
    public let product: String
    public let seat: Int
    public let tier: Int
    public let issued_at: String
}

public enum LicenseVerifier {
    /// Raw 32-byte Ed25519 public key. The private key lives only in the Worker.
    public static let productionPublicKeyBase64 = "Fvc4ThUXSkdLAJKr+VlrahxuyjdvkX6wyTzgYVPazxU="

    public static func verify(_ token: String, publicKeyBase64: String = productionPublicKeyBase64) -> FlowCueLicense? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("FC1-") else { return nil }
        let rest = trimmed.dropFirst(4)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        guard let body = base64URLDecode(String(rest[..<dot])),
              let signature = base64URLDecode(String(rest[rest.index(after: dot)...])) else { return nil }
        guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return nil }
        guard key.isValidSignature(signature, for: body) else { return nil }
        guard let license = try? JSONDecoder().decode(FlowCueLicense.self, from: body) else { return nil }
        guard license.v == 1, license.product == "mac-pro", license.seat > 0 else { return nil }
        return license
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        return Data(base64Encoded: text)
    }
}
