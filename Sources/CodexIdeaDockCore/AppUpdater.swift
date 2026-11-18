import CommonCrypto
import Foundation

/// 直接分发版的自更新：查 GitHub release → 下载 DMG → 校验 sha256 → 打开。
/// 不引第三方框架；「替换 App」这一步交给用户拖进 Applications。
public actor AppUpdater {
    public struct Release: Sendable, Equatable {
        public let version: String        // 0.1.1
        public let tag: String            // v0.1.1
        public let dmgURL: URL
        public let sha256URL: URL?
        public let size: Int
    }

    public enum UpdateError: Error, Sendable {
        case noRelease
        case downloadFailed
        case checksumMismatch
    }

    public static let repository = "Jorgut/flowcue"

    public init() {}

    /// 当前 App 版本（CFBundleShortVersionString）。
    public nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("FlowCue", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int
                let browser_download_url: String
            }
            let tag_name: String
            let prerelease: Bool
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.prerelease,
              let dmg = payload.assets.first(where: { $0.name.hasSuffix(".dmg") }),
              let url = URL(string: dmg.browser_download_url) else {
            throw UpdateError.noRelease
        }
        let sha = payload.assets.first { $0.name == dmg.name + ".sha256" }
        return Release(
            version: payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name,
            tag: payload.tag_name,
            dmgURL: url,
            sha256URL: sha.flatMap { URL(string: $0.browser_download_url) },
            size: dmg.size
        )
    }

    /// 下载到 Downloads 并校验；返回本地文件 URL。
    public func download(_ release: Release,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: release.dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let total = max(release.size, 1)
        var data = Data()
        data.reserveCapacity(total)
        var buffer = Data(capacity: 1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                data.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(min(1, Double(data.count) / Double(total)))
            }
        }
        data.append(buffer)
        progress(1)

        if let shaURL = release.sha256URL,
           let (shaData, _) = try? await URLSession.shared.data(from: shaURL),
           let expected = String(data: shaData, encoding: .utf8)?
               .split(separator: " ").first.map(String.init) {
            let actual = Self.sha256(data)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = downloads.appendingPathComponent(release.dmgURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return destination
    }

    nonisolated static func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
