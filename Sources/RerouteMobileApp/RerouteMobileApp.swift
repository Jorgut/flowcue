import SwiftUI
import SwiftData
import StoreKit
import Observation



// MARK: - FlowCue Pro subscription

enum SubscriptionProduct {
    static let monthly = "com.flowcue.pro.monthly"
    static let yearly = "com.flowcue.pro.yearly"
    static let all = [monthly, yearly]
}

@MainActor
@Observable
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var isLoading = true
    var lastError: String?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { await listenForTransactions() }
        Task { await refresh() }
    }


    func refresh() async {
        isLoading = true
        await loadProducts()
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  SubscriptionProduct.all.contains(transaction.productID) else { continue }
            if transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > .now {
                entitled = true
            }
        }
        isPro = entitled
        isLoading = false
    }

    func loadProducts() async {
        do {
            products = try await Product.products(for: SubscriptionProduct.all)
                .sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    lastError = "Purchase could not be verified."
                    return
                }
                await transaction.finish()
                await refresh()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
                await refresh()
            }
        }
    }
}

struct SubscriptionPaywall: View {
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProductID: String?

    private var selectedProduct: Product? {
        subscription.products.first { $0.id == selectedProductID } ?? subscription.products.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FlowCue Pro").font(.largeTitle.bold())
                        Text("Capture ideas on any device and keep them in sync through your private iCloud account.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("iCloud sync across your devices", systemImage: "arrow.triangle.2.circlepath.icloud")
                        Label("Send ideas to your Mac and supported coding agents", systemImage: "paperplane")
                        Label("More agent continuation features as they ship", systemImage: "sparkles")
                    }
                    if subscription.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if subscription.products.isEmpty {
                        Text("Subscription products are not available yet. Please try again later.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(subscription.products, id: \.id) { product in
                            Button {
                                selectedProductID = product.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(product.displayName).font(.headline)
                                        if let intro = product.subscription?.introductoryOffer {
                                            Text("Includes a \(intro.period.value)-day free trial").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(product.displayPrice).font(.headline)
                                    if selectedProductID == product.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .padding()
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Button {
                            guard let selectedProduct else { return }
                            Task { await subscription.purchase(selectedProduct) }
                        } label: {
                            Text("Continue").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedProduct == nil)
                    }
                    Button("Restore Purchases") { Task { await subscription.restore() } }
                    if let error = subscription.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel in App Store settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://github.com/Jorgut/flowcue/blob/main/PRIVACY.md")!)
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.caption)
                }
                .padding()
            }
            .navigationTitle("FlowCue Pro")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: subscription.isPro) { _, isPro in if isPro { dismiss() } }
            .task { if subscription.products.isEmpty { await subscription.refresh() } }
        }
    }
}



// MARK: - Remote continuation (FlowCue Pro)

@MainActor
@Observable
final class RemotePhoneController {
    private let transport: CloudKitRemoteTransport?
    private let defaults: UserDefaults
    private(set) var threads: [RemoteThreadSnapshot] = []
    private(set) var isLoading = false
    var statusMessage = ""
    var lastError: String?

    var isAvailable: Bool { transport != nil }

    init(containerIdentifier: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.transport = containerIdentifier.flatMap { CloudKitRemoteTransport(containerIdentifier: $0) }
    }

    func refresh() async {
        guard let transport else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await transport.fetchThreads()
            statusMessage = threads.isEmpty ? "Waiting for your Mac to share sessions." : ""
        } catch {
            lastError = "Could not reach iCloud. Your Mac must be signed in to the same account."
        }
    }

    @discardableResult
    func send(to thread: RemoteThreadSnapshot, text: String) async -> Bool {
        guard let transport else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let phoneID: UUID
        if let raw = defaults.string(forKey: "FlowCue.remotePhoneID"), let id = UUID(uuidString: raw) {
            phoneID = id
        } else {
            phoneID = UUID()
            defaults.set(phoneID.uuidString, forKey: "FlowCue.remotePhoneID")
        }
        let command = RemoteCommand(phoneID: phoneID, executorID: thread.executorID, threadID: thread.id, text: trimmed)
        do {
            try await transport.sendCommand(command)
            statusMessage = "Sent to your Mac. The reply will appear when it is ready."
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
            return true
        } catch {
            lastError = "Could not send. Check that your Mac is online and signed in to iCloud."
            return false
        }
    }
}

