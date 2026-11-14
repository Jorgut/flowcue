import Foundation
import Observation

@MainActor
@Observable
public final class IdeaSyncController {
    public private(set) var isEnabled: Bool
    public private(set) var isSyncing = false
    public private(set) var statusMessage = "同步已关闭"
    public var isAvailable: Bool { containerIdentifier != nil }
    private let store: IdeaDockStore
    private let defaults: UserDefaults
    private let containerIdentifier: String?
    private let journalURL: URL
    @ObservationIgnored private var session: IdeaSyncSession?
    private static let preferenceKey = "Reroute.iCloudSyncEnabled"

    public init(store: IdeaDockStore, defaults: UserDefaults, containerIdentifier: String?, journalURL: URL? = nil) {
        self.store = store
        self.defaults = defaults
        self.containerIdentifier = containerIdentifier?.isEmpty == false ? containerIdentifier : nil
        self.journalURL = journalURL ?? URL.applicationSupportDirectory.appendingPathComponent("RerouteSync/journal.json")
        self.isEnabled = containerIdentifier?.isEmpty == false && defaults.bool(forKey: Self.preferenceKey)
        if self.containerIdentifier == nil { statusMessage = "此版本暂不支持 iCloud 同步" }
        else if isEnabled { statusMessage = "等待同步" }
    }

    public func setEnabled(_ enabled: Bool) {
        guard !enabled || isAvailable else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        statusMessage = enabled ? "等待同步" : "同步已关闭"
    }

    public func synchronizeNow() async {
        guard isEnabled, !isSyncing, let containerIdentifier else { return }
        isSyncing = true
        statusMessage = "正在同步"
        defer { isSyncing = false }
        do {
            if session == nil {
                session = try IdeaSyncSession(journalURL: journalURL, transport: CloudKitIdeaTransport(containerIdentifier: containerIdentifier))
            }
            try await session?.synchronize(readLocal: { self.store.sharedIdeas }, apply: { ideas in
                guard self.isEnabled, !Task.isCancelled else { throw CancellationError() }
                try self.store.applySharedIdeas(ideas)
            })
            statusMessage = isEnabled ? "已同步" : "同步已关闭"
        } catch is CancellationError {
            statusMessage = isEnabled ? "等待同步" : "同步已关闭"
        } catch IdeaSyncError.accountChanged {
            setEnabled(false)
            statusMessage = "iCloud 账户已更换，同步已暂停"
        } catch IdeaSyncError.protectedLocalNote {
            statusMessage = "想法存在编辑冲突，原文已保留"
        } catch {
            // Never expose raw CloudKit errors or note content in UI/diagnostics.
            statusMessage = isEnabled ? "暂时无法同步，本地想法已保留" : "同步已关闭"
        }
    }

    /// iOS callers cancel this task when leaving the foreground. No hard real-time promise.
    public func runWhileActive() async {
        while !Task.isCancelled {
            await synchronizeNow()
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
        }
    }
}
