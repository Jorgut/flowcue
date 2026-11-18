import XCTest
@testable import CodexIdeaDockCore

final class CaptureHostPolicyTests: XCTestCase {
    func testCodexAndClaudeDesktopAreFloatingHosts() {
        XCTAssertTrue(CaptureHostPolicy.shouldFloat(bundleIdentifier: "com.openai.codex"))
        XCTAssertTrue(
            CaptureHostPolicy.shouldFloat(
                bundleIdentifier: "com.anthropic.claudefordesktop"
            )
        )
    }

    func testSupportedTerminalApplicationsAreFloatingHosts() {
        let terminalBundleIdentifiers = [
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

        for bundleIdentifier in terminalBundleIdentifiers {
            XCTAssertTrue(
                CaptureHostPolicy.shouldFloat(bundleIdentifier: bundleIdentifier),
                "Expected \(bundleIdentifier) to be a floating host"
            )
        }
    }

    func testUnrelatedApplicationsAreNotFloatingHosts() {
        let unrelatedBundleIdentifiers: [String?] = [
            nil,
            "com.apple.Safari",
            "com.apple.finder",
            "com.tencent.xinWeChat",
            "com.archintera.FlowCue.Mac",
        ]

        for bundleIdentifier in unrelatedBundleIdentifiers {
            XCTAssertFalse(
                CaptureHostPolicy.shouldFloat(bundleIdentifier: bundleIdentifier),
                "Expected \(bundleIdentifier ?? "nil") not to be a floating host"
            )
        }
    }

    func testCurrentApplicationActivationPreservesPreviousExternalHost() {
        var state = CaptureHostState()

        XCTAssertTrue(
            state.applicationDidActivate(
                bundleIdentifier: "com.openai.codex",
                isCurrentApplication: false
            )
        )
        XCTAssertTrue(
            state.applicationDidActivate(
                bundleIdentifier: "com.archintera.FlowCue.Mac",
                isCurrentApplication: true
            )
        )
        XCTAssertEqual(state.lastExternalBundleIdentifier, "com.openai.codex")

        XCTAssertFalse(
            state.applicationDidActivate(
                bundleIdentifier: "com.apple.Safari",
                isCurrentApplication: false
            )
        )
        XCTAssertFalse(
            state.applicationDidActivate(
                bundleIdentifier: "com.archintera.FlowCue.Mac",
                isCurrentApplication: true
            )
        )
        XCTAssertEqual(state.lastExternalBundleIdentifier, "com.apple.Safari")
    }

    func testExternalApplicationWithoutBundleIdentifierClearsFloatingState() {
        var state = CaptureHostState(lastExternalBundleIdentifier: "com.apple.Terminal")

        XCTAssertFalse(
            state.applicationDidActivate(
                bundleIdentifier: nil,
                isCurrentApplication: false
            )
        )
        XCTAssertNil(state.lastExternalBundleIdentifier)
    }
}
