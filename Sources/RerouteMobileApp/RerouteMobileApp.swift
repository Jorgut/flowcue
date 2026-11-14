import SwiftUI
import SwiftData
import StoreKit
import Observation
import UIKit
import Network
import Speech
import AVFoundation
import PhotosUI

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

    private static func token(_ key: @escaping (FlowCueTokens) -> String) -> Color {
        Color(uiColor: UIColor { traits in
            let tokens = FlowCueTokens.tokens(for: traits.userInterfaceStyle == .dark ? .dark : .light)
            return UIColor(flowCueHex: key(tokens))
        })
    }

    static let accent = token { $0.accent }
    static let accentSoft = accent.opacity(0.14)
    static let mint = token { $0.success }
    static let surface = token { $0.surface }
    static let canvas = token { $0.canvas }
    static let hairline = token { $0.border }
    static let textPrimary = token { $0.textPrimary }
    static let textSecondary = token { $0.textSecondary }
    static let textTertiary = token { $0.textTertiary }
    static let warning = token { $0.warning }
    static let failure = token { $0.failure }
    static let onAccent = ink

    /// Airy 的「顶部冷光」；浅色只留很淡的一层，保持表面干净。
    static func topGlow(_ scheme: ColorScheme) -> RadialGradient {
        RadialGradient(
            stops: [
                .init(color: accent.opacity(scheme == .dark ? 0.18 : 0.10), location: 0),
                .init(color: accent.opacity(scheme == .dark ? 0.05 : 0.03), location: 0.46),
                .init(color: .clear, location: 0.78)
            ],
            center: .top,
            startRadius: 0,
            endRadius: 420
        )
    }
}

/// 按设计稿字号渲染，同时跟随 Dynamic Type 放大。
private struct FlowCueFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

private extension View {
    func flowCueFont(
        _ size: CGFloat,
        relativeTo style: Font.TextStyle = .body,
        weight: Font.Weight = .regular
    ) -> some View {
        modifier(FlowCueFontModifier(size: size, relativeTo: style, weight: weight))
    }
}

/// 全屏底色 + Airy 顶部冷光，Home / Agents 共用。
private struct FlowCueScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            FlowCueTheme.canvas
            FlowCueTheme.topGlow(colorScheme)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Subscription

@MainActor
@Observable
final class SubscriptionManager {
    private(set) var products: [Product] = []
    private(set) var isPro = false
    #if DEBUG
    private let previewPro = ProcessInfo.processInfo.arguments.contains("--flowcue-pro-preview")
    #endif
    /// TestFlight builds use a sandbox receipt. During beta, unlock Pro so testers
    /// can exercise sync and remote continuation before subscriptions are live.
    private var isTestFlightBuild: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
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
        #if DEBUG
        isPro = entitled || previewPro || isTestFlightBuild
        #else
        isPro = entitled || isTestFlightBuild
        #endif
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

// MARK: - LAN remote continuation

struct DSHRemoteApproval: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String?
    let toolName: String?
    let callId: String?
    let reason: String?
    let displayReason: String?
    let createdAt: String?

    var title: String { displayReason ?? reason ?? toolName ?? "DSH approval" }
}

struct DSHRemoteDecision: Codable {
    let id: String
    let decision: String
}

struct DSHRemoteApprovalsResponse: Codable {
    let available: Bool
    let pending: [DSHRemoteApproval]
}

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

@MainActor
@Observable
final class LANRemoteController {
    private(set) var discovered: [DiscoveredMac] = []
    private(set) var selected: DiscoveredMac?
    private(set) var threads: [RemoteThreadSnapshot] = []
    private(set) var dshApprovals: [DSHRemoteApproval] = []
    private(set) var dshSessions: [DSHSessionSnapshot] = []
    private(set) var dshSubagents: [DSHSessionSnapshot] = []
    private(set) var dshBridgeAvailable = false
    private(set) var isLoading = false
    private(set) var isScanning = false
    var pairingCode = ""
    var manualAddress = ""
    var statusMessage = ""
    var browserStatus = ""
    var lastError: String?
    private(set) var lastLatencyMs: Int?
    private(set) var lastRefreshAt: Date?
    private(set) var lastAttempted: DiscoveredMac?

    private var browser: NWBrowser?

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let value = args.first(where: { $0.hasPrefix("--flowcue-manual=") }) {
            manualAddress = String(value.dropFirst("--flowcue-manual=".count))
        }
        if let value = args.first(where: { $0.hasPrefix("--flowcue-code=") }) {
            pairingCode = String(value.dropFirst("--flowcue-code=".count))
        }
        if !manualAddress.isEmpty && pairingCode.count == 6 {
            Task { [weak self] in await self?.connectManually() }
        }
        #endif
    }

    var isConnected: Bool { selected != nil }

    func startDiscovery() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_flowcue._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isScanning = true
                    self.browserStatus = "Scanning…"
                case .waiting(let error):
                    self.browserStatus = "Network waiting: \(error.localizedDescription)"
                case .failed(let error):
                    self.isScanning = false
                    self.browserStatus = "Browse failed: \(error.localizedDescription)"
                case .cancelled:
                    self.isScanning = false
                    self.browserStatus = "Scan stopped"
                default:
                    self.browserStatus = "Starting discovery…"
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var found: [DiscoveredMac] = []
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    let id = "\(name)-\(result.endpoint)"
                    if !found.contains(where: { $0.id == id }) {
                        found.append(DiscoveredMac(id: id, name: name, endpoint: result.endpoint))
                    }
                }
                self.discovered = found.sorted { $0.name < $1.name }
                self.isScanning = !found.isEmpty
                self.browserStatus = found.isEmpty ? (self.browserStatus.isEmpty ? "Scanning…" : self.browserStatus) : "Found \(found.count) Mac(s)"
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        isScanning = true
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    func connect(to server: DiscoveredMac) async {
        await connect(endpoint: server.endpoint, displayName: server.name)
    }

    func connectManually() async {
        let parts = manualAddress.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2,
              let rawPort = UInt16(parts[1]),
              let port = NWEndpoint.Port(rawValue: rawPort) else {
            lastError = "Enter the Mac address as IP:port, for example 192.168.1.10:8787."
            return
        }
        await connect(endpoint: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port), displayName: String(parts[0]))
    }

    func retryLastAttempt() async {
        guard let lastAttempted else { return }
        await connect(endpoint: lastAttempted.endpoint, displayName: lastAttempted.name)
    }

    private func connect(endpoint: NWEndpoint, displayName: String) async {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            lastError = "Enter the 6-digit pairing code shown on your Mac."
            return
        }
        lastAttempted = DiscoveredMac(id: displayName, name: displayName, endpoint: endpoint)
        isLoading = true
        defer { isLoading = false }
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let data = try await LANHTTP.request(endpoint: endpoint, method: "GET", path: "/v1/threads", token: code, body: nil)
            lastLatencyMs = max(1, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
            lastRefreshAt = .now
            let snapshots = try JSONDecoder().decode([RemoteThreadSnapshot].self, from: data)
            selected = DiscoveredMac(id: displayName, name: displayName, endpoint: endpoint)
            threads = snapshots.sorted { $0.updatedAt > $1.updatedAt }
            await refreshDSHApprovals()
            await refreshDSHSessions()
            statusMessage = threads.isEmpty ? "Connected. No sessions are available yet." : "Connected."
            lastError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stopDiscovery()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            lastError = "Could not connect. Check the code and that both devices are on the same Wi-Fi."
        }
    }

    func disconnect() {
        selected = nil
        threads = []
        dshApprovals = []
        dshSessions = []
        dshSubagents = []
        dshBridgeAvailable = false
        statusMessage = ""
        lastLatencyMs = nil
        lastRefreshAt = nil
        lastAttempted = nil
        lastError = nil
        startDiscovery()
    }

    func refresh() async {
        guard let selected else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        defer { isLoading = false }
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/threads", token: code, body: nil)
            lastLatencyMs = max(1, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
            lastRefreshAt = .now
            threads = try JSONDecoder().decode([RemoteThreadSnapshot].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
            await refreshDSHApprovals()
            await refreshDSHSessions()
            lastError = nil
        } catch {
            lastError = "Connection lost. Make sure the Mac app is still running on the same Wi-Fi."
        }
    }

    private func refreshDSHSessions() async {
        guard let selected else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/dsh/sessions", token: code, body: nil)
            dshSessions = try JSONDecoder().decode([DSHSessionSnapshot].self, from: data)
        } catch {
            dshSessions = []
        }
    }

    @discardableResult
    func sendDSH(to session: DSHSessionSnapshot, text: String, images: [Data] = []) async -> Bool {
        guard let selected else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        do {
            let encodedImages = images.map { $0.base64EncodedString() }
            let body = try JSONEncoder().encode(DSHRemoteMessage(
                sessionId: session.id,
                text: trimmed.isEmpty ? "Image attachment" : trimmed,
                images: encodedImages.isEmpty ? nil : encodedImages
            ))
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/dsh/send", token: pairingCode, body: body)
            statusMessage = "Sent to DSH."
            return true
        } catch {
            lastError = "DSH session is not live. Open it in DSH on your Mac first, then try again."
            return false
        }
    }

    func dshSubagents(for session: DSHSessionSnapshot) async -> [DSHSessionSnapshot] {
        guard let selected else { return [] }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        do {
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/dsh/subagents/\(encoded)", token: pairingCode, body: nil)
            return try JSONDecoder().decode([DSHSessionSnapshot].self, from: data)
        } catch {
            return []
        }
    }

    func dshMessages(for session: DSHSessionSnapshot) async -> [RemoteConversationMessage] {
        guard let selected else { return [] }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        do {
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/dsh/sessions/\(encoded)/messages", token: pairingCode, body: nil)
            return try JSONDecoder().decode([RemoteConversationMessage].self, from: data)
        } catch {
            return []
        }
    }

    private func refreshDSHApprovals() async {
        guard let selected else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/dsh/approvals", token: code, body: nil)
            let response = try JSONDecoder().decode(DSHRemoteApprovalsResponse.self, from: data)
            dshBridgeAvailable = response.available
            dshApprovals = response.pending
        } catch {
            // The DSH bridge is optional; an absent plugin must not break Codex.
            dshBridgeAvailable = false
            dshApprovals = []
        }
    }

    func refreshApprovals() async {
        await refreshDSHApprovals()
    }

    @discardableResult
    func decideDSH(_ approval: DSHRemoteApproval, decision: String) async -> Bool {
        guard let selected else { return false }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let body = try JSONEncoder().encode(DSHRemoteDecision(id: approval.id, decision: decision))
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/dsh/decide", token: code, body: body)
            dshApprovals.removeAll { $0.id == approval.id }
            statusMessage = decision == "allowed-once" ? "DSH approved." : "DSH rejected."
            return true
        } catch {
            lastError = "DSH approval expired or the bridge is unavailable."
            await refreshDSHApprovals()
            return false
        }
    }

    func messages(for thread: RemoteThreadSnapshot) async -> [RemoteConversationMessage] {
        guard let selected else { return [] }
        let encoded = thread.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thread.id
        do {
            let data = try await LANHTTP.request(endpoint: selected.endpoint, method: "GET", path: "/v1/threads/\(encoded)/messages", token: pairingCode, body: nil)
            return try JSONDecoder().decode([RemoteConversationMessage].self, from: data)
        } catch {
            return []
        }
    }

    @discardableResult
    func send(to thread: RemoteThreadSnapshot, text: String, images: [Data] = []) async -> Bool {
        guard let selected else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        let phoneID: UUID
        if let raw = UserDefaults.standard.string(forKey: "FlowCue.remotePhoneID"), let id = UUID(uuidString: raw) {
            phoneID = id
        } else {
            phoneID = UUID()
            UserDefaults.standard.set(phoneID.uuidString, forKey: "FlowCue.remotePhoneID")
        }
        let encodedImages = images.map { $0.base64EncodedString() }
        let command = RemoteCommand(
            phoneID: phoneID,
            executorID: thread.executorID,
            threadID: thread.id,
            text: trimmed,
            images: encodedImages.isEmpty ? nil : encodedImages
        )
        do {
            let body = try JSONEncoder().encode(command)
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/send", token: pairingCode, body: body)
            statusMessage = "Sent to your Mac. The reply will appear when it is ready."
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
            return true
        } catch {
            lastError = "Could not send. Check that your Mac is still online."
            return false
        }
    }
}

