import SwiftUI
import SwiftData
import StoreKit
import Observation
import UIKit

// MARK: - Product identity

enum FlowCueProduct {
    static let monthly = "com.archintera.FlowCue.Pro.Monthly"
    static let yearly = "com.archintera.FlowCue.Pro.Yearly"
    static let all = [monthly, yearly]
    static let privacyURL = URL(string: "https://github.com/Jorgut/flowcue/blob/main/PRIVACY.md")!
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
}

private enum FlowCueTheme {
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.16)
    static let accent = Color(red: 0.45, green: 0.40, blue: 1.0)
    static let mint = Color(red: 0.36, green: 0.85, blue: 0.72)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let canvas = Color(uiColor: .systemGroupedBackground)

    static var heroGradient: LinearGradient {
        LinearGradient(colors: [ink, Color(red: 0.18, green: 0.14, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Subscription

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
                  FlowCueProduct.all.contains(transaction.productID) else { continue }
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
            products = try await Product.products(for: FlowCueProduct.all)
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

    func trialDescription(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let unit: String
        switch offer.period.unit {
        case .day: unit = offer.period.value == 1 ? "day" : "days"
        case .week: unit = offer.period.value == 1 ? "week" : "weeks"
        case .month: unit = offer.period.value == 1 ? "month" : "months"
        case .year: unit = offer.period.value == 1 ? "year" : "years"
        @unknown default: unit = "days"
        }
        return "\(offer.period.value)-\(unit) free trial"
    }
}

// MARK: - Remote continuation

@MainActor
@Observable
final class RemotePhoneController {
    private let containerIdentifier: String?
    private let defaults: UserDefaults
    private(set) var threads: [RemoteThreadSnapshot] = []
    private(set) var isLoading = false
    var statusMessage = ""
    var lastError: String?

    var isAvailable: Bool { containerIdentifier?.isEmpty == false }

    init(containerIdentifier: String?, defaults: UserDefaults = .standard) {
        self.containerIdentifier = containerIdentifier
        self.defaults = defaults
    }

    private var transport: CloudKitRemoteTransport? {
        guard let containerIdentifier, !containerIdentifier.isEmpty else { return nil }
        return CloudKitRemoteTransport(containerIdentifier: containerIdentifier)
    }

    func refresh() async {
        guard let transport else {
            lastError = "iCloud is not available in this build."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await transport.fetchThreads().sorted { $0.updatedAt > $1.updatedAt }
            if threads.isEmpty {
                statusMessage = "Waiting for your Mac to share sessions."
            } else {
                statusMessage = ""
            }
        } catch {
            lastError = "Could not reach iCloud. Make sure your Mac is online and signed in to the same account."
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
        do {
            try await transport.sendCommand(RemoteCommand(phoneID: phoneID, executorID: thread.executorID, threadID: thread.id, text: trimmed))
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

// MARK: - App

@main
struct RerouteMobileApp: App {
    @State private var store: IdeaDockStore?
    @State private var syncController: IdeaSyncController?
    @State private var subscription = SubscriptionManager()
    @State private var remoteController = RemotePhoneController(containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String)
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage("FlowCue.hasSeenOnboarding") private var hasSeenOnboarding = false

    init() {
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
            Group {
                if let store, let syncController {
                    if hasSeenOnboarding {
                        RootTabView(store: store, syncController: syncController, remoteController: remoteController)
                    } else {
                        OnboardingView {
                            hasSeenOnboarding = true
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "FlowCue could not start",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Your existing ideas have not been replaced. Please reopen the app.")
                    )
                }
            }
            .id(language)
            .environment(subscription)
            .environment(\.locale, Locale(identifier: language))
        }
    }
}

private struct MobileLocalBridge: CodexBridging {
    func listThreads() async throws -> [WorkContextItem] { [] }
    func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        .failed(exitCode: nil, message: "Direct delivery is unavailable on iOS.")
    }
}

// MARK: - Root

private enum FlowCueTab: Hashable { case inbox, agents, settings }

private struct RootTabView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: RemotePhoneController
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage("FlowCue.hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: FlowCueTab = .inbox

    var body: some View {
        TabView(selection: $tab) {
            InboxView(store: store, syncController: syncController)
                .tag(FlowCueTab.inbox)
                .tabItem { Label("Ideas", systemImage: "sparkles") }
            AgentsView(controller: remoteController)
                .tag(FlowCueTab.agents)
                .tabItem { Label("Agents", systemImage: "paperplane") }
            SettingsView(store: store, syncController: syncController, remoteController: remoteController, showOnboarding: { hasSeenOnboarding = false })
                .tag(FlowCueTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(FlowCueTheme.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await syncController.runWhileActive()
        }
    }
}

// MARK: - Inbox

private struct InboxView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @State private var showingCompose = false
    @State private var showingPaywall = false
    @State private var showingArchived = false

    private var ideas: [CaptureItem] { store.filteredCaptures }

    var body: some View {
        NavigationStack {
            Group {
                if ideas.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(ideas) { idea in
                                NavigationLink {
                                    IdeaDetailView(store: store, capture: idea)
                                } label: {
                                    IdeaRow(capture: idea)
                                }
                                .listRowBackground(FlowCueTheme.surface)
                            }
                        } header: {
                            Text(showingArchived ? "Archived ideas" : "Recent ideas")
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(FlowCueTheme.canvas)
                }
            }
            .navigationTitle("FlowCue")
            .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search ideas")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingArchived.toggle()
                        store.statusFilter = showingArchived ? .archived : nil
                    } label: {
                        Image(systemName: showingArchived ? "tray.full.fill" : "tray")
                    }
                    .accessibilityLabel(showingArchived ? "Show active ideas" : "Show archived ideas")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Capture an idea")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = store.notification?.message {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(L10n.text(message)).font(.footnote)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
            .sheet(isPresented: $showingCompose, onDismiss: { store.flushDraft() }) {
                ComposeView(store: store)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 36)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(FlowCueTheme.heroGradient)
                    .frame(height: 190)
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.mint)
                    Text("A quiet place for ideas\nthat deserve a next step.")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Capture now. Continue with your coding agents later.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .padding(.horizontal)

            VStack(spacing: 12) {
                Button {
                    showingCompose = true
                } label: {
                    Label("Capture your first idea", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(FlowCueTheme.accent)
                if !subscription.isPro {
                    Button("See FlowCue Pro") { showingPaywall = true }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            Spacer()
        }
        .background(FlowCueTheme.canvas)
    }
}

private struct IdeaRow: View {
    let capture: CaptureItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capture.text)
                .font(.body)
                .lineLimit(4)
            HStack(spacing: 8) {
                Text(capture.updatedAt, format: .relative(presentation: .named))
                if capture.status == .archived {
                    Text("·")
                    Text("Archived")
                }
                if capture.status == .failed || capture.status == .unknown {
                    Text("·")
                    Label("Needs attention", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ComposeView: View {
    @Bindable var store: IdeaDockStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $store.draftText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(18)
                    .accessibilityLabel("Idea content")
                HStack {
                    Text("\(store.draftText.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.draftText.isEmpty {
                        Text("Start typing or paste a thought.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .background(FlowCueTheme.canvas)
            .navigationTitle("New idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.flushDraft(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.saveCurrent() != nil { dismiss() }
                    }
                    .disabled(store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
            .onAppear { focused = true }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }
}

private struct IdeaDetailView: View {
    @Bindable var store: IdeaDockStore
    let capture: CaptureItem
    @State private var text: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(store: IdeaDockStore, capture: CaptureItem) {
        self.store = store
        self.capture = capture
        _text = State(initialValue: capture.text)
    }

    private var isArchived: Bool { capture.status == .archived }
    private var hasChanges: Bool { text != capture.text }
    private var canSave: Bool { hasChanges && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isArchived }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .padding(10)
                    .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(isArchived)
                    .accessibilityLabel("Idea content")
                HStack {
                    Label(capture.updatedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    Spacer()
                    if isArchived {
                        Label("Archived", systemImage: "archivebox")
                    } else if capture.status == .failed || capture.status == .unknown {
                        Label("Needs attention", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Saved locally", systemImage: "internaldrive")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(FlowCueTheme.canvas)
        .navigationTitle(capture.text.isEmpty ? "Idea" : "Edit idea")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .bottomBar) {
                if isArchived {
                    Button("Restore") {
                        store.undoArchive(capture.id)
                        dismiss()
                    }
                } else {
                    Button("Archive", role: .destructive) {
                        _ = save(force: true)
                        store.archive(capture.id)
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { _ = save(force: false) }
    }

    @discardableResult
    private func save(force: Bool = false) -> Bool {
        guard isArchived == false, hasChanges else { return true }
        let trimmed = force ? text : text
        let didSave = store.updateText(captureID: capture.id, text: trimmed)
        if !didSave { text = capture.text }
        return didSave
    }
}

// MARK: - Agents

private struct AgentsView: View {
    @Bindable var controller: RemotePhoneController
    @Environment(SubscriptionManager.self) private var subscription
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Group {
                if !subscription.isPro {
                    ProLockedView(
                        title: "Continue sessions from your phone",
                        message: "FlowCue Pro connects to your Mac and lets you read the last reply and send the next message — without opening your laptop.",
                        action: { showingPaywall = true }
                    )
                } else if controller.threads.isEmpty {
                    ContentUnavailableView {
                        Label("No sessions yet", systemImage: "moon.zzz")
                    } description: {
                        Text(controller.isLoading ? "Looking for your Mac…" : "On your Mac, open FlowCue and enable “Allow iPhone to continue Codex sessions” in the menu bar. Both devices must use the same iCloud account.")
                    } actions: {
                        Button("Refresh") { Task { await controller.refresh() } }
                    }
                } else {
                    List(controller.threads) { thread in
                        NavigationLink {
                            AgentDetailView(controller: controller, thread: thread)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(thread.title).font(.headline).lineLimit(2)
                                if !thread.lastReply.isEmpty {
                                    Text(thread.lastReply).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text(thread.updatedAt, format: .relative(presentation: .named))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .listRowBackground(FlowCueTheme.surface)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .background(FlowCueTheme.canvas)
                    .refreshable { await controller.refresh() }
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await controller.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { if subscription.isPro { await controller.refresh() } }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }
}

private struct AgentDetailView: View {
    @Bindable var controller: RemotePhoneController
    let thread: RemoteThreadSnapshot
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thread.title).font(.title3.bold())
                    Text(thread.updatedAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !thread.lastReply.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Last reply", systemImage: "text.bubble")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(thread.lastReply)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Continue", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .focused($focused)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityLabel("Next message")
                }
                Button {
                    sending = true
                    Task {
                        let sent = await controller.send(to: thread, text: text)
                        if sent { text = "" }
                        sending = false
                        await controller.refresh()
                    }
                } label: {
                    Label(sending ? "Sending…" : "Send to Mac", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(FlowCueTheme.accent)
                .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !controller.statusMessage.isEmpty {
                    Text(controller.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(FlowCueTheme.canvas)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: RemotePhoneController
    let showOnboarding: () -> Void
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if subscription.isPro {
                        HStack {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(FlowCueTheme.mint)
                            VStack(alignment: .leading) {
                                Text("FlowCue Pro").font(.headline)
                                Text("iCloud sync and remote continuation are active.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Manage subscription") {
                            UIApplication.shared.open(FlowCueProduct.manageSubscriptionsURL)
                        }
                    } else {
                        Button {
                            showingPaywall = true
                        } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(FlowCueTheme.accent)
                                VStack(alignment: .leading) {
                                    Text("Upgrade to FlowCue Pro").font(.headline)
                                    Text("Sync ideas and continue sessions from your phone.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button("Restore purchases") { Task { await subscription.restore() } }
                } header: { Text("Subscription") }

                Section {
                    Toggle("iCloud sync", isOn: Binding(
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
                    Text(L10n.text(syncController.statusMessage))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sync now") { Task { await syncController.synchronizeNow() } }
                        .disabled(!subscription.isPro || !syncController.isEnabled || syncController.isSyncing)
                } header: { Text("iCloud") } footer: {
                    Text("Ideas sync through your private iCloud account. FlowCue never reads your coding-agent conversations for sync.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                } header: { Text("Appearance") }

                Section {
                    Button("Replay welcome") { showOnboarding() }
                    Link("Privacy Policy", destination: FlowCueProduct.privacyURL)
                    Link("Terms of Use", destination: FlowCueProduct.termsURL)
                } header: { Text("About") } footer: {
                    Text("FlowCue \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · Independent app, not affiliated with any agent provider.")
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(FlowCueTheme.canvas)
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }
}

// MARK: - Paywall and onboarding

private struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var purchasing = false

    private var selectedProduct: Product? {
        subscription.products.first { $0.id == selectedID } ?? subscription.products.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(FlowCueTheme.mint)
                        Text("FlowCue Pro").font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text("Your ideas, available on every device — and ready to continue on your Mac.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        FeatureLine(icon: "arrow.triangle.2.circlepath.icloud", text: "Private iCloud sync across iPhone and Mac")
                        FeatureLine(icon: "text.bubble", text: "Read the last reply from your coding agent")
                        FeatureLine(icon: "paperplane", text: "Send the next message from your phone")
                        FeatureLine(icon: "lock.shield", text: "Same iCloud account; no public relay")
                    }
                    if subscription.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if subscription.products.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Subscriptions are not available right now.")
                                .font(.subheadline)
                            Text("Make sure the app is connected to the App Store, then try again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(subscription.products, id: \.id) { product in
                                Button {
                                    selectedID = product.id
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(product.displayName).font(.headline)
                                            if let trial = subscription.trialDescription(for: product) {
                                                Text(trial).font(.caption).foregroundStyle(FlowCueTheme.mint)
                                            }
                                        }
                                        Spacer()
                                        Text(product.displayPrice).font(.headline)
                                        Image(systemName: selectedProduct?.id == product.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedProduct?.id == product.id ? FlowCueTheme.accent : Color.secondary)
                                    }
                                    .padding(16)
                                    .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            Button {
                                guard let selectedProduct else { return }
                                purchasing = true
                                Task {
                                    await subscription.purchase(selectedProduct)
                                    purchasing = false
                                }
                            } label: {
                                Text(purchasing ? "Purchasing…" : "Continue")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(FlowCueTheme.accent)
                            .disabled(purchasing || selectedProduct == nil)
                        }
                    }
                    Button("Restore purchases") { Task { await subscription.restore() } }
                        .font(.footnote)
                    if let error = subscription.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel in App Store settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Link("Privacy Policy", destination: FlowCueProduct.privacyURL)
                            Link("Terms of Use", destination: FlowCueProduct.termsURL)
                        }
                        .font(.caption)
                    }
                }
                .padding(22)
            }
            .background(FlowCueTheme.canvas)
            .navigationTitle("FlowCue Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: subscription.isPro) { _, isPro in if isPro { dismiss() } }
            .task { if subscription.products.isEmpty { await subscription.refresh() } }
        }
    }
}

private struct FeatureLine: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .background(FlowCueTheme.accent.opacity(0.12), in: Circle())
                .foregroundStyle(FlowCueTheme.accent)
            Text(text).font(.subheadline)
        }
    }
}

private struct ProLockedView: View {
    let title: String
    let message: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(FlowCueTheme.accent)
            VStack(spacing: 8) {
                Text(title).font(.title3.bold()).multilineTextAlignment(.center)
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Upgrade to FlowCue Pro", action: action)
                .buttonStyle(.borderedProminent)
                .tint(FlowCueTheme.accent)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(FlowCueTheme.canvas)
    }
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("sparkles", "Catch the thought before it disappears", "A quiet inbox for ideas, snippets, and next steps. Save now; decide later."),
        ("iphone.and.macbook", "Capture on iPhone. Continue on Mac.", "FlowCue Pro keeps your ideas in sync and lets your Mac hand them to your coding agent."),
        ("lock.shield", "Private by default", "Your ideas stay in your private iCloud account. No public feed, no ads, no tracking.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer()
                        Image(systemName: pages[index].icon)
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(FlowCueTheme.mint)
                        Text(pages[index].title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(pages[index].body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            VStack(spacing: 10) {
                Button(page == pages.count - 1 ? "Get started" : "Continue") {
                    if page == pages.count - 1 { onFinish() } else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .tint(FlowCueTheme.accent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                Button("Skip") { onFinish() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        }
        .background(FlowCueTheme.canvas)
    }
}
