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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let name = (json["hook_event_name"] as? String) ?? (json["event"] as? String) ?? "Stop"
        guard name == "Stop" else { return }

        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let body = project.map { L10n.text("Codex 在 ") + $0 + L10n.text(" 跑完了一轮") }
            ?? L10n.text("Codex 跑完了一轮")

        let content = UNMutableNotificationContent()
        content.title = "FlowCue"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
