import AppKit
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

enum CodexFallbackResult {
    case copiedAndActivated
    case empty
    case copyFailed
    case copyFailedAndClipboardCouldNotBeRestored
    case copiedButCouldNotOpen

    var notification: DockNotification {
        switch self {
        case .copiedAndActivated:
            DockNotification(kind: .success, message: "已复制并打开 Codex。")
        case .empty:
            DockNotification(kind: .warning, message: "没有可复制的内容。")
        case .copyFailed:
            DockNotification(kind: .error, message: "复制失败，未打开 Codex。")
        case .copyFailedAndClipboardCouldNotBeRestored:
            DockNotification(kind: .error, message: "复制失败，原剪贴板也未能恢复。")
        case .copiedButCouldNotOpen:
            DockNotification(kind: .warning, message: "内容已复制，但无法打开 Codex。")
        }
    }
}

@MainActor
enum CodexFallback {
    static func copyAndActivate(text: String) async -> CodexFallbackResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return .empty
        }

        let pasteboard = NSPasteboard.general
        #if REROUTE_APP_STORE
        pasteboard.clearContents()
        guard pasteboard.writeObjects([text as NSString]) else {
            NSSound.beep()
            return .copyFailed
        }
        #else
        let previousItems = pasteboard.pasteboardItems
        pasteboard.clearContents()
        guard pasteboard.writeObjects([text as NSString]) else {
            pasteboard.clearContents()
            let restoredClipboard: Bool
            if let previousItems {
                restoredClipboard = previousItems.isEmpty || pasteboard.writeObjects(previousItems)
            } else {
                restoredClipboard = false
            }
            NSSound.beep()
            return restoredClipboard ? .copyFailed : .copyFailedAndClipboardCouldNotBeRestored
        }
        #endif

        if let runningApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first,
           runningApplication.activate(options: [.activateAllWindows]) {
            return .copiedAndActivated
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            NSSound.beep()
            return .copiedButCouldNotOpen
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(
                    returning: application != nil && error == nil
                        ? .copiedAndActivated
                        : .copiedButCouldNotOpen
                )
            }
        }
    }
}
