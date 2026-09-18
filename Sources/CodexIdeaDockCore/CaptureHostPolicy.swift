import Foundation

public enum CaptureHostPolicy {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Beta",
        "dev.warp.Warp-Nightly",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
    ]

    public static func shouldFloat(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return supportedBundleIdentifiers.contains(bundleIdentifier)
    }
}

public struct CaptureHostState: Equatable, Sendable {
    public private(set) var lastExternalBundleIdentifier: String?

    public init(lastExternalBundleIdentifier: String? = nil) {
        self.lastExternalBundleIdentifier = lastExternalBundleIdentifier
    }

    @discardableResult
    public mutating func applicationDidActivate(
        bundleIdentifier: String?,
        isCurrentApplication: Bool
    ) -> Bool {
        if !isCurrentApplication {
            lastExternalBundleIdentifier = bundleIdentifier
        }
        return shouldFloat
    }

    public var shouldFloat: Bool {
        CaptureHostPolicy.shouldFloat(
            bundleIdentifier: lastExternalBundleIdentifier
        )
    }
}