private enum LANHTTP {
    static func request(endpoint: NWEndpoint, method: String, path: String, token: String?, body: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let runner = LANHTTPRunner(endpoint: endpoint, method: method, path: path, token: token, body: body, continuation: continuation)
            runner.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                runner.fail(URLError(.timedOut))
            }
        }
    }
}

private final class LANHTTPRunner: @unchecked Sendable {
    private let connection: NWConnection
    private let requestData: Data
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var continuation: CheckedContinuation<Data, Error>?

    init(endpoint: NWEndpoint, method: String, path: String, token: String?, body: Data?, continuation: CheckedContinuation<Data, Error>) {
        self.connection = NWConnection(to: endpoint, using: .tcp)
        var request = "\(method) \(path) HTTP/1.1\r\nHost: flowcue.local\r\nConnection: close\r\n"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        if let body {
            request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        request += "\r\n"
        var data = Data(request.utf8)
        if let body { data.append(body) }
        self.requestData = data
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.connection.send(content: self.requestData, completion: .contentProcessed { error in
                    if let error { self.fail(error) } else { self.receive() }
                })
            } else if case .failed(let error) = state {
                self.fail(error)
            }
        }
        connection.start(queue: .global())
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(throwing: error)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let error { self.fail(error); return }
            if let body = self.parseResponse() {
                self.succeed(body)
            } else if isComplete {
                self.fail(URLError(.badServerResponse))
            } else {
                self.receive()
            }
        }
    }

    private func parseResponse() -> Data? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) ?? ""
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.contains(" 200 ") else {
            return nil
        }
        var contentLength = 0
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.split(separator: ":").dropFirst().joined().trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        return buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
    }

    private func succeed(_ body: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(returning: body)
    }
}

// MARK: - App

@main
struct RerouteMobileApp: App {
    @State private var store: IdeaDockStore?
    @State private var syncController: IdeaSyncController?
    @State private var subscription = SubscriptionManager()
    @State private var remoteController = LANRemoteController()
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
    @Bindable var remoteController: LANRemoteController
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage("FlowCue.hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: FlowCueTab = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let value = arguments.first(where: { $0.hasPrefix("--flowcue-tab=") }) {
            switch String(value.dropFirst("--flowcue-tab=".count)) {
            case "agents": return .agents
            case "settings": return .settings
            default: return .inbox
            }
        }
        if arguments.contains("--flowcue-agents") { return .agents }
        #endif
        return .inbox
    }()

    var body: some View {
        TabView(selection: $tab) {
            InboxView(store: store, syncController: syncController, remoteController: remoteController, tab: $tab)
                .tag(FlowCueTab.inbox)
                .toolbar(.hidden, for: .tabBar)
            AgentsView(controller: remoteController, tab: $tab)
                .tag(FlowCueTab.agents)
                .toolbar(.hidden, for: .tabBar)
            SettingsView(
                store: store,
                syncController: syncController,
                remoteController: remoteController,
                tab: $tab,
                showOnboarding: { hasSeenOnboarding = false }
            )
            .tag(FlowCueTab.settings)
            .toolbar(.hidden, for: .tabBar)
        }
        .tint(FlowCueTheme.accent)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await syncController.runWhileActive()
        }
    }
}

// MARK: - Home chrome

private enum HomeLayout {
    static let margin: CGFloat = 18
    static let barMargin: CGFloat = 14
    static let rowSpacing: CGFloat = 11
}

/// 角色的 96 网格几何，与 `docs/design/ios/` 里的 SVG 同源。
private struct FlowCueFaceMark: View {
    var ink: Color
    var smile: Color

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 96
            context.scaleBy(x: unit, y: unit)