struct RemoteAgentsView: View {
    @Bindable var controller: RemotePhoneController
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if !subscription.isPro {
                    ContentUnavailableView {
                        Label("FlowCue Pro", systemImage: "lock")
                    } description: {
                        Text("Remote continuation is part of FlowCue Pro.")
                    } actions: {
                        Button("Upgrade") { showingPaywall = true }
                    }
                } else if controller.threads.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions yet", systemImage: "moon.zzz")
                    } description: {
                        Text(controller.isLoading ? "Loading sessions…" : "On your Mac, enable “Allow iPhone to continue Codex sessions” from the FlowCue menu bar.")
                    }
                } else {
                    List(controller.threads) { thread in
                        NavigationLink {
                            RemoteThreadDetailView(controller: controller, thread: thread)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(thread.title).font(.headline).lineLimit(1)
                                if !thread.lastReply.isEmpty {
                                    Text(thread.lastReply).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    .refreshable { await controller.refresh() }
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await controller.refresh() }
            .sheet(isPresented: $showingPaywall) { SubscriptionPaywall() }
            .alert("Connection issue", isPresented: Binding(
                get: { controller.lastError != nil },
                set: { if !$0 { controller.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { controller.lastError = nil }
            } message: { Text(controller.lastError ?? "") }
        }
    }
}

private struct RemoteThreadDetailView: View {
    @Bindable var controller: RemotePhoneController
    let thread: RemoteThreadSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(thread.title).font(.title2.bold())
                if !thread.lastReply.isEmpty {
                    Text("Last reply").font(.caption).foregroundStyle(.secondary)
                    Text(thread.lastReply)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Continue").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Button {
                    isSending = true
                    Task {
                        let sent = await controller.send(to: thread, text: text)
                        if sent { text = "" }
                        isSending = false
                    }
                } label: {
                    Label("Send to Mac", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !controller.statusMessage.isEmpty {
                    Text(controller.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@main
struct RerouteMobileApp: App {
    @State private var store: IdeaDockStore?
    @State private var syncController: IdeaSyncController?
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @State private var subscription = SubscriptionManager()

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
                containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String)
        })
    }

    var body: some Scene {
        WindowGroup {
            if let store, let syncController {
                MobileInbox(store: store, syncController: syncController)
                    .id(language)
                    .environment(subscription)
                    .environment(\.locale, Locale(identifier: language))
            } else {
                ContentUnavailableView(L10n.text("FlowCue 无法启动"), systemImage: "exclamationmark.triangle", description: Text(L10n.text("无法打开本地存储，已有想法未被替换。")))
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
    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingCapture = false
    @State private var showingSettings = false
    @State private var showingPaywall = false
    @State private var showingRemote = false
    @State private var remoteController: RemotePhoneController?

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
            .navigationTitle("FlowCue")
            .searchable(text: $store.searchText, prompt: L10n.text("搜索内容"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "globe") }
                        .accessibilityLabel("Language")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingRemote = true } label: { Image(systemName: "paperplane") }
                        .accessibilityLabel("Agents")
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
            .sheet(isPresented: $showingRemote) {
                if let remoteController {
                    RemoteAgentsView(controller: remoteController)
                }
            }
            .task {
                guard remoteController == nil else { return }
                let container = Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String
                remoteController = RemotePhoneController(containerIdentifier: container)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    Form {
                        Section("FlowCue Pro") {
                            if subscription.isPro {
                                Label("Pro is active", systemImage: "checkmark.seal.fill")
                                Button("Manage subscription") {
                                    if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                                        UIApplication.shared.open(url)
                                    }
                                }
                            } else {
                                Text("iCloud sync and remote agent features require FlowCue Pro.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Upgrade to FlowCue Pro") { showingPaywall = true }
                            }
                            Button("Restore Purchases") { Task { await subscription.restore() } }
                        }
                        Section("iCloud Sync") {
                            Toggle("iCloud Sync", isOn: Binding(
                                get: { syncController.isEnabled },
                                set: { enabled in
                                    if enabled && !subscription.isPro {
                                        showingPaywall = true
                                    } else {
                                        syncController.setEnabled(enabled)
                                    }
                                }
                            ))
                            .disabled(!syncController.isAvailable)
                            Text(L10n.text(syncController.statusMessage)).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.text("想法通过你的私有 iCloud 账户在设备之间同步。"))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.text("立即同步")) { Task { await syncController.synchronizeNow() } }
                                .disabled(!subscription.isPro || !syncController.isEnabled || syncController.isSyncing)
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
                    .sheet(isPresented: $showingPaywall) { SubscriptionPaywall() }
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
