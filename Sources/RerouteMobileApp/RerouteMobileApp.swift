import SwiftUI
import SwiftData

@main
struct RerouteMobileApp: App {
    @State private var store: IdeaDockStore?
    @State private var syncController: IdeaSyncController?
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue

    init() {
        // Fail closed if the persistent database cannot be opened.
        let localStore = try? IdeaDockStore(
            modelContainer: IdeaDockPersistence.makeDefaultContainer(),
            bridge: MobileLocalBridge(),
            userDefaults: .standard
        )
        _store = State(initialValue: localStore)
        _syncController = State(initialValue: localStore.map {
            IdeaSyncController(store: $0, defaults: .standard,
                containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "RerouteCloudKitContainer") as? String)
        })
    }

    var body: some Scene {
        WindowGroup {
            if let store, let syncController {
                MobileInbox(store: store, syncController: syncController)
                    .id(language)
                    .environment(\.locale, Locale(identifier: language))
            } else {
                ContentUnavailableView(L10n.text("Reroute 无法启动"), systemImage: "exclamationmark.triangle", description: Text(L10n.text("无法打开本地存储，已有想法未被替换。")))
            }
        }
    }
}

private struct MobileLocalBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "Direct delivery is unavailable on iOS.")
    }
}

private struct MobileInbox: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @State private var showingCapture = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                if store.filteredCaptures.isEmpty {
                    Text(L10n.text("没有匹配的想法")).foregroundStyle(.secondary)
                }
                ForEach(store.filteredCaptures) { capture in
                    NavigationLink {
                        MobileDetail(store: store, capture: capture)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(capture.text).lineLimit(3)
                            Text(capture.updatedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Reroute")
            .searchable(text: $store.searchText, prompt: L10n.text("搜索内容"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "globe") }
                        .accessibilityLabel("Language")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCapture = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(L10n.text("记录想法"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = store.notification?.message {
                    Text(L10n.text(message)).font(.caption).padding().frame(maxWidth: .infinity).background(.bar)
                }
            }
            .sheet(isPresented: $showingCapture, onDismiss: { store.flushDraft() }) {
                NavigationStack {
                    TextEditor(text: $store.draftText)
                        .padding().accessibilityLabel(L10n.text("想法内容"))
                        .navigationTitle(L10n.text("记录想法"))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.text("关闭")) { store.flushDraft(); showingCapture = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button(L10n.text("保存")) {
                                    if store.saveCurrent() != nil { showingCapture = false }
                                }
                                .disabled(store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                }
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    Form {
                        Section("iCloud Sync") {
                            Toggle("iCloud Sync", isOn: Binding(
                                get: { syncController.isEnabled },
                                set: { syncController.setEnabled($0) }
                            ))
                            .disabled(!syncController.isAvailable)
                            Text(L10n.text(syncController.statusMessage)).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("想法通过你的私有 iCloud 账户在设备之间同步。"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("立即同步")) { Task { await syncController.synchronizeNow() } }
                                .disabled(!syncController.isEnabled || syncController.isSyncing)
                        }
                        Picker("Language / 语言", selection: $language) {
                            ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                                Text(language.displayName).tag(language.rawValue)
                            }
                        }
                        Toggle(L10n.text("已归档"), isOn: Binding(
                            get: { store.statusFilter == .archived },
                            set: { store.statusFilter = $0 ? .archived : nil }
                        ))
                    }
                    .navigationTitle(L10n.text("设置"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showingSettings = false } } }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await syncController.runWhileActive()
        }
    }
}

private struct MobileDetail: View {
    @Bindable var store: IdeaDockStore
    let capture: CaptureItem
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(store: IdeaDockStore, capture: CaptureItem) {
        self.store = store
        self.capture = capture
        _text = State(initialValue: capture.text)
    }

    var body: some View {
        TextEditor(text: $text)
            .padding()
            .disabled(capture.status == .archived)
            .navigationTitle(L10n.text("想法内容"))
            .accessibilityLabel(L10n.text("编辑想法内容"))
            .toolbar {
                ShareLink(item: text)
                Button(capture.status == .archived ? L10n.text("恢复到原状态") : L10n.text("归档")) {
                    if capture.status == .archived {
                        store.undoArchive(capture.id)
                    } else {
                        guard store.updateText(captureID: capture.id, text: text) else { return }
                        store.archive(capture.id)
                    }
                    dismiss()
                }
            }
            .task(id: text) {
                guard capture.status != .archived, text != capture.text else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                commitEditedText()
            }
            .onDisappear { commitEditedText() }
    }

    @discardableResult
    private func commitEditedText() -> Bool {
        guard capture.status != .archived, text != capture.text else { return true }
        let didSave = store.updateText(captureID: capture.id, text: text)
        if !didSave { text = capture.text }
        return didSave
    }
}