            for center in [CGPoint(x: 32, y: 34), CGPoint(x: 64, y: 34)] {
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                    with: .color(ink)
                )
            }
            context.fill(
                Path(roundedRect: CGRect(x: 42, y: 40, width: 12, height: 18), cornerRadius: 6),
                with: .color(ink)
            )

            var mouth = Path()
            mouth.move(to: CGPoint(x: 26, y: 64))
            mouth.addQuadCurve(to: CGPoint(x: 70, y: 64), control: CGPoint(x: 48, y: 88.3))
            context.stroke(
                mouth,
                with: .color(smile),
                style: StrokeStyle(lineWidth: 14, lineCap: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private enum FlowCueGlyphKind {
    case spark, plane, face
}

/// 底部导航的线性图标，路径取自设计稿（20 网格）。
private struct FlowCueGlyph: View {
    let kind: FlowCueGlyphKind
    var ink: Color
    var smile: Color?

    var body: some View {
        switch kind {
        case .face:
            FlowCueFaceMark(ink: ink, smile: smile ?? ink)
        case .spark:
            Canvas { context, size in
                let unit = min(size.width, size.height) / 20
                context.scaleBy(x: unit, y: unit)
                var path = Path()
                path.move(to: CGPoint(x: 10, y: 3.2))
                path.addLine(to: CGPoint(x: 11.7, y: 7.8))
                path.addLine(to: CGPoint(x: 16.3, y: 9.5))
                path.addLine(to: CGPoint(x: 11.7, y: 11.2))
                path.addLine(to: CGPoint(x: 10, y: 15.8))
                path.addLine(to: CGPoint(x: 8.3, y: 11.2))
                path.addLine(to: CGPoint(x: 3.7, y: 9.5))
                path.addLine(to: CGPoint(x: 8.3, y: 7.8))
                path.closeSubpath()
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
            }
        case .plane:
            Canvas { context, size in
                let unit = min(size.width, size.height) / 20
                context.scaleBy(x: unit, y: unit)
                var path = Path()
                path.move(to: CGPoint(x: 3.6, y: 16.4))
                path.addLine(to: CGPoint(x: 16.4, y: 10))
                path.addLine(to: CGPoint(x: 3.6, y: 3.6))
                path.addLine(to: CGPoint(x: 5.8, y: 10))
                path.closeSubpath()
                path.move(to: CGPoint(x: 5.8, y: 10))
                path.addLine(to: CGPoint(x: 16.4, y: 10))
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}

/// 悬浮胶囊导航：三项，44pt 热区，AX 字号下只留图标。
private struct FlowCueTabBar: View {
    @Binding var selection: FlowCueTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Item {
        let tab: FlowCueTab
        let title: String
        let glyph: FlowCueGlyphKind
    }

    private let items: [Item] = [
        Item(tab: .inbox, title: "Ideas", glyph: .spark),
        Item(tab: .agents, title: "Agents", glyph: .plane),
        Item(tab: .settings, title: "Me", glyph: .face)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                itemButton(item)
            }
        }
        .frame(height: 44)
        .background(
            Capsule()
                .fill(FlowCueTheme.surface)
                .overlay(Capsule().strokeBorder(FlowCueTheme.hairline))
        )
        .padding(.horizontal, HomeLayout.barMargin)
        .padding(.vertical, 6)
        .background(FlowCueTheme.canvas)
    }

    private func itemButton(_ item: Item) -> some View {
        let isSelected = selection == item.tab
        let tint = isSelected ? FlowCueTheme.accent : FlowCueTheme.textSecondary
        return Button {
            guard selection != item.tab else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selection = item.tab
        } label: {
            VStack(spacing: 3) {
                FlowCueGlyph(kind: item.glyph, ink: tint, smile: tint)
                    .frame(width: 16, height: 16)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(item.title)
                        .flowCueFont(9, relativeTo: .caption2, weight: .medium)
                        .tracking(0.54)
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Home data and state probes

private enum HomeFilter: String, CaseIterable, Identifiable {
    case all, drafts, queued, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .drafts: "Drafts"
        case .queued: "Queued"
        case .archived: "Archived"
        }
    }

    func matches(_ status: CaptureStatus) -> Bool {
        switch self {
        case .all: status != .draft && status != .archived
        case .drafts: status == .saved
        case .queued: status == .queueing || status == .queued
        case .archived: status == .archived
        }
    }
}

private enum HomeFormat {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func meta(for date: Date) -> String {
        Calendar.current.isDateInToday(date) ? time.string(from: date) : day.string(from: date).uppercased()
    }
}

private enum FlowCueLinkFormat {
    static func latency(_ milliseconds: Int?) -> String? {
        guard let milliseconds else { return nil }
        if milliseconds >= 1000 {
            return String(format: "%.1fs", Double(milliseconds) / 1000)
        }
        return "\(milliseconds)ms"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return date.formatted(.relative(presentation: .named))
    }

    /// 列表右侧的短时间：2m / 1h / 3d。
    static func shortRelative(_ date: Date) -> String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// 列表摘要只保留纯文本，去掉常见 Markdown 记号。
    static func plainSnippet(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Bonjour 服务名固定为 FlowCue，手动连接只有 IP；统一映射成可读设备名。
    static func deviceName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "FlowCue Mac" }
        if raw.contains(".") || raw.contains(":") { return "FlowCue Mac" }
        if raw == "FlowCue" { return "FlowCue Mac" }
        return raw
    }

    /// 设备指纹：只用哈希显示 8 位，避免把配对码直接留在屏幕上。
    static func fingerprint(_ seed: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let hex = String(format: "%016llx", hash).uppercased()
        let start = hex.prefix(4)
        let end = hex.dropFirst(8).prefix(4)
        return "\(start) · \(end)"
    }
}

private enum HomeStatus {
    static func label(_ status: CaptureStatus) -> String {
        switch status {
        case .draft, .saved: "DRAFT"
        case .queueing, .queued: "QUEUED"
        case .failed: "FAILED"
        case .unknown: "NEEDS CHECK"
        case .archived: "ARCHIVED"
        }
    }

    static func tint(_ status: CaptureStatus) -> Color {
        switch status {
        case .draft, .saved: FlowCueTheme.textSecondary
        case .queueing: FlowCueTheme.accent
        case .queued: FlowCueTheme.mint
        case .failed: FlowCueTheme.failure
        case .unknown: FlowCueTheme.warning
        case .archived: FlowCueTheme.textTertiary
        }
    }
}

/// 只用于 DEBUG 截图与状态走查；Release 永远返回空值。
private enum HomePreview {
    static let requestedState: String? = {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-home-state=")
        }) else { return nil }
        return String(argument.dropFirst("--flowcue-home-state=".count))
        #else
        return nil
        #endif
    }()

    static var usesSamples: Bool {
        requestedState == "demo" || requestedState == "syncFailed" || requestedState == "offline"
    }
    static var forcesEmpty: Bool { requestedState == "empty" }
    static var forcesLoading: Bool { requestedState == "loading" }
    static var forcesSyncFailure: Bool { requestedState == "syncFailed" }
    static var forcesOffline: Bool { requestedState == "offline" }

    static let samples: [CaptureItem] = {
        #if DEBUG
        [
            sample("Retry backoff feels too slow", hour: 21, minute: 4, status: .saved),
            sample("Character should blink once on save", hour: 20, minute: 51, status: .queueing),
            sample("Share sheet for Safari", hour: 18, minute: 22, status: .queued),
            sample("Widget for quick capture", hour: 17, minute: 40, status: .saved)
        ]
        #else
        []
        #endif
    }()

    #if DEBUG
    private static func sample(
        _ text: String,
        hour: Int,
        minute: Int,
        status: CaptureStatus
    ) -> CaptureItem {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return CaptureItem(
            id: UUID(),
            text: text,
            sourceThreadID: nil,
            targetThreadID: nil,
            sourceTitle: nil,
            targetTitle: nil,
            createdAt: date,
            updatedAt: date,
            status: status,
            statusBeforeArchive: nil,
            lastError: nil
        )
    }
    #endif
}

@MainActor
@Observable
private final class FlowCueNetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

// MARK: - Inbox

private struct InboxView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    @Binding var tab: FlowCueTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter: HomeFilter = .all
    @State private var network = FlowCueNetworkMonitor()
    @State private var searchDictation = VoiceDictation()
    @State private var searchBase = ""
    @State private var chipsCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var hasCompletedInitialSync = false
    @FocusState private var captureFocused: Bool
    @ScaledMetric(relativeTo: .caption) private var searchHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var chipHeight: CGFloat = 26
    @FocusState private var searchFocused: Bool

    private static let syncFailureMessages: Set<String> = [
        "暂时无法同步，本地想法已保留",
        "iCloud 账户已更换，同步已暂停",
        "想法存在编辑冲突，原文已保留"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, HomeLayout.margin)
                    .padding(.top, 12)
                searchField
                    .padding(.horizontal, HomeLayout.margin)
                    .padding(.top, 12)
                chips
                banners
                content
                if let note = store.notification, note.kind != .success {
                    HomeNoticeStrip(kind: note.kind, message: L10n.text(note.message)) {
                        store.notification = nil
                    }
                    .padding(.horizontal, HomeLayout.margin)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .task(id: note.id) {
                        try? await Task.sleep(for: .seconds(4))
                        if store.notification?.id == note.id { store.notification = nil }
                    }
                }
                HomeCaptureBar(store: store, focused: $captureFocused)
                if !captureFocused && !searchFocused {
                    FlowCueTabBar(selection: $tab)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: captureFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: searchFocused)
            .background { FlowCueScreenBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .task { network.start() }
            .onChange(of: syncController.isSyncing) { _, isSyncing in
                if !isSyncing { hasCompletedInitialSync = true }
            }
            .onDisappear {
                network.stop()
                searchDictation.stop()
            }
            .alert(
                "Voice input unavailable",
                isPresented: Binding(
                    get: { searchDictation.error != nil },
                    set: { if !$0 { searchDictation.error = nil } }
                )
            ) {
                Button("OK", role: .cancel) { searchDictation.error = nil }
            } message: {
                Text(searchDictation.error ?? "")
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text("FlowCue")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .tracking(-0.14)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Spacer()
            Button {
                tab = .settings
            } label: {
                ZStack {
                    Circle().fill(FlowCueTheme.surface)
                    Circle().strokeBorder(FlowCueTheme.hairline)
                    FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Me")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(FlowCueTheme.textSecondary)
                .accessibilityHidden(true)
            TextField("Search your ideas", text: $store.searchText)
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .submitLabel(.search)
            Button {
                toggleSearchDictation()
            } label: {
                Image(systemName: searchDictation.isRecording ? "waveform" : "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(searchDictation.isRecording ? FlowCueTheme.accent : FlowCueTheme.textSecondary.opacity(0.7))
                    .frame(width: 42, height: searchHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchDictation.isRecording ? "Stop voice search" : "Search by voice")
        }
        .padding(.leading, 13)
        .padding(.trailing, 4)
        .frame(minHeight: searchHeight)
        .background(
            Capsule()
                .fill(FlowCueTheme.surface)
                .overlay(Capsule().strokeBorder(FlowCueTheme.hairline))
        )
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(HomeFilter.allCases) { option in
                    chip(option)
                }
            }
            .padding(.horizontal, HomeLayout.margin)
        }
        .frame(height: chipsCollapsed ? 0 : chipHeight)
        .opacity(chipsCollapsed ? 0 : 1)
        .clipped()
        .padding(.top, chipsCollapsed ? 0 : 10)
        .accessibilityHidden(chipsCollapsed)
    }

    private func chip(_ option: HomeFilter) -> some View {
        let isSelected = filter == option
        return Button {
            guard filter != option else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            filter = option
        } label: {
            Text(option.title)
                .flowCueFont(11.5, relativeTo: .caption, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: chipHeight)
                .background(
                    Capsule()
                        .fill(isSelected ? FlowCueTheme.accentSoft : Color.clear)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : FlowCueTheme.hairline)
                )
                .foregroundStyle(isSelected ? FlowCueTheme.accent : FlowCueTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var banners: some View {
        if isOffline {
            FlowCueInlineBanner(
                kind: .warning,
                title: "You are offline. Ideas are saved on this iPhone."
            )
            .padding(.horizontal, HomeLayout.margin)
            .padding(.top, 10)
        } else if showsSyncFailure {
            FlowCueInlineBanner(
                kind: .failure,
                title: "Sync failed — changes saved locally",
                actionTitle: "Retry",
                action: { Task { await syncController.synchronizeNow() } }
            )
            .padding(.horizontal, HomeLayout.margin)
            .padding(.top, 10)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 0) {
                sectionHeader
                    .padding(.horizontal, HomeLayout.margin)
                    .padding(.top, 16)
                HomeSkeletonList()
                    .padding(.horizontal, HomeLayout.margin)
                    .padding(.top, 4)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else if showsEmptyState {
            emptyState
        } else {
            sectionHeader
                .padding(.horizontal, HomeLayout.margin)
                .padding(.top, 16)
            if visibleIdeas.isEmpty {
                filteredEmptyState
            } else {
                ideaList
            }
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Text(
                store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No \(filter.title.lowercased()) ideas"
                    : "No ideas match your search"
            )
            .flowCueFont(14, relativeTo: .subheadline)
            .foregroundStyle(FlowCueTheme.textSecondary)
            Button("Show all ideas") {
                store.searchText = ""
                filter = .all
            }
            .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
            .foregroundStyle(FlowCueTheme.accent)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isOffline: Bool {
        HomePreview.forcesOffline || !network.isOnline
    }

    private var showsSyncFailure: Bool {
        if HomePreview.forcesSyncFailure { return true }
        guard HomePreview.requestedState == nil else { return false }
        return syncController.isEnabled && Self.syncFailureMessages.contains(syncController.statusMessage)
    }

    private var isLoading: Bool {
        if HomePreview.forcesLoading { return true }
        guard HomePreview.requestedState == nil else { return false }
        return !hasCompletedInitialSync
            && syncController.isEnabled
            && syncController.isSyncing
            && store.captures.isEmpty
    }

    private var baseCaptures: [CaptureItem] {
        HomePreview.usesSamples ? HomePreview.samples : store.captures
    }

    private var activeIdeas: [CaptureItem] {
        baseCaptures.filter { $0.status != .draft && $0.status != .archived }
    }

    private var visibleIdeas: [CaptureItem] {
        let normalizedSearch = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return baseCaptures.filter { capture in
            guard capture.status != .draft, filter.matches(capture.status) else { return false }
            guard !normalizedSearch.isEmpty else { return true }
            return capture.text.localizedCaseInsensitiveContains(normalizedSearch)
                || capture.sourceTitle?.localizedCaseInsensitiveContains(normalizedSearch) == true
                || capture.targetTitle?.localizedCaseInsensitiveContains(normalizedSearch) == true
        }
    }

    private var showsEmptyState: Bool {
        guard visibleIdeas.isEmpty else { return false }
        if HomePreview.forcesEmpty { return true }
        let normalizedSearch = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return activeIdeas.isEmpty && normalizedSearch.isEmpty && filter == .all
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Ideas")
                    .flowCueFont(26, relativeTo: .title2, weight: .semibold)
                    .tracking(-0.52)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text(isLoading ? " · —" : " · \(visibleIdeas.count)")
                    .flowCueFont(16, relativeTo: .callout, weight: .medium)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer()
            if !dynamicTypeSize.isAccessibilitySize {
                statusLine
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isLoading {
            Text("—")
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundStyle(FlowCueTheme.textSecondary)
        } else if remoteController.isConnected && !isOffline {
            HStack(spacing: 5) {
                Circle()
                    .fill(FlowCueTheme.mint)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text("Codex · \(FlowCueLinkFormat.latency(remoteController.lastLatencyMs) ?? "online")")
            }
            .flowCueFont(10, relativeTo: .caption2)
            .tracking(0.6)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Codex online")
        } else {
            Text("\(activeIdeas.count) LOCAL")
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundStyle(FlowCueTheme.textSecondary)
        }
    }

    private var ideaList: some View {
        ScrollView {
            ScrollViewOffsetReader()
            LazyVStack(spacing: 0) {
                ForEach(visibleIdeas) { idea in
                    NavigationLink {
                        IdeaDetailView(store: store, capture: idea)
                    } label: {
                        HomeIdeaRow(capture: idea)
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(FlowCueTheme.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, HomeLayout.margin)
            .padding(.top, 4)
        }
        .coordinateSpace(name: HomeScrollSpace.name)
        .scrollDismissesKeyboard(.interactively)
        .onPreferenceChange(HomeScrollOffsetKey.self) { offset in
            updateChipVisibility(offset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 92, height: 92)
            Text("No ideas yet")
                .flowCueFont(19, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 22)
            Text("Capture the first thought. You can send it to your agents later.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 260)
                .padding(.top, 10)
            Button {
                captureFocused = true
            } label: {
                Text("Capture the first idea →")
                    .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.accent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Capture the first idea")
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, HomeLayout.margin)
    }

    // MARK: Behaviour

    private func updateChipVisibility(_ offset: CGFloat) {
        let delta = offset - lastScrollOffset
        lastScrollOffset = offset
        guard !captureFocused else { return }
        if delta < -2 && offset < -12 && !chipsCollapsed {
            // 下滚 > 12pt：200ms 收起。
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { chipsCollapsed = true }
        } else if delta > 2 && chipsCollapsed {
            // 上滚：240ms 滑回。
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { chipsCollapsed = false }
        }
    }

    private func toggleSearchDictation() {
        if searchDictation.isRecording {
            searchDictation.stop()
            return
        }
        searchBase = store.searchText
        searchDictation.start { transcript in
            store.searchText = searchBase.isEmpty ? transcript : searchBase + " " + transcript
        }
    }
}

private enum HomeScrollSpace {
    static let name = "home-scroll"
}

private struct HomeScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewOffsetReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: HomeScrollOffsetKey.self,
                value: proxy.frame(in: .named(HomeScrollSpace.name)).minY
            )
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

private struct HomeIdeaRow: View {
    let capture: CaptureItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: HomeLayout.rowSpacing) {
            Circle()
                .fill(HomeStatus.tint(capture.status))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.text)
                    .flowCueFont(14, relativeTo: .subheadline)
                    .lineSpacing(1)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text("\(HomeStatus.label(capture.status)) · \(HomeFormat.meta(for: capture.updatedAt))")
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .tracking(0.2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.5))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(capture.text), \(HomeStatus.label(capture.status)), \(HomeFormat.meta(for: capture.updatedAt))"
        )
    }
}

private struct FlowCueInlineBanner: View {
    enum Kind { case warning, failure }

    let kind: Kind
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    private var tint: Color {
        kind == .warning ? FlowCueTheme.warning : FlowCueTheme.failure
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(title)
                .flowCueFont(11, relativeTo: .caption2)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .flowCueFont(11, relativeTo: .caption2, weight: .semibold)
                        .foregroundStyle(tint)
                        .padding(.vertical, 4)
                        .padding(.leading, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                .fill(FlowCueTheme.textPrimary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                .strokeBorder(tint.opacity(0.33))
        )
        .accessibilityElement(children: .contain)
    }
}

private struct HomeNoticeStrip: View {
    let kind: DockNotificationKind
    let message: String
    let onDismiss: () -> Void

    private var tint: Color {
        kind == .warning ? FlowCueTheme.warning : FlowCueTheme.failure
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(message)
                .flowCueFont(11, relativeTo: .caption2)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusInline, style: .continuous)
                .strokeBorder(tint.opacity(0.33))
        )
    }
}

private struct HomeSkeletonList: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(alignment: .top, spacing: HomeLayout.rowSpacing) {
                    Circle()
                        .fill(FlowCueTheme.hairline)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(FlowCueTheme.hairline)
                            .frame(height: 11)
                            .frame(maxWidth: 230, alignment: .leading)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(FlowCueTheme.hairline)
                            .frame(width: 90, height: 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 13)
                Rectangle()
                    .fill(FlowCueTheme.hairline)
                    .frame(height: 1)
            }
        }
        .accessibilityLabel("Loading ideas")
    }
}

private struct HomeCaptureBar: View {
    @Bindable var store: IdeaDockStore
    @FocusState.Binding var focused: Bool
    @State private var dictation = VoiceDictation()
    @State private var baseText = ""

    private var canSubmit: Bool {
        !store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 9) {
            Button {
                focused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17))
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .frame(width: 28, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Capture an idea")

            TextField("Capture an idea", text: $store.draftText, axis: .vertical)
                .lineLimit(1...4)
                .flowCueFont(13.5, relativeTo: .footnote)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { submit() }

            Button {
                toggleDictation()
            } label: {
                Image(systemName: dictation.isRecording ? "waveform" : "mic")
                    .font(.system(size: 16))
                    .foregroundStyle(dictation.isRecording ? FlowCueTheme.accent : FlowCueTheme.textSecondary.opacity(0.6))
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate an idea")

            ZStack {
                Circle()
                    .fill(FlowCueTheme.accent)
                    .frame(width: 32, height: 32)
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel("Save idea")
            }
            .frame(width: 44, height: 44)
        }
        .padding(.leading, 13)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(FlowCueTheme.surface)
                .overlay(Capsule().strokeBorder(FlowCueTheme.hairline))
        )
        .padding(.horizontal, HomeLayout.barMargin)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .alert(
            "Voice input unavailable",
            isPresented: Binding(
                get: { dictation.error != nil },
                set: { if !$0 { dictation.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
    }

    private func toggleDictation() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        baseText = store.draftText
        dictation.start { transcript in
            store.draftText = baseText.isEmpty ? transcript : baseText + " " + transcript
        }
    }

    private func submit() {
        dictation.stop()
        guard canSubmit, store.saveCurrent() != nil else { return }
        store.notification = nil
        focused = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

/// 只用于 DEBUG 状态走查；Release 永远返回 nil。
private enum AgentsPreview {
    static let requestedState: String? = {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-agents-state=")
        }) else { return nil }
        return String(argument.dropFirst("--flowcue-agents-state=".count))
        #else
        return nil
        #endif
    }()

    static var forcesDiscovering: Bool { requestedState == "discovering" }
    static var forcesCannotReach: Bool { requestedState == "cannotReach" }
    static var forcesOffline: Bool { requestedState == "offline" }
}

private enum AgentsLayout {
    static let margin: CGFloat = 18
    static let deviceIcon: CGFloat = 34
    static let agentIcon: CGFloat = 26
}

private struct AgentsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .flowCueFont(10, relativeTo: .caption2, weight: .regular)
            .tracking(1.4)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AgentsFaceBadge: View {
    let size: CGFloat
    let faceSize: CGFloat
    var ink: Color = FlowCueTheme.textPrimary
    var smile: Color = FlowCueTheme.accent
    var background: Color = FlowCueTheme.surface
    var cornerRadius: CGFloat = FlowCueMetrics.radiusInline
    var bordered: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
            if bordered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FlowCueTheme.hairline)
            }
            FlowCueFaceMark(ink: ink, smile: smile)
                .frame(width: faceSize, height: faceSize)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct AgentsAddBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    FlowCueTheme.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            Image(systemName: "plus")
                .font(.system(size: 14))
                .foregroundStyle(FlowCueTheme.textSecondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 34pt 设备卡，对应设计稿 DEVICES 区。
private struct AgentsDeviceCard: View {
    let title: String
    let isOnline: Bool
    let latency: String?

    var body: some View {
        HStack(spacing: 11) {
            AgentsFaceBadge(
                size: AgentsLayout.deviceIcon,
                faceSize: 22,
                background: FlowCueTheme.canvas,
                cornerRadius: FlowCueMetrics.radiusInline,
                bordered: true
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(isOnline ? FlowCueTheme.mint : FlowCueTheme.failure)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(isOnline ? "online" : "offline")
                    if isOnline, let latency {
                        Text(" · \(latency)")
                    }
                }
                .flowCueFont(10, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.8))
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusPanel, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusPanel, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: FlowCueMetrics.radiusPanel, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(isOnline ? "online" : "offline")\(latency.map { ", \($0)" } ?? "")"
        )
    }
}

/// 26pt agent 行，对应设计稿 AGENTS ON THIS MAC 区。
private struct AgentsAgentRow: View {
    let title: String
    let meta: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            AgentsFaceBadge(
                size: AgentsLayout.agentIcon,
                faceSize: 18,
                ink: isActive ? FlowCueTheme.textPrimary : FlowCueTheme.textSecondary,
                smile: isActive ? FlowCueTheme.accent : FlowCueTheme.textSecondary,
                background: FlowCueTheme.surface,
                cornerRadius: 8
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text(meta)
                    .flowCueFont(10, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if isActive {
                Circle()
                    .fill(FlowCueTheme.mint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .strokeBorder(FlowCueTheme.textSecondary, lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(meta), \(isActive ? "active" : "idle")")
    }
}

private struct AgentsAddRow: View {
    var body: some View {
        HStack(spacing: 9) {
            AgentsAddBadge(size: AgentsLayout.agentIcon)
            Text("Add agent")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Spacer()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityLabel("Add agent")
    }
}

private struct AgentsRingSpinner: View {
    var size: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(FlowCueTheme.hairline, lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(FlowCueTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: spinning
                )
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
        .accessibilityHidden(true)
    }
}

private struct AgentsView: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingPaywall = false
    @State private var showingPairing = AgentsPreview.requestedState == "pairing"
    @State private var showingAddAgent = AgentsPreview.requestedState == "addAgent"
    @State private var showingRemote = AgentsPreview.requestedState == "remote"
    @State private var showingCodex = AgentsPreview.requestedState == "codex"
    @State private var showingDSH = AgentsPreview.requestedState == "dsh"
    @State private var network = FlowCueNetworkMonitor()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                agentsHeader

                Group {
                    if subscription.isLoading {
                        ProgressView()
                            .tint(FlowCueTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !subscription.isPro {
                        ProLockedView(
                            title: "Continue sessions from your phone",
                            message: "FlowCue Pro connects directly to your Mac on the same Wi-Fi. Read the last reply and send the next message without opening your laptop.",
                            action: { showingPaywall = true }
                        )
                    } else if showsCannotReach {
                        cannotReachContent
                    } else if controller.isConnected {
                        connectedContent
                    } else if showsDiscovering {
                        discoveringContent
                    } else {
                        emptyContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background { FlowCueScreenBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingRemote) {
                RemoteDeviceView(controller: controller, tab: $tab)
            }
            .navigationDestination(isPresented: $showingCodex) {
                CodexAgentView(controller: controller, tab: $tab)
            }
            .navigationDestination(isPresented: $showingDSH) {
                DSHAgentView(controller: controller, tab: $tab)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FlowCueTabBar(selection: $tab)
            }
            .task { network.start() }
            .task {
                while !Task.isCancelled {
                    if controller.isConnected {
                        await controller.refresh()
                    }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onDisappear {
                network.stop()
                controller.stopDiscovery()
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingPairing) {
                PairMacSheet(controller: controller)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingAddAgent) {
                AddAgentSheet {
                    await controller.refresh()
                }
                .presentationDetents([.large])
            }
        }
    }

    private var agentsHeader: some View {
        ZStack {
            Text("Agents")
                .flowCueFont(17, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            HStack {
                Spacer()
                if subscription.isPro && !subscription.isLoading {
                    Button {
                        toolbarAction()
                    } label: {
                        Image(systemName: toolbarSymbol)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(toolbarSymbol == "plus" ? "Pair a Mac" : "Refresh agents")
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 10)
    }

    // MARK: State

    private var isOffline: Bool {
        AgentsPreview.forcesOffline || !network.isOnline
    }

    private var showsCannotReach: Bool {
        if AgentsPreview.forcesCannotReach { return true }
        return !controller.isConnected && controller.lastError != nil && controller.lastAttempted != nil
    }

    private var showsDiscovering: Bool {
        if AgentsPreview.forcesDiscovering { return true }
        return !controller.isConnected
            && controller.lastAttempted == nil
            && controller.isScanning
            && controller.discovered.isEmpty
    }

    private var toolbarSymbol: String {
        if AgentsPreview.requestedState != nil {
            return "arrow.clockwise"
        }
        if controller.isConnected || controller.lastAttempted != nil || controller.isScanning {
            return "arrow.clockwise"
        }
        return "plus"
    }

    private func toolbarAction() {
        if controller.isConnected {
            Task { await controller.refresh() }
        } else if controller.lastAttempted != nil {
            Task { await controller.retryLastAttempt() }
        } else if controller.isScanning {
            controller.stopDiscovery()
            controller.startDiscovery()
        } else {
            showingPairing = true
        }
    }

    private var deviceName: String {
        FlowCueLinkFormat.deviceName(controller.selected?.name ?? controller.lastAttempted?.name)
    }

    // MARK: Connected

    private var connectedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isOffline {
                    FlowCueInlineBanner(
                        kind: .warning,
                        title: "No network. Agents need Wi-Fi."
                    )
                    .padding(.top, 10)
                } else if let message = controller.lastError {
                    FlowCueInlineBanner(
                        kind: .failure,
                        title: message,
                        actionTitle: "Retry",
                        action: { Task { await controller.refresh() } }
                    )
                    .padding(.top, 10)
                }

                AgentsSectionHeader(title: "DEVICES")
                    .padding(.top, 14)

                NavigationLink {
                    RemoteDeviceView(controller: controller, tab: $tab)
                } label: {
                    AgentsDeviceCard(
                        title: deviceName,
                        isOnline: !isOffline,
                        latency: FlowCueLinkFormat.latency(controller.lastLatencyMs)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                AgentsSectionHeader(title: "AGENTS ON THIS MAC")
                    .padding(.top, 16)

                VStack(spacing: 0) {
                    NavigationLink {
                        CodexAgentView(controller: controller, tab: $tab)
                    } label: {
                        AgentsAgentRow(
                            title: "Codex",
                            meta: codexMeta,
                            isActive: !isOffline && !controller.threads.isEmpty
                        )
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(FlowCueTheme.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)

                    NavigationLink {
                        DSHAgentView(controller: controller, tab: $tab)
                    } label: {
                        AgentsAgentRow(
                            title: "DSH",
                            meta: dshMeta,
                            isActive: !isOffline && controller.dshBridgeAvailable
                        )
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(FlowCueTheme.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)

                    Button {
                        showingAddAgent = true
                    } label: {
                        AgentsAddRow()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.bottom, 28)
        }
        .refreshable { await controller.refresh() }
    }

    private var codexMeta: String {
        let count = controller.threads.count
        return count == 0 ? "No sessions yet" : "\(count) session\(count == 1 ? "" : "s")"
    }

    private var dshMeta: String {
        let count = controller.dshSessions.count
        var parts: [String] = [count == 0 ? "No sessions yet" : "\(count) session\(count == 1 ? "" : "s")"]
        if !controller.dshApprovals.isEmpty {
            parts.append("\(controller.dshApprovals.count) pending")
        } else if !controller.dshBridgeAvailable {
            parts = ["Bridge not installed"]
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Empty / discovery / error

    private var emptyContent: some View {
        VStack(spacing: 0) {
            if isOffline {
                FlowCueInlineBanner(
                    kind: .warning,
                    title: "No network. Agents need Wi-Fi."
                )
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 80, height: 80)
            Text("No agents yet")
                .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 18)
            Text("Pair a Mac to continue your sessions from your phone.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 260)
                .padding(.top, 6)
            Button {
                showingPairing = true
            } label: {
                Text("Pair a Mac")
                    .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(FlowCueTheme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discoveringContent: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            AgentsRingSpinner(size: 34)
            Text("Looking for devices")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 4)
            Text("Make sure your Mac is on the same Wi-Fi and FlowCue is running.")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 280)
            Button("Cancel") {
                controller.stopDiscovery()
            }
            .flowCueFont(12, relativeTo: .caption)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .padding(.top, 4)
            .accessibilityLabel("Cancel discovery")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AgentsLayout.margin)
    }

    private var cannotReachContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isOffline {
                    FlowCueInlineBanner(
                        kind: .warning,
                        title: "No network. Agents need Wi-Fi."
                    )
                    .padding(.top, 10)
                }

                Button {
                    showingPairing = true
                } label: {
                    AgentsDeviceCard(
                        title: deviceName,
                        isOnline: false,
                        latency: nil
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                FlowCueInlineBanner(
                    kind: .failure,
                    title: "Can't reach this Mac",
                    actionTitle: "Retry",
                    action: { Task { await controller.retryLastAttempt() } }
                )
                .padding(.top, 10)

                Text("Check that FlowCue is running on your Mac, then try again. Ideas stay on this iPhone.")
                    .flowCueFont(12, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 14)

                Button {
                    showingPairing = true
                } label: {
                    Text("Pair a different Mac")
                        .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.accent)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.bottom, 28)
        }
        .refreshable {
            await controller.retryLastAttempt()
        }
    }
}

// MARK: - Pairing

private struct PairMacSheet: View {
    @Bindable var controller: LANRemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var target: DiscoveredMac?
    @State private var showingManual = false
    @FocusState private var codeFocused: Bool

    private var canConnect: Bool {
        guard controller.pairingCode.count == 6 else { return false }
        if target != nil { return true }
        return showingManual && !controller.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    codeSection
                    nearbySection
                    manualSection
                    if let error = controller.lastError {
                        FlowCueInlineBanner(
                            kind: .failure,
                            title: error,
                            actionTitle: "Retry",
                            action: { Task { await connect() } }
                        )
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { FlowCueScreenBackground() }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                connectButton
            }
            .task {
                if !controller.isScanning { controller.startDiscovery() }
            }
            .onChange(of: controller.pairingCode) { _, value in
                let digits = String(value.filter { "0123456789".contains($0) }.prefix(6))
                if digits != value { controller.pairingCode = digits }
            }
            .onChange(of: controller.isConnected) { _, connected in
                if connected { dismiss() }
            }
        }
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter the code")
                .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Text("Shown on your Mac in FlowCue → iPhone.")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.top, 4)
            TextField("000000", text: $controller.pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .focused($codeFocused)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(minHeight: 54)
                .background(
                    RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                        .fill(FlowCueTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                        .strokeBorder(codeFocused ? FlowCueTheme.accent.opacity(0.6) : FlowCueTheme.hairline)
                )
                .padding(.top, 14)
                .accessibilityLabel("6-digit pairing code")
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentsSectionHeader(title: "NEARBY · WI-FI")
                .padding(.top, 22)

            if controller.discovered.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    if controller.isScanning {
                        AgentsRingSpinner(size: 22)
                            .padding(.top, 1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(controller.isScanning ? "Looking for devices…" : "No Mac found")
                            .flowCueFont(13, relativeTo: .subheadline)
                            .foregroundStyle(FlowCueTheme.textPrimary)
                        Text("Make sure your Mac is on the same Wi-Fi and FlowCue is running.")
                            .flowCueFont(11, relativeTo: .caption2)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !controller.isScanning {
                            Button("Search again") {
                                controller.stopDiscovery()
                                controller.startDiscovery()
                            }
                            .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.accent)
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(controller.discovered) { mac in
                        Button {
                            target = mac
                            codeFocused = true
                        } label: {
                            pairDeviceRow(mac)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private func pairDeviceRow(_ mac: DiscoveredMac) -> some View {
        let selected = target?.id == mac.id
        return HStack(spacing: 11) {
            AgentsFaceBadge(
                size: 30,
                faceSize: 20,
                background: FlowCueTheme.canvas,
                cornerRadius: FlowCueMetrics.radiusInline,
                bordered: true
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(FlowCueLinkFormat.deviceName(mac.name))
                    .flowCueFont(13, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text("This network")
                    .flowCueFont(10, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.accent)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                .strokeBorder(selected ? FlowCueTheme.accent.opacity(0.6) : FlowCueTheme.hairline)
        )
        .contentShape(Rectangle())
    }

    private var manualSection: some View {
        DisclosureGroup(isExpanded: $showingManual) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("192.168.1.10:61849", text: $controller.manualAddress)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                            .fill(FlowCueTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FlowCueMetrics.radiusCard, style: .continuous)
                            .strokeBorder(FlowCueTheme.hairline)
                    )
                Text("Use this if the Mac does not appear automatically.")
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            .padding(.top, 8)
        } label: {
            Text("Connect manually")
                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textSecondary)
        }
        .tint(FlowCueTheme.textSecondary)
        .padding(.top, 18)
    }

    private var connectButton: some View {
        VStack(spacing: 0) {
            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if controller.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(FlowCueTheme.onAccent)
                    }
                    Text(controller.isLoading ? "Connecting…" : "Connect")
                        .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                }
                .foregroundStyle(canConnect ? FlowCueTheme.onAccent : FlowCueTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    Capsule()
                        .fill(canConnect ? FlowCueTheme.accent : FlowCueTheme.surface)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(canConnect ? Color.clear : FlowCueTheme.hairline)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canConnect || controller.isLoading)
            .accessibilityLabel("Connect to Mac")
        }
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(FlowCueTheme.canvas)
    }

    private func connect() async {
        if let target {
            await controller.connect(to: target)
        } else if showingManual {
            await controller.connectManually()
        }
        if controller.isConnected { dismiss() }
    }

}

// MARK: - Add agent

private struct AddAgentSheet: View {
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false

    private let supported = ["Codex", "Claude Code", "DSH"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                        .frame(width: 56, height: 56)
                    Text("Agents live on your Mac")
                        .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .padding(.top, 16)
                    Text("FlowCue detects the agents installed on your Mac. Open FlowCue on your Mac, connect an agent there, then refresh this page.")
                        .flowCueFont(12.5, relativeTo: .caption)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .lineSpacing(3)
                        .padding(.top, 8)

                    AgentsSectionHeader(title: "DETECTED BY FLOWCUE")
                        .padding(.top, 22)
                    VStack(spacing: 0) {
                        ForEach(supported, id: \.self) { name in
                            HStack(spacing: 10) {
                                AgentsFaceBadge(
                                    size: AgentsLayout.agentIcon,
                                    faceSize: 18,
                                    background: FlowCueTheme.surface,
                                    cornerRadius: 8
                                )
                                Text(name)
                                    .flowCueFont(13, relativeTo: .subheadline)
                                    .foregroundStyle(FlowCueTheme.textPrimary)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            if name != supported.last {
                                Rectangle()
                                    .fill(FlowCueTheme.hairline)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("Add agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    refreshing = true
                    Task {
                        await refresh()
                        refreshing = false
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if refreshing {
                            ProgressView().controlSize(.small).tint(FlowCueTheme.onAccent)
                        }
                        Text("Refresh agents")
                            .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                    }
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(FlowCueTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(FlowCueTheme.canvas)
            }
        }
    }
}

// MARK: - Device detail (Remote first pass)

private struct RemoteDeviceView: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    @Environment(\.dismiss) private var dismiss

    private var name: String {
        FlowCueLinkFormat.deviceName(controller.selected?.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            remoteHeader

            ScrollView {
                VStack(spacing: 0) {
                    AgentsFaceBadge(
                        size: 56,
                        faceSize: 40,
                        background: FlowCueTheme.surface,
                        cornerRadius: FlowCueMetrics.radiusPanel,
                        bordered: true
                    )
                    Text(name)
                        .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .padding(.top, 14)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(controller.isConnected ? FlowCueTheme.mint : FlowCueTheme.failure)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                        Text(controller.isConnected ? "Online · Wi-Fi" : "Offline")
                    }
                    .flowCueFont(12, relativeTo: .caption)
                    .foregroundStyle(controller.isConnected ? FlowCueTheme.mint : FlowCueTheme.failure)
                    .padding(.top, 6)

                    VStack(spacing: 0) {
                        infoRow("Latency", FlowCueLinkFormat.latency(controller.lastLatencyMs) ?? "—")
                        infoRow("Last sync", FlowCueLinkFormat.relative(controller.lastRefreshAt))
                        infoRow(
                            "Pairing",
                            FlowCueLinkFormat.fingerprint("\(name)|\(controller.pairingCode)"),
                            monospaced: true
                        )
                    }
                    .padding(.top, 22)
                }
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 22)
            }
        }
        .background { FlowCueScreenBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                NavigationLink {
                    chatDestination
                } label: {
                    Text("Open chat")
                        .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(FlowCueTheme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open chat")

                Button {
                    controller.disconnect()
                    dismiss()
                } label: {
                    Text("Disconnect")
                        .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(FlowCueTheme.surface))
                        .overlay(Capsule().strokeBorder(FlowCueTheme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disconnect from this Mac")
            }
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(FlowCueTheme.canvas)
        }
    }

    private var remoteHeader: some View {
        ZStack {
            Text("Device")
                .flowCueFont(17, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var chatDestination: some View {
        if let thread = controller.threads.first {
            AgentDetailView(controller: controller, thread: thread)
        } else {
            CodexAgentView(controller: controller, tab: $tab)
        }
    }

    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(FlowCueTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowCueTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}


private struct DSHApprovalCard: View {
    let approval: DSHRemoteApproval
    let decide: (String) async -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(FlowCueTheme.accent)
                Text(approval.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                Spacer()
                if let tool = approval.toolName {
                    Text(tool)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if let reason = approval.reason, reason != approval.title {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: 10) {
                Button("Reject", role: .destructive) {
                    busy = true
                    Task { await decide("rejected"); busy = false }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Button("Approve once") {
                    busy = true
                    Task { await decide("allowed-once"); busy = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(FlowCueTheme.accent)
                .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Sessions

private struct SessionsScreenHeader: View {
    let title: String
    let onBack: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .flowCueFont(17, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer()
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 17))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session")
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 10)
    }
}

private struct SessionsStatusLine: View {
    let isOnline: Bool
    let deviceName: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? FlowCueTheme.mint : FlowCueTheme.failure)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(isOnline ? "online · \(deviceName)" : "offline")
        }
        .flowCueFont(11, relativeTo: .caption2)
        .foregroundStyle(isOnline ? FlowCueTheme.mint : FlowCueTheme.failure)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.top, 8)
    }
}

private struct SessionsCountLabel: View {
    let count: Int

    var body: some View {
        Text("\(count) SESSION\(count == 1 ? "" : "S")")
            .flowCueFont(10, relativeTo: .caption2)
            .tracking(1.4)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.top, 14)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct AgentSessionRowView: View {
    let title: String
    let subtitle: String
    let updatedAt: Date
    let isOnline: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: Color {
        guard isOnline else { return FlowCueTheme.textSecondary }
        let age = Date.now.timeIntervalSince(updatedAt)
        if age < 3600 { return FlowCueTheme.mint }
        if age < 21_600 { return FlowCueTheme.accent }
        return FlowCueTheme.textSecondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "Untitled session" : title)
                    .flowCueFont(13.5, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Text(subtitle)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 8)
            Text(FlowCueLinkFormat.shortRelative(updatedAt))
                .flowCueFont(10, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title), \(subtitle), \(FlowCueLinkFormat.shortRelative(updatedAt))"
        )
    }
}

private struct SessionsEmptyState: View {
    let agent: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 60, height: 60)
            Text("No sessions yet")
                .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 18)
            Text("Start one from an idea, or ask \(agent) something.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 280)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AgentsLayout.margin)
    }
}

private struct SessionsSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 11) {
                    Circle()
                        .fill(FlowCueTheme.hairline)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(FlowCueTheme.hairline)
                            .frame(height: 11)
                            .frame(maxWidth: 240, alignment: .leading)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(FlowCueTheme.hairline)
                            .frame(height: 8)
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                Rectangle()
                    .fill(FlowCueTheme.hairline)
                    .frame(height: 1)
            }
        }
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.top, 10)
        .accessibilityLabel("Loading sessions")
    }
}

private struct SessionsLoadError: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowCueInlineBanner(
                kind: .failure,
                title: "Couldn't load sessions",
                actionTitle: "Retry",
                action: retry
            )
            Text("The Mac may have gone to sleep. Your ideas are safe on this iPhone.")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .lineSpacing(3)
                .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.top, 10)
    }
}

private struct NewSessionSheet: View {
    let agent: String
    let refresh: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                        .frame(width: 56, height: 56)
                    Text("New sessions start on your Mac")
                        .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .padding(.top, 16)
                    Text("The phone bridge can continue existing \(agent) sessions, but it can't create a new one yet. Open \(agent) in FlowCue on your Mac, start a session there, then refresh this list.")
                        .flowCueFont(12.5, relativeTo: .caption)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .lineSpacing(3)
                        .padding(.top, 8)
                    AgentsSectionHeader(title: "WHY")
                        .padding(.top, 22)
                    Text("Creating a session needs a Mac-side endpoint. Until then, this list stays read/continue-only on iPhone.")
                        .flowCueFont(12, relativeTo: .caption)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .lineSpacing(3)
                        .padding(.top, 8)
                }
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    refreshing = true
                    Task {
                        await refresh()
                        refreshing = false
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if refreshing {
                            ProgressView().controlSize(.small).tint(FlowCueTheme.onAccent)
                        }
                        Text("Refresh sessions")
                            .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                    }
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(FlowCueTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(refreshing)
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(FlowCueTheme.canvas)
            }
        }
    }
}

private struct DSHApprovalsSheet: View {
    @Bindable var controller: LANRemoteController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if controller.dshApprovals.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(FlowCueTheme.mint)
                            Text("No pending approvals")
                                .flowCueFont(14, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(controller.dshApprovals) { approval in
                            DSHApprovalCard(approval: approval) { decision in
                                _ = await controller.decideDSH(approval, decision: decision)
                            }
                        }
                    }
                }
                .padding(AgentsLayout.margin)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("Approvals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
        }
    }
}

private struct CodexAgentView: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    @Environment(\.dismiss) private var dismiss
    @State private var network = FlowCueNetworkMonitor()
    @State private var showingNewSession = false

    private var sessions: [RemoteThreadSnapshot] {
        controller.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var isOnline: Bool {
        controller.isConnected && network.isOnline
    }

    private var isLoading: Bool {
        controller.isLoading && sessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionsScreenHeader(
                title: "Codex",
                onBack: { dismiss() },
                onNewSession: { showingNewSession = true }
            )
            SessionsStatusLine(
                isOnline: isOnline,
                deviceName: FlowCueLinkFormat.deviceName(controller.selected?.name)
            )
            content
            newSessionButton
            FlowCueTabBar(selection: $tab)
        }
        .background { FlowCueScreenBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .task { network.start() }
        .onDisappear { network.stop() }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(agent: "Codex") { await controller.refresh() }
                .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            SessionsSkeleton()
            Spacer(minLength: 0)
        } else if sessions.isEmpty && controller.lastError != nil {
            SessionsLoadError { Task { await controller.refresh() } }
            Spacer(minLength: 0)
        } else if sessions.isEmpty {
            SessionsEmptyState(agent: "Codex")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if controller.lastError != nil {
                        FlowCueInlineBanner(
                            kind: .failure,
                            title: "Connection lost — showing saved sessions",
                            actionTitle: "Retry",
                            action: { Task { await controller.refresh() } }
                        )
                        .padding(.horizontal, AgentsLayout.margin)
                        .padding(.top, 10)
                    }
                    SessionsCountLabel(count: sessions.count)
                    VStack(spacing: 0) {
                        ForEach(sessions) { thread in
                            NavigationLink {
                                AgentDetailView(controller: controller, thread: thread)
                            } label: {
                                AgentSessionRowView(
                                    title: thread.title,
                                    subtitle: subtitle(for: thread),
                                    updatedAt: thread.updatedAt,
                                    isOnline: isOnline
                                )
                            }
                            .buttonStyle(.plain)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, AgentsLayout.margin)
                }
                .padding(.bottom, 16)
            }
            .refreshable { await controller.refresh() }
        }
    }

    private func subtitle(for thread: RemoteThreadSnapshot) -> String {
        let reply = FlowCueLinkFormat.plainSnippet(
            thread.lastReply.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !reply.isEmpty { return reply }
        if let project = thread.projectDirectory, !project.isEmpty {
            return URL(fileURLWithPath: project).lastPathComponent
        }
        return "No reply yet"
    }

    private var newSessionButton: some View {
        Button {
            showingNewSession = true
        } label: {
            Text("New session")
                .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .frame(minHeight: 40)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            FlowCueTheme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("New session")
    }
}

private struct DSHAgentView: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    @Environment(\.dismiss) private var dismiss
    @State private var network = FlowCueNetworkMonitor()
    @State private var showingNewSession = false
    @State private var showingApprovals = false

    private var sessions: [DSHSessionSnapshot] {
        controller.dshSessions
            .filter { !$0.isSubagent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var isOnline: Bool {
        controller.isConnected && network.isOnline
    }

    private var isLoading: Bool {
        controller.isLoading && sessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionsScreenHeader(
                title: "DSH",
                onBack: { dismiss() },
                onNewSession: { showingNewSession = true }
            )
            SessionsStatusLine(
                isOnline: isOnline,
                deviceName: FlowCueLinkFormat.deviceName(controller.selected?.name)
            )
            if !controller.dshApprovals.isEmpty {
                FlowCueInlineBanner(
                    kind: .warning,
                    title: "\(controller.dshApprovals.count) pending approval\(controller.dshApprovals.count == 1 ? "" : "s")",
                    actionTitle: "Review",
                    action: { showingApprovals = true }
                )
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.top, 8)
            }
            content
            newSessionButton
            FlowCueTabBar(selection: $tab)
        }
        .background { FlowCueScreenBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .task { network.start() }
        .onDisappear { network.stop() }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(agent: "DSH") { await controller.refresh() }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingApprovals) {
            DSHApprovalsSheet(controller: controller)
                .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            SessionsSkeleton()
            Spacer(minLength: 0)
        } else if sessions.isEmpty && controller.lastError != nil {
            SessionsLoadError { Task { await controller.refresh() } }
            Spacer(minLength: 0)
        } else if sessions.isEmpty {
            SessionsEmptyState(agent: "DSH")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if controller.lastError != nil {
                        FlowCueInlineBanner(
                            kind: .failure,
                            title: "Connection lost — showing saved sessions",
                            actionTitle: "Retry",
                            action: { Task { await controller.refresh() } }
                        )
                        .padding(.horizontal, AgentsLayout.margin)
                        .padding(.top, 10)
                    }
                    SessionsCountLabel(count: sessions.count)
                    VStack(spacing: 0) {
                        ForEach(sessions) { session in
                            NavigationLink {
                                DSHSessionDetailView(controller: controller, session: session)
                            } label: {
                                AgentSessionRowView(
                                    title: session.title,
                                    subtitle: subtitle(for: session),
                                    updatedAt: session.updatedAt,
                                    isOnline: isOnline
                                )
                            }
                            .buttonStyle(.plain)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, AgentsLayout.margin)
                }
                .padding(.bottom, 16)
            }
            .refreshable { await controller.refresh() }
        }
    }

    private func subtitle(for session: DSHSessionSnapshot) -> String {
        let project = session.projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { return "DSH session" }
        return URL(fileURLWithPath: project).lastPathComponent
    }

    private var newSessionButton: some View {
        Button {
            showingNewSession = true
        } label: {
            Text("New session")
                .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .frame(minHeight: 40)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            FlowCueTheme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("New session")
    }
}


private struct DSHSessionDetailView: View {
    @Bindable var controller: LANRemoteController
    let session: DSHSessionSnapshot
    @State private var messages: [RemoteConversationMessage] = []
    @State private var loading = false
    @State private var subagents: [DSHSessionSnapshot] = []
    @State private var text = ""
    @State private var sending = false

    private var pendingApprovals: [DSHRemoteApproval] {
        controller.dshApprovals.filter { $0.sessionId == session.id }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if messages.isEmpty {
                    ContentUnavailableView("No text history", systemImage: "text.bubble", description: Text("This DSH session has no user/assistant text messages yet."))
                } else {
                    ForEach(messages) { message in
                        ConversationBubble(message: message)
                    }
                }
                Text("Messages go to the live DSH session on your Mac. If the session is not running, open it in DSH first.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding()
        }
        .safeAreaInset(edge: .top, spacing: 0) { dshPinnedHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if !pendingApprovals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(FlowCueTheme.accent)
                            Text("DSH needs your confirmation")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(pendingApprovals.count) pending")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        ForEach(pendingApprovals) { approval in
                            DSHApprovalCard(approval: approval) { decision in
                                _ = await controller.decideDSH(approval, decision: decision)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                if messages.last?.role == "user" {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("DSH is working…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                AgentComposer(text: $text, placeholder: "Message this DSH session", sending: sending, allowsImages: true) { images in
                    sending = true
                    Task {
                        let sent = await controller.sendDSH(to: session, text: text, images: images)
                        if sent {
                            text = ""
                            messages = await controller.dshMessages(for: session)
                        }
                        sending = false
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(FlowCueTheme.canvas)
            .overlay(alignment: .top) { Divider().opacity(0.45) }
        }
        .background(FlowCueTheme.canvas)
        .navigationTitle("DSH session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            loading = true
            await controller.refreshApprovals()
            messages = await controller.dshMessages(for: session)
            subagents = await controller.dshSubagents(for: session)
            loading = false
            await scrollToBottom(proxy)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await controller.refreshApprovals()
                let updated = await controller.dshMessages(for: session)
                if updated != messages {
                    messages = updated
                    await scrollToBottom(proxy)
                }
            }
        }
        .onChange(of: messages.count) { _, _ in
            Task { await scrollToBottom(proxy) }
        }
        }
    }

    private var dshPinnedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.headline).lineLimit(2)
            Text(session.projectDirectory).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !subagents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        Label("\(subagents.count) subagents", systemImage: "person.2.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FlowCueTheme.accent)
                        ForEach(subagents) { subagent in
                            NavigationLink {
                                DSHSessionDetailView(controller: controller, session: subagent)
                            } label: {
                                Text(subagent.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(FlowCueTheme.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FlowCueTheme.canvas)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) async {
        guard let last = messages.last else { return }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct AgentDetailView: View {
    @Bindable var controller: LANRemoteController
    let thread: RemoteThreadSnapshot
    @State private var text = ""
    @State private var messages: [RemoteConversationMessage] = []
    @State private var loadingMessages = false
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    if loadingMessages { ProgressView().controlSize(.small) }
                    if messages.isEmpty {
                        if !thread.lastReply.isEmpty {
                            Text(thread.lastReply)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            Text("No conversation history is available for this session yet.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    } else {
                        ForEach(messages) { message in
                            ConversationBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                if !controller.statusMessage.isEmpty {
                    Text(controller.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .top, spacing: 0) { codexPinnedHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                if messages.last?.role == "user" {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Agent is working…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                AgentComposer(text: $text, placeholder: "Next message", sending: sending, allowsImages: true) { images in
                    sending = true
                    Task {
                        let sent = await controller.send(to: thread, text: text, images: images)
                        if sent { text = "" }
                        sending = false
                        await controller.refresh()
                        messages = await controller.messages(for: thread)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(FlowCueTheme.canvas)
            .overlay(alignment: .top) { Divider().opacity(0.45) }
        }
        .background(FlowCueTheme.canvas)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task {
            loadingMessages = true
            messages = await controller.messages(for: thread)
            loadingMessages = false
            await scrollToBottom(proxy)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                let updated = await controller.messages(for: thread)
                if updated != messages {
                    messages = updated
                    await scrollToBottom(proxy)
                }
            }
        }
        .onChange(of: messages.count) { _, _ in
            Task { await scrollToBottom(proxy) }
        }
        }
    }

    private var codexPinnedHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thread.title).font(.headline).lineLimit(2)
            Text(thread.updatedAt, format: .relative(presentation: .named))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FlowCueTheme.canvas)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) async {
        guard let last = messages.last else { return }
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

@MainActor
@Observable
final class VoiceDictation {
    private(set) var isRecording = false
    var error: String?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onUpdate: ((String) -> Void)?

    func start(onUpdate: @escaping (String) -> Void) {
        guard !isRecording else { return }
        self.onUpdate = onUpdate
        error = nil
        // TCC invokes these callbacks on a background queue. Passing an
        // isolated closure here trips Swift 6's actor-isolation assertion.
        Self.requestSpeechAuthorization { @Sendable [weak self] status in
            guard status == .authorized else {
                Task { @MainActor in self?.error = "Speech recognition permission was denied." }
                return
            }
            Self.requestMicrophoneAuthorization { @Sendable [weak self] granted in
                guard granted else {
                    Task { @MainActor in self?.error = "Microphone permission was denied." }
                    return
                }
                Task { @MainActor in self?.begin() }
            }
        }
    }

    private nonisolated static func requestSpeechAuthorization(
        _ completion: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization(completion)
    }

    private nonisolated static func requestMicrophoneAuthorization(
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }

    func stop() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin() {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognition is not available right now."
            return
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                self.error = "No microphone input is available."
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            isRecording = true
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, speechError in
                let transcript = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || speechError != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let transcript { self.onUpdate?(transcript) }
                    if finished { self.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }
}

private struct AgentComposer: View {
    @Binding var text: String
    let placeholder: String
    let sending: Bool
    let allowsImages: Bool
    let onSend: ([Data]) -> Void
    @State private var dictation = VoiceDictation()
    @State private var baseText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [Data] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                if allowsImages {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(FlowCueTheme.canvas.opacity(0.8), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Attach images")
                }

                Button {
                    if dictation.isRecording {
                        dictation.stop()
                    } else {
                        baseText = text
                        dictation.start { transcript in
                            text = baseText + (baseText.isEmpty ? "" : " ") + transcript
                        }
                    }
                } label: {
                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(dictation.isRecording ? .red : .secondary)
                        .frame(width: 34, height: 34)
                        .background(FlowCueTheme.canvas.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isRecording ? "Stop voice input" : "Start voice input")

                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...4)
                    .padding(.vertical, 8)
                    .accessibilityLabel(placeholder)

                Button {
                    dictation.stop()
                    onSend(images)
                    images = []
                    pickerItems = []
                } label: {
                    Image(systemName: sending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) || sending
                                ? Color.secondary.opacity(0.25)
                                : FlowCueTheme.accent,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(sending || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty))
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(FlowCueTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(FlowCueTheme.hairline.opacity(0.45), lineWidth: 1)
            }
            .onChange(of: pickerItems) { _, items in
                Task {
                    var loaded: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data),
                           let jpeg = image.jpegData(compressionQuality: 0.82) {
                            loaded.append(jpeg)
                        }
                    }
                    images = loaded
                }
            }

            if dictation.isRecording {
                Text("Listening…").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
            }
            if let error = dictation.error {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2).padding(.leading, 8)
            }
        }
    }
}

private struct ConversationBubble: View {
    let message: RemoteConversationMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if isUser {
            HStack(alignment: .bottom) {
                Spacer(minLength: 54)
                VStack(alignment: .trailing, spacing: 8) {
                    if let images = message.images, !images.isEmpty {
                        MessageImageGrid(images: images)
                    }
                    if !message.text.isEmpty {
                        InlineMarkdownText(text: message.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(FlowCueTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.vertical, 2)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let images = message.images, !images.isEmpty {
                    MessageImageGrid(images: images)
                }
                if !message.text.isEmpty {
                    MarkdownMessageView(text: message.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct MessageImageGrid: View {
    let images: [RemoteMessageImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(images) { image in
                if let data = Data(base64Encoded: image.base64), let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case bullet([String])
    case numbered([String])
    case quote(String)
    case rule
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let heading = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    blocks.append(.heading(level: min(hashes, 4), text: heading))
                    index += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix(">") else { break }
                    quoted.append(String(value.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                var items: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") else { break }
                    items.append(String(value.dropFirst(2)))
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            if let range = trimmed.range(of: #"^[0-9]+[.)]\s"#, options: .regularExpression) {
                var items: [String] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.range(of: #"^[0-9]+[.)]\s"#, options: .regularExpression) != nil else { break }
                    items.append(value.replacingOccurrences(of: #"^[0-9]+[.)]\s"#, with: "", options: .regularExpression))
                    index += 1
                }
                blocks.append(.numbered(items))
                _ = range
                continue
            }

            var paragraph: [String] = []
            while index < lines.count {
                let value = lines[index].trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value.hasPrefix("```") || value.hasPrefix("#") || value == "---" || value == "***" || value.hasPrefix(">") || value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") || value.range(of: #"^[0-9]+[.)]\s"#, options: .regularExpression) != nil {
                    break
                }
                paragraph.append(value)
                index += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }
}

private struct MarkdownMessageView: View {
    let text: String

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(text: text)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        case .heading(let level, let text):
            InlineMarkdownText(text: text)
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(FlowCueTheme.accent).frame(width: 5, height: 5)
                        InlineMarkdownText(text: item).font(.body).lineSpacing(3)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        InlineMarkdownText(text: item).font(.body).lineSpacing(3)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(FlowCueTheme.accent.opacity(0.6)).frame(width: 3)
                InlineMarkdownText(text: text).font(.body).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .rule:
            Divider()
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlowCueTheme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    @Binding var tab: FlowCueTab
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
                    Text("FlowCue \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")) · Independent app, not affiliated with any agent provider.")
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(FlowCueTheme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FlowCueTabBar(selection: $tab)
            }
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
