import Foundation
import UserNotifications
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif

/// 监听 `~/.flowcue/hook-events.jsonl`：Codex 每跑完一轮，hook 脚本会追加一行。
/// 这里只做「收到 → 通知」，不改你的数据。
final class HookEventMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0

    func start() {
        let url = CodexHooks.eventsFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

        let handle = FileHandle(forReadingAtPath: url.path)
        let fd = handle?.fileDescriptor ?? -1
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.readNewLines(url: url)
        }
        source.setCancelHandler { try? handle?.close() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func readNewLines(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset = size
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            notifyIfStop(String(line))
        }
    }

    private func notifyIfStop(_ line: String) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // 新格式：{source, received_at, payload:{...}}；旧格式是平铺的事件对象
        let source = envelope["source"] as? String
        let payload = (envelope["payload"] as? [String: Any]) ?? envelope

        let name = (payload["hook_event_name"] as? String)
            ?? (payload["event"] as? String)
            ?? "Stop"
        guard name == "Stop" else { return }

        let agent = source == "claude" ? "Claude Code" : "Codex"
        let agentID = source == "claude" ? "claude" : "codex"
        let project = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let sessionID = (payload["session_id"] as? String) ?? UUID().uuidString
        let snippet = project.map { L10n.text("在 ") + $0 + L10n.text(" 完成一轮") }
            ?? L10n.text("完成一轮")

        Task { @MainActor in
            NotificationService.shared.postTurnFinished(
                agent: agent,
                sessionTitle: project ?? "",
                snippet: snippet,
                agentID: agentID,
                sessionID: sessionID
            )
        }
    }
}
