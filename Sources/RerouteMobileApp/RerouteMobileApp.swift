import SwiftUI
import WidgetKit
import SwiftData
import StoreKit
import Observation
import UIKit
import CryptoKit
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
    nonisolated(unsafe) static var current: FlowCueThemeSpec = FlowCueThemeCatalog.spec(for: "airy")

    static var accent: Color { Color(hex: current.accent) }
    static var accentSoft: Color { accent.opacity(0.14) }
    /// 状态色跟主题明暗走：亮色主题上用深绿/深红/深琥珀，
    /// 否则 #5CD9B8 这类荧光色放在米色底上几乎看不清。
    static var mint: Color {
        current.group == .light ? Color(hex: "#0B7A5C") : Color(hex: "#5CD9B8")
    }
    static var surface: Color { Color(hex: current.card) }
    static var canvas: Color { Color(hex: current.background) }
    static var hairline: Color { current.hasBorder ? Color(hex: current.border) : .clear }
    static var textPrimary: Color { Color(hex: current.foreground) }
    static var textSecondary: Color { Color(hex: current.secondary) }
    static var textTertiary: Color { Color(hex: current.secondary).opacity(0.9) }
    static var warning: Color {
        current.group == .light ? Color(hex: "#8A5A00") : Color(hex: "#F0B429")
    }
    static var failure: Color {
        current.group == .light ? Color(hex: "#B42318") : Color(hex: "#FF6B6B")
    }
    /// 亮色主题的 accent 是深色，按钮文字必须用白；深色主题反之。
    static var onAccent: Color {
        current.group == .light ? .white : Color(hex: "#0A0A12")
    }

    static var radiusPanel: CGFloat { current.radius }
    static var radiusCard: CGFloat { current.radius }
    static var radiusInline: CGFloat { max(0, min(current.radius, 12)) }
    static var radiusCapsule: CGFloat { current.radius }

    static var hasGlow: Bool { current.glow }
    static var hasGrid: Bool { current.grid }

    static var navActive: Color {
        switch current.id {
        case "terminal": mint
        case "paper": textPrimary
        case "neutral": .white
        default: accent
        }
    }

    static func fontDesign(for style: Font.TextStyle) -> Font.Design {
        switch style {
        case .largeTitle, .title, .title2, .title3, .headline:
            return design(current.titleFont)
        case .caption, .caption2, .footnote:
            return design(current.metaFont)
        default:
            return .default
        }
    }

    private static func design(_ value: String) -> Font.Design {
        switch value {
        case "serif": .serif
        case "mono": .monospaced
        default: .default
        }
    }
}

private struct FlowCueTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 用户在 外观 里调的字号倍率；叠加在系统 Dynamic Type 之上。
    var flowCueTextScale: CGFloat {
        get { self[FlowCueTextScaleKey.self] }
        set { self[FlowCueTextScaleKey.self] = newValue }
    }
}

private struct FlowCueFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @Environment(\.flowCueTextScale) private var textScale
    private let weight: Font.Weight
    private let style: Font.TextStyle

    init(size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight) {
        // 11pt 是 HIG 的可读下限；比它更小的字在手机上会明显吃力。
        _size = ScaledMetric(wrappedValue: max(size, 11), relativeTo: style)
        self.weight = weight
        self.style = style
    }

    func body(content: Content) -> some View {
        content.font(.system(size: max(size * textScale, 11), weight: weight, design: FlowCueTheme.fontDesign(for: style)))
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

/// 全屏底色：按当前主题决定冷光 / 网格 / 纯色。
private struct FlowCueScreenBackground: View {
    var body: some View {
        ZStack {
            FlowCueTheme.canvas
            if FlowCueTheme.hasGlow {
                RadialGradient(
                    stops: [
                        .init(color: FlowCueTheme.accent.opacity(0.14), location: 0),
                        .init(color: FlowCueTheme.accent.opacity(0.04), location: 0.46),
                        .init(color: .clear, location: 0.78)
                    ],
                    center: .top,
                    startRadius: 0,
                    endRadius: 420
                )
            }
            if FlowCueTheme.hasGrid {
                FlowCueGridBackground()
            }
        }
        .ignoresSafeArea()
    }
}

private struct FlowCueGridBackground: View {
    var body: some View {
        let color = FlowCueTheme.hairline.opacity(0.55)
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += 28
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 28
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
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
        // FlowCue is free: Basic and the Mac app are not gated by StoreKit.
        // Remote will get its own paid tier later; until then every feature is free.
        isPro = true
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

/// `GET /v1/ping` 的响应。旧版 Mac 只返回 name/version，所以全部可选。
struct MacHandshake: Decodable {
    let name: String?
    let appVersion: String?
    let protocolNumber: Int?

    enum CodingKeys: String, CodingKey {
        case name, appVersion
        case protocolNumber = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decode(String.self, forKey: .name)
        appVersion = try? container.decode(String.self, forKey: .appVersion)
        if let value = try? container.decode(Int.self, forKey: .protocolNumber) {
            protocolNumber = value
        } else if let raw = try? container.decode(String.self, forKey: .protocolNumber) {
            protocolNumber = Int(raw)
        } else {
            protocolNumber = nil
        }
    }
}

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

/// 手机 ↔ Mac 的唯一链路状态（直连和中继共用一套）。
enum RemoteLinkState: Equatable {
    case disconnected
    case connecting
    case online
    case offline(reason: String)

    var isOnline: Bool { if case .online = self { return true } else { return false } }
    var isConnecting: Bool { if case .connecting = self { return true } else { return false } }
    var reason: String? { if case .offline(let reason) = self { return reason } else { return nil } }
}

/// 隧道自己的失败原因；`LANRemoteController.connectionMessage` 会把它翻成用户文案。
enum RemoteLinkError: LocalizedError, Equatable {
    case offline(String)
    case notReady
    case macOffline
    /// A single request exceeded its deadline. This is not proof that the
    /// transport is down; a large history payload can be slow while heartbeats
    /// are still healthy, so callers must not flip the whole link offline.
    case timeout

    var message: String {
        switch self {
        case .offline(let reason): return reason
        case .notReady: return L10n.text("正在连接 Mac…")
        case .macOffline: return L10n.text("Mac 不在线。")
        case .timeout: return L10n.text("请求超时。")
        }
    }

    var errorDescription: String? { message }
}

struct DSHMessagePage: Decodable {
    let messages: [RemoteConversationMessage]
    let total: Int
    let start: Int
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
    /// DSH 在等人回答的问题（提问卡）。
    private(set) var dshQuestions: [DSHRemoteQuestionBatch] = []
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
    /// 最近一次成功推给 Mac 的 Pro 到期时间；nil 表示本次连接还没推过。
    @ObservationIgnored private var lastPushedProExpiry: String?
    @ObservationIgnored private var didPushPro = false
    /// 最近一次握手拿到的 Mac 版本；nil 表示还没握手或旧版 Mac 没返回。
    private(set) var macAppVersion: String?
    private(set) var macProtocolVersion: Int?
    private(set) var needsMacUpdate = false
    private(set) var needsPhoneUpdate = false
    // v2 增加 zlib 响应压缩与 RemoteChunk 分块；旧端无法解析。
    static let minimumProtocol = 2
    static let supportedProtocol = 2

    /// 配对页/设备页展示用：iPhone 1.1.0 (52) ↔ Mac 0.1.1 · 协议 1
    var versionHandshakeText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let phone = "iPhone \(version) (\(build))"
        guard let macAppVersion else { return phone }
        let protocolText = macProtocolVersion.map { " · 协议 \($0)" } ?? ""
        return "\(phone) ↔ Mac \(macAppVersion)\(protocolText)"
    }

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
        if args.contains("--flowcue-approvals-preview") || args.contains("--flowcue-approvals-preview=2") {
            dshBridgeAvailable = true
            dshApprovals = [DSHRemoteApproval(
                id: "preview-approval",
                sessionId: nil,
                toolName: "exec_command",
                callId: nil,
                reason: "Allow running a shell command?",
                displayReason: "Auto review denied this call: 上传 build 49 到 TestFlight 属于对外发布",
                createdAt: nil
            )]
        }
        if args.contains("--flowcue-sessions-preview") {
            let now = Date()
            dshSessions = [
                .init(id: "pv-1", title: "iOS 开发", projectDirectory: "/Users/aj/Jorgut-Independent Developer/FlowCue/FlowCue-Development", updatedAt: now, isSubagent: false),
                .init(id: "pv-2", title: "继续 MacOS 开发会话", projectDirectory: "/Users/aj/Jorgut-Independent Developer/FlowCue/FlowCue-Development", updatedAt: now.addingTimeInterval(-3600), isSubagent: false),
                .init(id: "pv-3", title: "1.1 已发布 1.2 继续", projectDirectory: "/Users/aj/Jorgut-Independent Developer/QuietBar", updatedAt: now.addingTimeInterval(-7200), isSubagent: false),
                .init(id: "pv-4", title: "Tight canvas 任务开工", projectDirectory: "/Users/aj/Jorgut-Independent Developer/QuietBar", updatedAt: now.addingTimeInterval(-86400), isSubagent: false),
                .init(id: "pv-5", title: "检查 Kaloop 并准备上架", projectDirectory: "/Users/aj/Jorgut-Independent Developer/Kaloop fit app", updatedAt: now.addingTimeInterval(-90000), isSubagent: false),
            ]
        }
        if args.contains("--flowcue-questions-preview") {
            dshQuestions = [
                DSHRemoteQuestionBatch(
                    id: "preview-q1",
                    createdAt: nil,
                    sessionId: nil,
                    questions: [
                        .init(
                            id: "q1",
                            title: "现在修深色对比与无障碍阻塞项吗？",
                            detail: "QA 报告里还有 21 条对比度失败需要逐条判定。",
                            multiSelect: false,
                            options: [
                                .init(label: "现在修并重跑 QA", detail: "改自适应文字色，重跑无障碍与深色截图"),
                                .init(label: "先记录，不改", detail: "保留报告，暂不改代码"),
                                .init(label: "本轮到此为止", detail: "先到这里，下次继续"),
                            ]
                        )
                    ]
                ),
                DSHRemoteQuestionBatch(
                    id: "preview-q2",
                    createdAt: nil,
                    sessionId: nil,
                    questions: [
                        .init(
                            id: "q2",
                            title: "这次发布要带哪些构建目标？",
                            detail: "可多选。",
                            multiSelect: true,
                            options: [
                                .init(label: "iOS 1.1.0", detail: nil),
                                .init(label: "macOS 0.1.5", detail: nil),
                                .init(label: "官网同步", detail: "更新下载页与 changelog"),
                            ]
                        )
                    ]
                ),
            ]
        }
        if args.contains("--flowcue-approvals-preview=2") {
                dshApprovals.append(DSHRemoteApproval(
                    id: "preview-approval-2",
                    sessionId: nil,
                    toolName: "apply_patch",
                    callId: nil,
                    reason: "Allow writing outside the workspace?",
                    displayReason: "Write to ~/Library/Application Support/FlowCueRemote",
                    createdAt: nil
                ))
        }
        #endif
    }

    /// 链路状态的唯一真相：UI 只读它，不再用 `selected != nil` 或
    /// 系统网络状态推断「在线」。隧道/直连任何一侧变化都写这里。
    private(set) var linkState: RemoteLinkState = .disconnected
    /// 当前链路走中继（否则是同一 Wi-Fi 直连）。
    private(set) var isRemote = false

    /// 已选好一台 Mac：决定 UI 显示「设备」还是「配对新 Mac」。
    /// 它只说明配对还在，不说明现在能收发。
    var isPaired: Bool { selected != nil }
    /// 真的能收发请求。
    var isOnline: Bool { linkState.isOnline }
    var isConnecting: Bool { linkState.isConnecting }
    var connectionReason: String? { linkState.reason }

    /// 任何一次成功请求都证明链路仍通；设备页/卡片统一读这个。
    fileprivate func markOnline() {
        guard isPaired else { return }
        linkState = .online
        lastRefreshAt = Date()
        lastError = nil
    }

    fileprivate func markOffline(_ error: Error) {
        guard isPaired else { return }
        let message = Self.connectionMessage(for: error)
        linkState = .offline(reason: message)
        lastError = message
        lastLatencyMs = nil
    }

    static func connectionMessage(for error: Error) -> String {
        if let link = error as? RemoteLinkError { return link.message }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return L10n.text("连接超时。")
            case .networkConnectionLost, .notConnectedToInternet: return L10n.text("网络已断开。")
            case .cancelled: return L10n.text("连接已取消。")
            case .badServerResponse, .userAuthenticationRequired: return L10n.text("配对已失效，请重新配对。")
            default: return L10n.text("无法连接这台 Mac。")
            }
        }
        return error.localizedDescription
    }

    /// 隧道每次状态变化都同步到这里；设备卡片、详情页、设置页不再各自推断。
    func attachRemoteTunnel(_ tunnel: RemoteTunnel) {
        isRemote = true
        linkState = .connecting
        tunnel.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .disconnected:
                if !self.isPaired { self.linkState = .disconnected }
            case .connecting:
                if self.isPaired { self.linkState = .connecting }
            case .online:
                if self.isPaired {
                    self.linkState = .online
                    self.lastError = nil
                    self.lastRefreshAt = Date()
                    // 重新在线后立刻补一次数据，UI 不用等下一轮轮询。
                    Task { await self.refresh() }
                }
            case .offline(let reason):
                if self.isPaired {
                    self.linkState = .offline(reason: reason)
                    self.lastError = reason
                    self.lastLatencyMs = nil
                }
            }
        }
    }

    /// 用户点「Reconnect」：优先重开中继隧道，其次重连上次的局域网设备。
    func reconnect() async {
        lastError = nil
        if isRemote || RemoteTunnel.current() != nil {
            isRemote = true
            linkState = .connecting
            if let tunnel = RemoteTunnel.current() {
                tunnel.reconnectNow()
            } else if restoreRemoteIfPossible() {
                adoptRemoteDevice()
            }
            return
        }
        if let lastAttempted {
            await connect(endpoint: lastAttempted.endpoint, displayName: lastAttempted.name)
            return
        }
        if restoreRemoteIfPossible() {
            adoptRemoteDevice()
        }
    }

    /// 连续失败到阈值就重新扫一遍 Bonjour，找到同名 Mac 就切过去。
    /// 之前 IP 一变，轮询只重试旧地址，永远是 Connection lost。
    private var consecutiveFailures = 0
    private var isRecovering = false

    func recoverConnectionIfNeeded() async {
        // 中继链路由 RemoteTunnel 自己看门狗+重连，这里只负责局域网 IP 变化。
        guard !isRemote else { return }
        guard let current = selected else {
            // 启动/唤醒后局域网设备还没恢复时，别直接 return 卡死在 offline。
            if restoreRemoteIfPossible() { adoptRemoteDevice() }
            return
        }
        let alive = (try? await LANHTTP.request(
            endpoint: current.endpoint, method: "GET", path: "/v1/ping",
            token: nil, body: nil, timeout: 4
        )) != nil
        if alive {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        // 局域网不可达（例如手机切到蜂窝）时，如果已有远程凭据，
        // 直接回退到中继，不要只反复扫 Bonjour 把界面卡在 LOCAL。
        if consecutiveFailures >= 3, restoreRemoteIfPossible() {
            adoptRemoteDevice()
            consecutiveFailures = 0
            return
        }
        guard consecutiveFailures >= 3, !isRecovering else { return }
        isRecovering = true
        defer {
            stopDiscovery()
            isRecovering = false
        }
        startDiscovery()
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            guard let match = discovered.first(where: { $0.name == current.name }) ?? discovered.first else { continue }
            await connect(to: match)
            consecutiveFailures = 0
            return
        }
    }

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
        // 切回局域网时把可能残留的中继隧道关掉，避免请求继续走旧隧道。
        RemoteTunnel.current()?.disconnect()
        RemoteTunnel.teardown()
        isRemote = false
        linkState = .connecting

        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            lastError = "Enter the 6-digit pairing code shown on your Mac."
            linkState = .offline(reason: L10n.text("缺少配对码。"))
            return
        }
        lastAttempted = DiscoveredMac(id: displayName, name: displayName, endpoint: endpoint)
        needsMacUpdate = false
        needsPhoneUpdate = false
        isLoading = true
        defer { isLoading = false }

        // 先握手。ping 失败（旧版 Mac / 网络抖动）不当作版本不匹配，继续走原有连接路径。
        do {
            let data = try await LANHTTP.request(endpoint: endpoint, method: "GET", path: "/v1/ping", token: nil, body: nil)
            let handshake = try JSONDecoder().decode(MacHandshake.self, from: data)
            macAppVersion = handshake.appVersion
            macProtocolVersion = handshake.protocolNumber
            if let macProtocol = handshake.protocolNumber {
                if macProtocol < Self.minimumProtocol {
                    needsMacUpdate = true
                    lastError = "Your Mac's FlowCue is too old for this iPhone app. Update the Mac app to continue."
                    linkState = .offline(reason: L10n.text("Mac 版本过旧。"))
                    return
                }
                if macProtocol > Self.supportedProtocol {
                    needsPhoneUpdate = true
                    lastError = "This Mac expects a newer iPhone app. Update FlowCue on your iPhone."
                    linkState = .offline(reason: L10n.text("iPhone 版本过旧。"))
                    return
                }
            }
        } catch {
            // 旧版 Mac 没有 /v1/ping 的握手字段；继续用原有方式连接。
        }

        do {
            // 这里显示的是链路延迟，不该把 /v1/threads 的 Codex 扫描时间算进去。
            let started = CFAbsoluteTimeGetCurrent()
            _ = try await LANHTTP.request(endpoint: endpoint, method: "GET", path: "/v1/ping", token: code, body: nil, timeout: 5)
            lastLatencyMs = max(1, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
            let data = try await LANHTTP.request(endpoint: endpoint, method: "GET", path: "/v1/threads", token: code, body: nil)
            let snapshots = try JSONDecoder().decode([RemoteThreadSnapshot].self, from: data)
            selected = DiscoveredMac(id: displayName, name: displayName, endpoint: endpoint)
            threads = snapshots.sorted { $0.updatedAt > $1.updatedAt }
            linkState = .online
            lastRefreshAt = .now
            await refreshDSHApprovals()
            await refreshDSHSessions()
            await syncProToMac(force: true)
            await uploadPushToken(endpoint: endpoint, code: code)
            await rememberRemoteIdentity(endpoint: endpoint, code: code, name: displayName)
            statusMessage = threads.isEmpty ? "Connected. No sessions are available yet." : "Connected."
            lastError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stopDiscovery()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let message = Self.connectionMessage(for: error)
            lastError = "Could not connect. Check the code and that both devices are on the same Wi-Fi."
            linkState = .offline(reason: message)
        }
    }

    /// 每次启动、以及系统换发新 token 后，把 token 重新上报给 Mac。
    /// 只在连接时上传一次会漏掉「装新包换了 token」这种情况。
    func uploadPushTokenIfNeeded() async {
        guard let selected else { return }
        guard FlowCuePushRegistration.shared.needsUpload else { return }
        guard FlowCuePushRegistration.shared.token != nil else { return }
        await uploadPushToken(endpoint: selected.endpoint, code: pairingCode)
        FlowCuePushRegistration.shared.needsUpload = false
    }

    /// 记住这台 Mac 的中继身份：远程配对时手机要靠它定位。
    private func rememberRemoteIdentity(endpoint: NWEndpoint, code: String, name: String) async {
        guard let data = try? await LANHTTP.request(
            endpoint: endpoint, method: "GET", path: "/v1/ping",
            token: code, body: nil, timeout: 8
        ),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let macID = object["remoteMacID"] as? String, !macID.isEmpty else { return }
        // LANHTTP 可能走隧道，这里必须直连才能拿到 ping；
        // 若走隧道也返回了同样的字段，直接存即可。
        RemoteCredentials.macID = macID
        RemoteCredentials.deviceName = name
    }

    /// 把 APNs device token 交给 Mac。Mac 用它直接给苹果推送服务发请求，
    /// 不需要自建服务端；token 变了会覆盖。
    private func uploadPushToken(endpoint: NWEndpoint, code: String) async {
        guard let token = FlowCuePushRegistration.shared.token else { return }
        struct Body: Encodable {
            let token: String
            let environment: String
            let diagnostics: [String: Int]
        }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        let diagnostics = FlowCuePushRegistration.shared.diagnostics.mapValues { ($0 as? Bool) == true ? 1 : 0 }
        guard let body = try? JSONEncoder().encode(
            Body(token: token, environment: environment, diagnostics: diagnostics)
        ) else { return }
        _ = try? await LANHTTP.request(
            endpoint: endpoint, method: "POST", path: "/v1/push/token", token: code, body: body
        )
    }

    /// 发送前压一下：截图原图动辄 3–5 MB，base64 后更大，走局域网没必要传原图。
    static func compressedImage(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    // MARK: - 通用 Agent
    private(set) var agentInfos: [RemoteAgentInfo] = []
    /// 本机可用的 skill（斜杠菜单用）。
    private(set) var skills: [RemoteSkillInfo] = []
    /// Agent 列表最近一次加载失败的原因；nil 表示没失败。
    private(set) var agentsError: String?

    /// 所有核心请求都走这里：成功即证明链路在线，失败立刻标离线并把
    /// 原因交给 UI。`try?` 直接吞掉然后返回空数组会让页面永远转圈。
    private func sendRequest(
        method: String = "GET",
        path: String,
        authenticated: Bool = true,
        body: Data? = nil,
        timeout: TimeInterval = 20,
        requestID: String? = nil
    ) async throws -> Data {
        do {
            let data = try await LANHTTP.request(
                endpoint: requestEndpoint,
                method: method,
                path: path,
                token: authenticated ? pairingCode : nil,
                body: body,
                timeout: timeout,
                requestID: requestID
            )
            markOnline()
            return data
        } catch {
            // 大响应超时只代表这一次请求慢，不代表中继断了；链路状态交给
            // 心跳和 transport 错误，避免 2MB 历史把整个 UI 打成 offline。
            if !Self.isRequestTimeout(error) {
                markOffline(error)
            }
            throw error
        }
    }

    private static func isRequestTimeout(_ error: Error) -> Bool {
        if let link = error as? RemoteLinkError, link == .timeout { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        return false
    }

    func refreshSkills() async {
        guard isPaired else { return }
        guard let data = try? await sendRequest(path: "/v1/skills", timeout: 15) else { return }
        if let list = try? JSONDecoder().decode([RemoteSkillInfo].self, from: data) {
            skills = list
            UserDefaults.standard.set(data, forKey: "FlowCue.skillsCache")
        }
    }

    func loadCachedSkills() {
        guard skills.isEmpty,
              let data = UserDefaults.standard.data(forKey: "FlowCue.skillsCache"),
              let list = try? JSONDecoder().decode([RemoteSkillInfo].self, from: data) else { return }
        skills = list
    }

    private static let agentCacheKey = "FlowCue.agentInfoCache"

    /// 冷启动时先读上次的统计，避免空白几秒。
    func loadCachedAgents() {
        guard agentInfos.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.agentCacheKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode([RemoteAgentInfo].self, from: data) {
            agentInfos = cached
        }
    }

    func refreshAgents() async {
        guard isPaired else { return }
        do {
            let data = try await sendRequest(path: "/v1/agents", timeout: 20)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let agents = try? decoder.decode([RemoteAgentInfo].self, from: data) else {
                agentsError = L10n.text("Mac 返回了无法解析的 Agent 列表。")
                return
            }
            agentInfos = agents
            agentsError = nil
            UserDefaults.standard.set(data, forKey: Self.agentCacheKey)
        } catch {
            agentsError = Self.connectionMessage(for: error)
        }
    }

    func agentSessions(_ agentID: String) async throws -> [RemoteAgentSession] {
        guard isPaired else { throw RemoteLinkError.offline(L10n.text("尚未连接 Mac。")) }
        let data = try await sendRequest(
            path: "/v1/agents/\(agentID)/sessions",
            timeout: 25
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let sessions = try? decoder.decode([RemoteAgentSession].self, from: data) else {
            throw RemoteLinkError.offline(L10n.text("Mac 返回了无法解析的会话列表。"))
        }
        return sessions
    }

    func agentMessages(agentID: String, sessionID: String, after: Int = 0) async throws -> [RemoteAgentMessage] {
        guard isPaired else { throw RemoteLinkError.offline(L10n.text("尚未连接 Mac。")) }
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sessionID
        var path = "/v1/agents/\(agentID)/sessions/\(encoded)/messages"
        if after > 0 { path += "?after=\(after)" }
        let data = try await sendRequest(
            path: path,
            timeout: 25
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let messages = try? decoder.decode([RemoteAgentMessage].self, from: data) else {
            throw RemoteLinkError.offline(L10n.text("Mac 返回了无法解析的对话。"))
        }
        return messages
    }

    /// 该会话「正在执行什么」；没有就返回 nil。
    func agentActivity(agentID: String, sessionID: String) async -> String? {
        guard isPaired else { return nil }
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sessionID
        guard let data = try? await sendRequest(
            path: "/v1/agents/\(agentID)/sessions/\(encoded)/activity",
            timeout: 15
        ) else { return nil }
        struct Payload: Decodable { let activity: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.activity.isEmpty else { return nil }
        return payload.activity
    }

    @discardableResult
    func sendAgent(agentID: String, sessionID: String, text: String, requestID: String? = nil) async -> Bool {
        guard isPaired else { return false }
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sessionID
        struct Body: Encodable { let text: String }
        guard let body = try? JSONEncoder().encode(Body(text: text)) else { return false }
        do {
            _ = try await sendRequest(
                method: "POST",
                path: "/v1/agents/\(agentID)/sessions/\(encoded)/send",
                body: body,
                timeout: 30,
                requestID: requestID
            )
            return true
        } catch {
            lastError = String(format: L10n.text("发送失败：%@"), Self.connectionMessage(for: error))
            return false
        }
    }

    /// 从 Mac 拉取全部想法（包含 Mac 上原有的历史想法），用于反向同步。
    func pullIdeas() async -> [RemoteIdea]? {
        guard isPaired,
              let data = try? await sendRequest(path: "/v1/ideas", timeout: 20) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([RemoteIdea].self, from: data)
    }

    /// 手机删掉一条想法后，让 Mac 也删掉同一条（同步是单向推送，不删会留副本）。
    func deleteIdeaOnMac(_ id: UUID) async {
        guard isPaired else { return }
        struct Body: Encodable { let id: String }
        guard let body = try? JSONEncoder().encode(Body(id: id.uuidString)) else { return }
        _ = try? await sendRequest(method: "POST", path: "/v1/ideas/delete", body: body, timeout: 15)
    }

    func refreshDSHQuestions() async {
        guard isPaired,
              let data = try? await sendRequest(path: "/v1/dsh/questions"),
              let list = try? JSONDecoder().decode([DSHRemoteQuestionBatch].self, from: data) else { return }
        if list != dshQuestions { dshQuestions = list }
    }

    @discardableResult
    func answerDSH(batchID: String, questionID: String, chosen: [String]) async -> Bool {
        guard isPaired else { return false }
        let answer = DSHQuestionAnswer(id: batchID, answers: [.init(id: questionID, selected: chosen, custom: nil)])
        guard let body = try? JSONEncoder().encode(answer) else { return false }
        do {
            _ = try await sendRequest(method: "POST", path: "/v1/dsh/answer", body: body, timeout: 20)
            await refreshDSHQuestions()
            return true
        } catch {
            lastError = L10n.text("问题已回答或已失效。")
            await refreshDSHQuestions()
            return false
        }
    }

    /// Mac 当前在跑什么（最近一次工具调用还没结束）。没有就返回 nil。
    func dshActivity(for session: DSHSessionSnapshot) async -> (label: String, since: Date)? {
        guard isPaired else { return nil }
        struct Activity: Decodable {
            let label: String
            let since: Double?
        }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        guard let data = try? await sendRequest(path: "/v1/dsh/activity/\(encoded)"),
              let activity = try? JSONDecoder().decode(Activity.self, from: data) else { return nil }
        let since = activity.since.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return (activity.label, since)
    }

    func disconnect() {
        RemoteTunnel.current()?.disconnect()
        RemoteTunnel.teardown()
        selected = nil
        threads = []
        dshApprovals = []
        dshQuestions = []
        dshSessions = []
        dshSubagents = []
        dshBridgeAvailable = false
        statusMessage = ""
        lastLatencyMs = nil
        lastRefreshAt = nil
        lastAttempted = nil
        lastError = nil
        linkState = .disconnected
        isRemote = false
        didPushPro = false
        lastPushedProExpiry = nil
        macAppVersion = nil
        macProtocolVersion = nil
        needsMacUpdate = false
        needsPhoneUpdate = false
        startDiscovery()
    }

    func refresh() async {
        guard isPaired else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            await updateLatency()
            let data = try await sendRequest(path: "/v1/threads")
            threads = try JSONDecoder().decode([RemoteThreadSnapshot].self, from: data).sorted { $0.updatedAt > $1.updatedAt }
            await refreshDSHApprovals()
            await refreshDSHSessions()
            await syncProToMac()
            lastError = nil
        } catch {
            // sendRequest 已经把链路标离线并写入具体原因。
            if lastError == nil {
                lastError = "Connection lost. Make sure FlowCue is still running on your Mac."
            }
        }
    }

    /// 用轻量 /v1/ping 单独测链路延迟；/v1/threads 要扫 Codex 会话，
    /// 4.5s 是服务端处理时间，不是网络 RTT，不能拿来显示 latency。
    private func updateLatency() async {
        let started = CFAbsoluteTimeGetCurrent()
        guard (try? await sendRequest(path: "/v1/ping", timeout: 5)) != nil else { return }
        lastLatencyMs = max(1, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }

    private func refreshDSHSessions() async {
        guard isPaired else { return }
        do {
            let data = try await sendRequest(path: "/v1/dsh/sessions")
            dshSessions = try JSONDecoder().decode([DSHSessionSnapshot].self, from: data)
        } catch {
            // 保留上次的列表，不要因为一次失败就清空成「没有会话」。
            if lastError == nil {
                lastError = Self.connectionMessage(for: error)
            }
        }
    }

    @discardableResult
    func sendDSH(to session: DSHSessionSnapshot, text: String, images: [Data] = [], requestID: String? = nil) async -> Bool {
        guard isPaired else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        do {
            let encodedImages = images.compactMap(Self.compressedImage).map { $0.base64EncodedString() }
            let body = try JSONEncoder().encode(DSHRemoteMessage(
                sessionId: session.id,
                text: trimmed.isEmpty ? "Image attachment" : trimmed,
                images: encodedImages.isEmpty ? nil : encodedImages,
                requestID: requestID
            ))
            _ = try await sendRequest(method: "POST", path: "/v1/dsh/send", body: body, timeout: 30)
            statusMessage = "Sent to DSH."
            return true
        } catch {
            lastError = "DSH session is not live. Open it in DSH on your Mac first, then try again."
            return false
        }
    }

    func dshSubagents(for session: DSHSessionSnapshot) async -> [DSHSessionSnapshot] {
        guard isPaired else { return [] }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        do {
            let data = try await sendRequest(path: "/v1/dsh/subagents/\(encoded)")
            return try JSONDecoder().decode([DSHSessionSnapshot].self, from: data)
        } catch {
            return []
        }
    }

    /// 远程模式下 selected 可能为空（它来自局域网发现）；
    /// 只要隧道在，就用占位 endpoint 发请求，由隧道接管。
    private var requestEndpoint: NWEndpoint {
        selected?.endpoint ?? .hostPort(host: "remote.invalid", port: 47824)
    }

    /// DSH 历史分页窗口。老 Mac 不认识 `paginated` 时仍返回数组，客户端
    /// 会退化为整段历史，保证新旧端都能读。
    func dshMessagePage(
        for session: DSHSessionSnapshot,
        after: Int? = nil,
        tail: Int? = nil,
        before: Int? = nil,
        limit: Int = 60
    ) async throws -> DSHMessagePage {
        guard isPaired else { throw RemoteLinkError.offline(L10n.text("尚未连接 Mac。")) }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        var query = ["paginated=1", "limit=\(limit)"]
        if let after { query.append("after=\(after)") }
        if let tail { query.append("tail=\(tail)") }
        if let before { query.append("before=\(before)") }
        let path = "/v1/dsh/sessions/\(encoded)/messages?" + query.joined(separator: "&")
        let data = try await sendRequest(path: path, timeout: 60)
        let decoder = JSONDecoder()
        if let page = try? decoder.decode(DSHMessagePage.self, from: data) {
            return page
        }
        if let messages = try? decoder.decode([RemoteConversationMessage].self, from: data) {
            return DSHMessagePage(messages: messages, total: messages.count, start: 0)
        }
        throw RemoteLinkError.offline(L10n.text("Mac 返回了无法解析的对话。"))
    }

    func dshMessages(for session: DSHSessionSnapshot, after: Int = 0) async throws -> [RemoteConversationMessage] {
        try await dshMessagePage(for: session, after: after > 0 ? after : nil).messages
    }

    private func refreshDSHApprovals() async {
        guard isPaired else { return }
        do {
            let data = try await sendRequest(path: "/v1/dsh/approvals")
            let response = try JSONDecoder().decode(DSHRemoteApprovalsResponse.self, from: data)
            dshBridgeAvailable = response.available
            dshApprovals = response.pending
        } catch {
            // The DSH bridge is optional; an absent plugin must not break Codex.
            // 传输失败时 sendRequest 已经标离线，这里只清桥接状态。
            dshBridgeAvailable = false
            dshApprovals = []
        }
    }

    func refreshApprovals() async {
        await refreshDSHApprovals()
        await syncProToMac()
    }

    /// 把本地想法推给 Mac 的 Inbox；Mac 按 id 幂等写入，重复推送不会产生副本。
    @discardableResult
    func pushIdea(_ capture: CaptureItem) async -> Bool {
        await pushIdea(RemoteIdea(
            id: capture.id,
            text: capture.text,
            createdAt: capture.createdAt,
            updatedAt: capture.updatedAt,
            status: capture.status.rawValue
        ))
    }

    @discardableResult
    func pushIdea(_ idea: RemoteIdea) async -> Bool {
        guard isPaired else { return false }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(idea)
            _ = try await sendRequest(method: "POST", path: "/v1/ideas", body: body)
            return true
        } catch {
            return false
        }
    }

    func pushAllIdeas(_ captures: [CaptureItem]) async {
        for capture in captures where capture.status != .archived {
            guard !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            await pushIdea(capture)
        }
    }

    /// 推送整库快照：包含已归档和墓碑。
    /// 离线时删掉的条目只留下本地墓碑，必须在重连后补推，否则 Mac 永远不会删。
    func pushAllIdeas(_ ideas: [RemoteIdea]) async {
        for idea in ideas {
            await pushIdea(idea)
        }
    }

    /// 把 iPhone 上的订阅到期时间推给 Mac，让 Pro 在 Mac 解锁。
    /// 只在首次连接或值变化时发送；失败不打扰用户，下一次轮询自动重试。
    func syncProToMac(force: Bool = false) async {
        guard let selected else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else { return }
        let raw = ProEntitlement.expiry.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        guard force || !didPushPro || raw != lastPushedProExpiry else { return }
        struct Report: Encodable { let expiry: String? }
        do {
            let body = try JSONEncoder().encode(Report(expiry: raw.isEmpty ? nil : raw))
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/pro/expiry", token: code, body: body)
            didPushPro = true
            lastPushedProExpiry = raw
        } catch {
            // 网络抖动或 Mac 未运行时静默失败，下一次轮询再试。
        }
    }

    @discardableResult
    func decideDSH(_ approval: DSHRemoteApproval, decision: String) async -> Bool {
        guard isPaired else { return false }
        do {
            let body = try JSONEncoder().encode(DSHRemoteDecision(id: approval.id, decision: decision))
            _ = try await sendRequest(method: "POST", path: "/v1/dsh/decide", body: body)
            dshApprovals.removeAll { $0.id == approval.id }
            statusMessage = decision == "allowed-once" ? "DSH approved." : "DSH rejected."
            return true
        } catch {
            lastError = "DSH approval expired or the bridge is unavailable."
            await refreshDSHApprovals()
            return false
        }
    }

    func messages(for thread: RemoteThreadSnapshot) async throws -> [RemoteConversationMessage] {
        guard isPaired else { throw RemoteLinkError.offline(L10n.text("尚未连接 Mac。")) }
        let encoded = thread.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? thread.id
        let data = try await sendRequest(path: "/v1/threads/\(encoded)/messages")
        guard let messages = try? JSONDecoder().decode([RemoteConversationMessage].self, from: data) else {
            throw RemoteLinkError.offline(L10n.text("Mac 返回了无法解析的对话。"))
        }
        return messages
    }

    @discardableResult
    func send(to thread: RemoteThreadSnapshot, text: String, images: [Data] = []) async -> Bool {
        guard isPaired else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        let phoneID: UUID
        if let raw = UserDefaults.standard.string(forKey: "FlowCue.remotePhoneID"), let id = UUID(uuidString: raw) {
            phoneID = id
        } else {
            phoneID = UUID()
            UserDefaults.standard.set(phoneID.uuidString, forKey: "FlowCue.remotePhoneID")
        }
        let encodedImages = images.compactMap(Self.compressedImage).map { $0.base64EncodedString() }
        let command = RemoteCommand(
            phoneID: phoneID,
            executorID: thread.executorID,
            threadID: thread.id,
            text: trimmed,
            images: encodedImages.isEmpty ? nil : encodedImages
        )
        do {
            let body = try JSONEncoder().encode(command)
            _ = try await sendRequest(method: "POST", path: "/v1/send", body: body)
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
    /// 发送类请求要更长的超时：桥接转发消息前要先唤醒 DSH 的 agent，
    /// 10 秒经常不够，会让手机把「已送达」误判成失败，用户于是反复重发。
    static func request(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        token: String?,
        body: Data?,
        timeout: TimeInterval = 10,
        requestID: String? = nil
    ) async throws -> Data {
        // 远程优先：中继隧道在线时所有 /v1 请求走加密通道，
        // LAN 直连作为同 Wi-Fi 的后备（断线即回退）。
        if let tunnel = await RemoteTunnel.current() {
            // 有隧道就只走隧道：离线时立刻抛错，绝不悄悄回退到
            // remote.invalid 这种占位地址然后卡到超时。
            // 必须带鉴权头：Mac 端所有接口都要 Bearer，隧道不传就会 401。
            var headers: [String: String] = [:]
            if let token, !token.isEmpty {
                headers["authorization"] = "Bearer \(token)"
            }
            return try await tunnel.request(method: method, path: path, headers: headers, body: body, requestID: requestID, timeout: timeout)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let runner = LANHTTPRunner(endpoint: endpoint, method: method, path: path, token: token, body: body, continuation: continuation)
            runner.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
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
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        request += "X-FlowCue-Version: \(clientVersion)\r\n"
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
    @UIApplicationDelegateAdaptor(FlowCueAppDelegate.self) private var appDelegate
    @State private var store: IdeaDockStore?
    @State private var syncController: IdeaSyncController?
    @State private var subscription = SubscriptionManager()
    @State private var remoteController = LANRemoteController()
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID
    @AppStorage("FlowCue.hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("FlowCue.textScale") private var textScale = 1.0
    @State private var previewOnboarding = OnboardingPreview.isActive

    init() {
        FlowCueThemeSelection.migrateIfNeeded()
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
            let theme = FlowCueThemeCatalog.spec(for: themeID)
            let _ = FlowCueTheme.current = theme
            let _ = FlowCueThemeSharing.publish(themeID)
            Group {
                if let store, let syncController {
                    if hasSeenOnboarding && !previewOnboarding {
                        RootTabView(store: store, syncController: syncController, remoteController: remoteController)
                    } else {
                        OnboardingView {
                            hasSeenOnboarding = true
                            previewOnboarding = false
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
            .id("\(themeID)|\(language)")
            .environment(\.flowCueTextScale, textScale)
            .environment(subscription)
            .environment(\.locale, Locale(identifier: language))
            .preferredColorScheme(theme.group.colorScheme)
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

private enum FlowCueTab: Hashable { case inbox, agents, me }

private struct RootTabView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage("FlowCue.hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    /// 同一个视图上只能可靠地存在一个 .sheet，所以这里合并成一个入口。
    @State private var activeSheet: RootSheet?
    @State private var didSeedSharedPreview = false
    @State private var lastAutoReconnectAt = Date.distantPast
    private enum RootSheet: String, Identifiable {
        case approvals, sharePreview
        var id: String { rawValue }
    }

    @State private var showingSharePreview: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--flowcue-share-extension-preview")
        #else
        false
        #endif
    }()
    @State private var tab: FlowCueTab = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let value = arguments.first(where: { $0.hasPrefix("--flowcue-tab=") }) {
            switch String(value.dropFirst("--flowcue-tab=".count)) {
            case "agents": return .agents
            case "settings", "me": return .me
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
            MeView(
                store: store,
                syncController: syncController,
                remoteController: remoteController,
                tab: $tab,
                showOnboarding: { hasSeenOnboarding = false }
            )
            .tag(FlowCueTab.me)
            .toolbar(.hidden, for: .tabBar)
        }
        .tint(FlowCueTheme.accent)
        .task(id: remoteController.isPaired) {
            guard remoteController.isPaired else { return }
            // 先把 Mac 上的想法拉下来合并（Mac → iPhone），再把本地推上去
            // （iPhone → Mac）。两边按 id 对齐，updatedAt 新的赢。
            if let pulled = await remoteController.pullIdeas() {
                _ = store.mergePulledIdeas(pulled)
            }
            await remoteController.pushAllIdeas(store.syncSnapshot())
            // 轮询分轻重：审批/提问很便宜，3 秒一次；Agent 汇总要遍历本机
            // 所有会话（实测 5–9 秒），远程时每 3 秒发一次会把对话请求堵死。
            var tick = 0
            while !Task.isCancelled {
                await remoteController.refreshApprovals()
                await remoteController.refreshDSHQuestions()
                if tick % 10 == 0 {
                    await remoteController.refreshAgents()
                }
                tick += 1
                await remoteController.uploadPushTokenIfNeeded()
                await remoteController.recoverConnectionIfNeeded()
                // App 前台但网络刚恢复/手机刚解锁时，scenePhase 不一定再变。
                // 每 15 秒兜底一次：优先恢复远程凭据，其次再走局域网重连。
                if !remoteController.isOnline,
                   Date().timeIntervalSince(lastAutoReconnectAt) > 15 {
                    lastAutoReconnectAt = .now
                    if remoteController.restoreRemoteIfPossible() {
                        remoteController.adoptRemoteDevice()
                    } else {
                        await remoteController.reconnect()
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: remoteController.dshApprovals.isEmpty) { _, isEmpty in
            if !isEmpty { activeSheet = .approvals }
        }
        .onChange(of: remoteController.dshQuestions.isEmpty) { _, isEmpty in
        }
        .onAppear {
            // 有远程凭据时直接连中继，不需要先在同一 Wi-Fi。
            if remoteController.restoreRemoteIfPossible() {
                remoteController.adoptRemoteDevice()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--flowcue-uitest-seed") {
                store.seedUIIdeasIfNeeded()
            }
            #endif
            if !remoteController.dshApprovals.isEmpty { activeSheet = .approvals }
            if showingSharePreview { activeSheet = .sharePreview }
            FlowCuePushRegistration.shared.requestIfNeeded()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .approvals:
                DSHApprovalsSheet(controller: remoteController)
            case .sharePreview:
                ShareExtensionView(
                    initialText: "The retry backoff feels too slow on flaky Wi-Fi — should we make it exponential?",
                    onSave: { _, _ in activeSheet = nil },
                    onCancel: { activeSheet = nil }
                )
            }
        }
        .onChange(of: store.captures) { _, _ in
            writeWidgetSnapshot()
        }
        .onOpenURL { url in
            guard url.scheme == "flowcue" else { return }
            tab = url.host == "chat" ? .agents : .inbox
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // 回前台时系统可能已经回收了 WebSocket，主动确认一次。
            RemoteTunnel.current()?.checkLiveness()
            #if DEBUG
            if !didSeedSharedPreview,
               ProcessInfo.processInfo.arguments.contains("--flowcue-share-preview") {
                didSeedSharedPreview = true
                FlowCueSharedCaptureStore.append(
                    FlowCueSharedCapture(text: "Shared from Safari", target: .inbox, createdAt: .now)
                )
            }
            #endif
            importSharedCaptures()
            writeWidgetSnapshot()
            await syncController.runWhileActive()
        }
    }

    private func writeWidgetSnapshot() {
        let active = store.captures
            .filter { $0.status != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
        let ideas = active.prefix(4).map { capture in
            FlowCueWidgetSnapshot.Idea(
                text: capture.text,
                status: HomeStatus.label(capture.status),
                updatedAt: capture.updatedAt
            )
        }
        let status: String
        if remoteController.isOnline, let latency = remoteController.lastLatencyMs {
            status = "CODEX \(FlowCueLinkFormat.latency(latency) ?? "")"
        } else {
            status = "LOCAL"
        }
        FlowCueWidgetSnapshotStore.write(
            FlowCueWidgetSnapshot(
                ideas: Array(ideas),
                totalIdeas: active.count,
                status: status,
                updatedAt: .now
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func importSharedCaptures() {
        let pending = FlowCueSharedCaptureStore.drain()
        guard !pending.isEmpty else { return }

        let previousTarget = store.targetThreadID
        var savedIDs: [UUID] = []
        for item in pending {
            if item.target == .codex, let context = store.contexts.first {
                store.setTarget(context.id)
            }
            if !store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let draftID = store.saveCurrent() {
                savedIDs.append(draftID)
            }
            store.draftText = item.text
            if let savedID = store.saveCurrent() {
                savedIDs.append(savedID)
            }
        }
        store.setTarget(previousTarget)
        let imported = store.captures.filter { savedIDs.contains($0.id) }
        Task { await remoteController.pushAllIdeas(imported) }
        store.notification = DockNotification(
            kind: .success,
            message: "Saved \(pending.count) shared idea\(pending.count == 1 ? "" : "s")."
        )
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
        let symbol: String
    }

    private let items: [Item] = [
        Item(tab: .inbox, title: "Ideas", glyph: .spark, symbol: "sparkles"),
        Item(tab: .agents, title: "Agents", glyph: .plane, symbol: "paperplane"),
        Item(tab: .me, title: "Me", glyph: .face, symbol: "face.smiling")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tab) { item in
                itemButton(item)
            }
        }
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                .fill(FlowCueTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
        )
        .padding(.horizontal, HomeLayout.barMargin)
        .padding(.vertical, 6)
        .background(FlowCueTheme.canvas)
    }

    private func itemButton(_ item: Item) -> some View {
        let isSelected = selection == item.tab
        let tint = isSelected ? FlowCueTheme.navActive : FlowCueTheme.textSecondary
        return Button {
            guard selection != item.tab else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            selection = item.tab
        } label: {
            VStack(spacing: 3) {
                FlowCueGlyph(kind: item.glyph, ink: tint, smile: tint)
                    .frame(width: 16, height: 16)
                Text(item.title)
                    .flowCueFont(9, relativeTo: .caption2, weight: .medium)
                    .tracking(0.54)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // 自定义栏不能像正文一样无限放大：HIG 要求用 Large Content
            // Viewer，而不是让标签吃掉五分之一屏。
            .dynamicTypeSize(.small ... .xxxLarge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.symbol)
        }
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

private enum FlowCueSyncState {
    static let failureMessages: Set<String> = [
        "暂时无法同步，本地想法已保留",
        "iCloud 账户已更换，同步已暂停",
        "想法存在编辑冲突，原文已保留"
    ]

    @MainActor
    static func hasFailure(_ sync: IdeaSyncController) -> Bool {
        sync.isEnabled && failureMessages.contains(sync.statusMessage)
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

    static func title(_ status: CaptureStatus) -> String {
        switch status {
        case .draft, .saved: "Draft"
        case .queueing, .queued: "Queued"
        case .failed: "Failed"
        case .unknown: "Needs check"
        case .archived: "Archived"
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

    static let archivedSamples: [CaptureItem] = {
        #if DEBUG
        [sample("Old widget idea", hour: 16, minute: 10, status: .archived)]
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

/// 仅 DEBUG：直接打开 Search 并带查询，用于截图走查。
private enum SearchPreview {
    static let requestedQuery: String? = {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-search=")
        }) else { return nil }
        return String(argument.dropFirst("--flowcue-search=".count))
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { requestedQuery != nil }
    static let seedRecent = ["character", "blink", "backoff"]
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
    @State private var showingSearch = SearchPreview.isActive
    @State private var startSearchVoice = false
    @State private var chipsCollapsed = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var hasCompletedInitialSync = false
    @State private var pendingDelete: CaptureItem?
    @State private var openIdea: CaptureItem?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @FocusState private var captureFocused: Bool
    @ScaledMetric(relativeTo: .caption) private var searchHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var chipHeight: CGFloat = 26

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
                if !isSelecting {
                    HomeCaptureBar(store: store, controller: remoteController, focused: $captureFocused)
                }
                if !captureFocused {
                    FlowCueTabBar(selection: $tab)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: captureFocused)
            .background { FlowCueScreenBackground() }
            .toolbar(.hidden, for: .navigationBar)
        .edgeSwipeBack()
            .navigationDestination(isPresented: $showingSearch) {
                SearchView(store: store, remoteController: remoteController, startVoice: startSearchVoice)
            }
            .navigationDestination(item: $openIdea) { idea in
                IdeaDetailView(store: store, remoteController: remoteController, capture: idea)
            }
            .confirmationDialog(
                "删除这条想法？",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { idea in
                Button("删除", role: .destructive) {
                    Task {
                        await remoteController.deleteIdeaOnMac(idea.id)
                        store.delete(idea.id)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { _ in
                Text("会移到垃圾箱（Me → Trash），可以随时恢复。Mac 上同一条也会一起移走。")
            }
            .task { network.start() }
            .onChange(of: syncController.isSyncing) { _, isSyncing in
                if !isSyncing { hasCompletedInitialSync = true }
            }
            .onDisappear { network.stop() }
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
                tab = .me
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
        HStack(spacing: 0) {
            Button {
                startSearchVoice = false
                showingSearch = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .accessibilityHidden(true)
                    Text(dynamicTypeSize.isAccessibilitySize ? "Search" : "Search your ideas")
                        .flowCueFont(12.5, relativeTo: .caption)
                        .lineLimit(1)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 13)
                .frame(minHeight: searchHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search your ideas")

            Button {
                startSearchVoice = true
                showingSearch = true
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                    .frame(width: 42, height: searchHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search by voice")
        }
        .padding(.trailing, 4)
        .frame(minHeight: searchHeight)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                .fill(FlowCueTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
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
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        // 未选中的 chip 也给一个实心底：透明底在自动对比度审计里
                        // 会被当成白底，而且视觉上也不像一个可点的控件。
                        .fill(isSelected ? FlowCueTheme.accentSoft : FlowCueTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .strokeBorder(isSelected ? Color.clear : FlowCueTheme.hairline)
                )
                .foregroundStyle(isSelected ? FlowCueTheme.accent : FlowCueTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
            Text("No \(filter.title.lowercased()) ideas")
                .flowCueFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Button("Show all ideas") {
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
        return FlowCueSyncState.hasFailure(syncController)
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
        baseCaptures.filter { capture in
            capture.status != .draft && filter.matches(capture.status)
        }
    }

    private var showsEmptyState: Bool {
        guard visibleIdeas.isEmpty else { return false }
        if HomePreview.forcesEmpty { return true }
        return activeIdeas.isEmpty && filter == .all
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
        } else if remoteController.isOnline && !isOffline {
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
                    IdeaSwipeRow(
                        onArchive: {
                            store.archive(idea.id)
                            if let updated = store.captures.first(where: { $0.id == idea.id }) {
                                Task { await remoteController.pushIdea(updated) }
                            }
                        },
                        onDelete: { pendingDelete = idea },
                        onTap: {
                            if isSelecting {
                                toggleSelection(idea.id)
                            } else {
                                openIdea = idea
                            }
                        },
                        onLongPress: {
                            guard !isSelecting else { return }
                            isSelecting = true
                            selectedIDs = [idea.id]
                        },
                        isSelecting: isSelecting,
                        isSelected: selectedIDs.contains(idea.id)
                    ) {
                        HomeIdeaRow(capture: idea)
                    }
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
        .overlay(alignment: .bottom) {
            if isSelecting { selectionBar }
        }
    }

    /// 批量选择时底部的操作条。
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .flowCueFont(11, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Spacer(minLength: 0)
            Button("Archive") { archiveSelected() }
                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .disabled(selectedIDs.isEmpty)
            Button("Delete") { deleteSelected() }
                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.failure)
                .disabled(selectedIDs.isEmpty)
            Button("Cancel") {
                isSelecting = false
                selectedIDs.removeAll()
            }
            .flowCueFont(12, relativeTo: .caption, weight: .semibold)
            .foregroundStyle(FlowCueTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
        }
        .padding(.bottom, 4)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedIDs.isEmpty { isSelecting = false }
        } else {
            selectedIDs.insert(id)
        }
    }

    private func archiveSelected() {
        let ids = selectedIDs
        isSelecting = false
        selectedIDs.removeAll()
        for id in ids {
            store.archive(id)
            if let updated = store.captures.first(where: { $0.id == id }) {
                Task { await remoteController.pushIdea(updated) }
            }
        }
    }

    private func deleteSelected() {
        let ids = selectedIDs
        isSelecting = false
        selectedIDs.removeAll()
        for id in ids { store.delete(id) }
        Task {
            for id in ids { await remoteController.deleteIdeaOnMac(id) }
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

// MARK: - Search

private enum SearchScope {
    case all
    case archived
}

private struct SearchView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var remoteController: LANRemoteController
    let startVoice: Bool
    var scope: SearchScope = .all

    @Environment(\.dismiss) private var dismiss
    @State private var query = SearchPreview.requestedQuery ?? ""
    @State private var recent: [String] = []
    @State private var didPrepare = false
    @State private var dictation = VoiceDictation()
    @State private var dictationBase = ""
    @FocusState private var focused: Bool

    private static let recentKey = "FlowCue.recentSearches"

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [CaptureItem] {
        guard !normalizedQuery.isEmpty else { return [] }
        return searchCaptures.filter { capture in
            if scope == .archived, capture.status != .archived { return false }
            return capture.text.localizedCaseInsensitiveContains(normalizedQuery)
                || capture.sourceTitle?.localizedCaseInsensitiveContains(normalizedQuery) == true
                || capture.targetTitle?.localizedCaseInsensitiveContains(normalizedQuery) == true
        }
    }

    private var searchCaptures: [CaptureItem] {
        #if DEBUG
        if HomePreview.usesSamples {
            return scope == .archived
                ? HomePreview.archivedSamples
                : HomePreview.samples + HomePreview.archivedSamples
        }
        #endif
        return store.captures
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !recent.isEmpty {
                        recentChips
                    }
                    if normalizedQuery.isEmpty {
                        if recent.isEmpty { emptyHint }
                    } else if results.isEmpty {
                        noResults
                    } else {
                        resultsSection
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background { FlowCueScreenBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .edgeSwipeBack()
        .onAppear(perform: prepare)
        .onDisappear { dictation.stop() }
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

    private var searchHeader: some View {
        HStack(spacing: 8) {
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

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .accessibilityHidden(true)

                TextField(scope == .archived ? "Search archive" : "Search your ideas", text: $query)
                    .flowCueFont(12.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { remember(normalizedQuery) }

                if dictation.isRecording {
                    Button {
                        dictation.stop()
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FlowCueTheme.accent)
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop voice search")
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(FlowCueTheme.textTertiary)
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 6)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                    .fill(FlowCueTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var recentChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT")
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recent, id: \.self) { term in
                        Button {
                            query = term
                            focused = true
                        } label: {
                            Text(term)
                                .flowCueFont(12, relativeTo: .caption)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                                        .fill(FlowCueTheme.surface)
                                        .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 18)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(FlowCueTheme.textTertiary)
            Text(scope == .archived ? "Search archived ideas" : "Search your ideas")
                .flowCueFont(16, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Text("Titles, source, and agent target.")
                .flowCueFont(11.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(results.count) \(results.count == 1 ? "RESULT" : "RESULTS")")
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.top, recent.isEmpty ? 18 : 10)
                .padding(.bottom, 2)

            ForEach(results) { capture in
                NavigationLink {
                    IdeaDetailView(store: store, remoteController: remoteController, capture: capture)
                } label: {
                    SearchResultRow(capture: capture)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { remember(normalizedQuery) })

                Rectangle()
                    .fill(FlowCueTheme.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 18)
                    .accessibilityHidden(true)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(FlowCueTheme.textTertiary)
            Text("No results for “\(normalizedQuery)”")
                .flowCueFont(15, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Try a different word.")
                .flowCueFont(11.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Button("Clear search") {
                query = ""
                focused = true
            }
            .flowCueFont(12, relativeTo: .caption, weight: .semibold)
            .foregroundStyle(FlowCueTheme.accent)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 84)
    }

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if recent.isEmpty, SearchPreview.isActive {
            recent = SearchPreview.seedRecent
        }
        if startVoice {
            startDictation()
        } else if query.isEmpty {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                focused = true
            }
        }
    }

    private func startDictation() {
        dictationBase = query
        dictation.start { transcript in
            query = dictationBase.isEmpty ? transcript : dictationBase + " " + transcript
        }
    }

    private func remember(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        recent = Array(next.prefix(6))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
}

private struct SearchResultRow: View {
    let capture: CaptureItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(HomeStatus.tint(capture.status))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(capture.text)
                    .flowCueFont(14, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(2)
                Text("\(HomeStatus.title(capture.status)) · \(HomeFormat.meta(for: capture.updatedAt))")
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.top, 2)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
    }
}


/// 左滑露出 Archive / Delete 两个操作。用自定义手势而不是 List 的
/// swipeActions——首页不是 List，改成 List 会破坏现有排版。
/// 左滑露出 Archive / Delete 两个操作。
/// 位移只有一个数据源 offsetX：拖动时跟手、松手时吸附。
/// 之前用 @GestureState + @State 双源，松手瞬间前者归零、后者才赋值，
/// 中间会算出 0 再滑出去，看起来就是「闪了两下」。
private struct IdeaSwipeRow<Content: View>: View {
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void
    let onLongPress: () -> Void
    let isSelecting: Bool
    let isSelected: Bool
    @ViewBuilder var content: Content

    @State private var offsetX: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var didDrag = false

    private let actionWidth: CGFloat = 78
    private var actionsWidth: CGFloat { actionWidth * 2 }

    var body: some View {
        ZStack(alignment: .trailing) {
            content
                .background(FlowCueTheme.canvas)
                .offset(x: isSelecting ? 0 : offsetX)
                // 选择模式下把内容右移，给左侧的勾选圆圈腾出位置，
                // 否则圆圈会压在标题上。
                .padding(.leading, isSelecting ? 26 : 0)
                .overlay(alignment: .leading) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? FlowCueTheme.accent : FlowCueTheme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
                // 单击：滑开时收起，否则进详情。用 simultaneousGesture，
                // 避免独占点击手势拖住列表滚动（.onTapGesture 曾经这么干过）。
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard !didDrag else { return }
                        if offsetX != 0 {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { offsetX = 0 }
                        } else {
                            onTap()
                        }
                    }
                )
                // 长按：直接滑出操作。放在这里而不是 Button 上，
                // Button 的手势优先级高，长按永远轮不到。
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            guard !isSelecting else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onLongPress()
                        }
                )
                .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        guard !isSelecting else { return }
                        if dragStart == nil {
                            dragStart = offsetX
                            didDrag = true
                        }
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) else { return }
                        let base = dragStart ?? 0
                        offsetX = min(0, max(-actionsWidth, base + dx))
                    }
                    .onEnded { value in
                        guard !isSelecting else { return }
                        let base = dragStart ?? 0
                        dragStart = nil
                        let dx = value.translation.width
                        let dy = value.translation.height
                        let projected = abs(dx) > abs(dy) ? base + dx : base
                        let shouldOpen = projected < -actionsWidth / 2
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            offsetX = shouldOpen ? -actionsWidth : 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { didDrag = false }
                    }
            )
            if !isSelecting && offsetX != 0 {
                HStack(spacing: 0) {
                    action("Archive", systemImage: "archivebox", color: FlowCueTheme.warning, action: onArchive)
                    action("Delete", systemImage: "trash", color: FlowCueTheme.failure, action: onDelete)
                }
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomTrailingRadius: FlowCueTheme.radiusInline,
                        topTrailingRadius: FlowCueTheme.radiusInline,
                        style: .continuous
                    )
                )
                .padding(.vertical, 2)
            }
        }
        .clipped()
    }

    private func action(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { offsetX = 0 }
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .flowCueFont(10, relativeTo: .caption2, weight: .semibold)
            }
            .foregroundStyle(Color.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
        // 实心画布底：视觉上与屏幕底一致；自动对比度审计需要真实背景色，
        // 透明节点会被当成白底而误报。
        .background(FlowCueTheme.canvas)
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
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.textPrimary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
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
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
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
    let controller: LANRemoteController
    @FocusState.Binding var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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

            TextField(dynamicTypeSize.isAccessibilitySize ? "Idea" : "Capture an idea", text: $store.draftText, axis: .vertical)
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
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                .fill(FlowCueTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
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
        guard canSubmit, let savedID = store.saveCurrent() else { return }
        store.notification = nil
        focused = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let saved = store.captures.first(where: { $0.id == savedID }) {
            Task { await controller.pushIdea(saved) }
        }
    }
}

private struct IdeaDetailView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var remoteController: LANRemoteController
    let capture: CaptureItem
    @State private var text: String
    @State private var isSaving = false
    @State private var showingSend = false
    @State private var showingDelete = false
    @State private var sentNote: String?
    @Environment(\.dismiss) private var dismiss

    init(store: IdeaDockStore, remoteController: LANRemoteController, capture: CaptureItem) {
        self.store = store
        self.remoteController = remoteController
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
                if let sentNote {
                    Label(sentNote, systemImage: "paperplane.fill")
                        .font(.caption)
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
            .padding()
        }
        .background(FlowCueTheme.canvas)
        .navigationTitle(capture.text.isEmpty ? "Idea" : "Edit idea")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSend = true
                } label: {
                    Image(systemName: "paperplane")
                }
                .disabled(isArchived || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send to agent")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 18) {
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
                    Button("Delete", role: .destructive) {
                        showingDelete = true
                    }
                }
            }
        }
        .confirmationDialog("删除这条想法？", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    await remoteController.deleteIdeaOnMac(capture.id)
                    store.delete(capture.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移到垃圾箱（Me → Trash），可以随时恢复。Mac 上同一条也会一起移走。")
        }
        .sheet(isPresented: $showingSend) {
            SendIdeaSheet(controller: remoteController, text: text) { target in
                sentNote = "Sent to \(target)"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .onDisappear { _ = save(force: false) }
    }

    @discardableResult
    private func save(force: Bool = false) -> Bool {
        guard isArchived == false, hasChanges else { return true }
        let trimmed = force ? text : text
        let didSave = store.updateText(captureID: capture.id, text: trimmed)
        if !didSave {
            text = capture.text
        } else if let updated = store.captures.first(where: { $0.id == capture.id }) {
            Task { await remoteController.pushIdea(updated) }
        }
        return didSave
    }
}


private struct SendIdeaSheet: View {
    @Bindable var controller: LANRemoteController
    let text: String
    let onSent: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sendingID: String?
    @State private var errorMessage: String?

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTargets: Bool {
        !controller.threads.isEmpty || controller.dshSessions.contains { !$0.isSubagent }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !controller.isPaired {
                    placeholder(
                        icon: "wifi.slash",
                        title: "No Mac connected",
                        detail: "Pair your Mac in Agents → your Mac, then try again."
                    )
                } else if !hasTargets {
                    placeholder(
                        icon: "terminal",
                        title: "No live sessions",
                        detail: "Open the target project in FlowCue on your Mac first."
                    )
                } else {
                    targetList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { FlowCueScreenBackground() }
            .navigationTitle("Send to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
            }
            .alert("Send failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var targetList: some View {
        List {
            // DSH 的实时会话排在最前：Codex 那边可能有几十条历史任务，
            // 放前面会把真正想发过去的会话挤到列表底部（用户只看得到 Codex）。
            let sessions = controller.dshSessions.filter { !$0.isSubagent }
            if !sessions.isEmpty {
                Section("DSH · live sessions") {
                    ForEach(sessions) { session in
                        row(
                            id: "dsh-\(session.id)",
                            title: session.title.isEmpty ? "Untitled session" : session.title,
                            subtitle: session.projectDirectory
                        ) {
                            await controller.sendDSH(to: session, text: trimmedText)
                        } onSuccess: {
                            onSent("DSH · \(session.title)")
                        }
                    }
                }
            }

            if !controller.threads.isEmpty {
                Section {
                    ForEach(Array(controller.threads.prefix(12))) { thread in
                        row(
                            id: "codex-\(thread.id)",
                            title: thread.title.isEmpty ? "Untitled session" : thread.title,
                            subtitle: thread.projectDirectory ?? ""
                        ) {
                            await controller.send(to: thread, text: trimmedText)
                        } onSuccess: {
                            onSent("Codex · \(thread.title)")
                        }
                    }
                } header: {
                    Text("Codex · recent")
                } footer: {
                    if controller.threads.count > 12 {
                        Text("只显示最近 12 个，共 \(controller.threads.count) 个会话。")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FlowCueTheme.canvas)
    }

    private func row(
        id: String,
        title: String,
        subtitle: String,
        action: @escaping () async -> Bool,
        onSuccess: @escaping () -> Void
    ) -> some View {
        Button {
            guard sendingID == nil else { return }
            sendingID = id
            Task {
                let ok = await action()
                sendingID = nil
                if ok {
                    onSuccess()
                    dismiss()
                } else {
                    errorMessage = controller.lastError ?? "The session did not accept the message."
                }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .flowCueFont(14, relativeTo: .subheadline)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .flowCueFont(11, relativeTo: .caption2)
                            .foregroundStyle(FlowCueTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if sendingID == id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane")
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(sendingID != nil)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FlowCueTheme.textSecondary)
            Text(title)
                .flowCueFont(15, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Text(detail)
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(24)
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
    var cornerRadius: CGFloat = FlowCueTheme.radiusInline
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
                cornerRadius: FlowCueTheme.radiusInline,
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
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
        .contentShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous))
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
    /// Agent 的 id（codex/claude/dsh），用来挑品牌图标；为空时退回 FlowCue 小脸。
    var agentID: String = ""

    /// 品牌图标：用官方 mark 的单色矢量，按品牌色 tint。
    private var brand: (asset: String, tint: Color)? {
        switch agentID {
        case "codex": return ("AgentOpenAI", Color(hex: "#10A37F"))
        case "claude": return ("AgentAnthropic", Color(hex: "#D97757"))
        case "dsh": return ("AgentDeepSeek", Color(hex: "#4D6BFE"))
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let brand {
                Image(brand.asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(isActive ? brand.tint : brand.tint.opacity(0.45))
                    .frame(width: AgentsLayout.agentIcon, height: AgentsLayout.agentIcon)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(FlowCueTheme.surface)
                    )
            } else {
                AgentsFaceBadge(
                    size: AgentsLayout.agentIcon,
                    faceSize: 18,
                    ink: isActive ? FlowCueTheme.textPrimary : FlowCueTheme.textSecondary,
                    smile: isActive ? FlowCueTheme.accent : FlowCueTheme.textSecondary,
                    background: FlowCueTheme.surface,
                    cornerRadius: 8
                )
            }
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
        // 实心画布底：视觉上与屏幕底一致；自动对比度审计需要真实背景色，
        // 透明节点会被当成白底而误报。
        .background(FlowCueTheme.canvas)
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
    @State private var showingPairing = AgentsPreview.requestedState == "pairing"
    @State private var showingAddAgent = AgentsPreview.requestedState == "addAgent"
    @State private var showingRemote = AgentsPreview.requestedState == "remote"
    @State private var showingCodex = AgentsPreview.requestedState == "codex"
    @State private var showingDSH = AgentsPreview.requestedState == "dsh"
    @State private var showingChat = ["chat", "chatEmpty", "chatDsh"].contains(AgentsPreview.requestedState ?? "")
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
                    } else if showsCannotReach {
                        cannotReachContent
                    } else if controller.isPaired {
                        connectedContent
                            .task { await loadAgentsIfNeeded() }
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
        .edgeSwipeBack()
            .navigationDestination(isPresented: $showingRemote) {
                RemoteDeviceView(controller: controller, tab: $tab)
            }
            .navigationDestination(isPresented: $showingCodex) {
                CodexAgentView(controller: controller, tab: $tab)
            }
            .navigationDestination(isPresented: $showingDSH) {
                DSHAgentView(controller: controller, tab: $tab)
            }
            .navigationDestination(isPresented: $showingChat) {
                ChatPreviewHost(controller: controller, tab: $tab)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FlowCueTabBar(selection: $tab)
            }
            .task { network.start() }
            .task {
                while !Task.isCancelled {
                    if controller.isOnline {
                        await controller.refresh()
                    }
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onDisappear {
                network.stop()
                controller.stopDiscovery()
            }
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
        // 已配对（尤其远程）时继续显示设备页：离线只是状态，不是「找不到设备」。
        // 详情页里可以直接 Reconnect。
        guard !controller.isPaired else { return false }
        return controller.lastAttempted != nil || controller.lastError != nil
    }

    private var showsDiscovering: Bool {
        if AgentsPreview.forcesDiscovering { return true }
        return !controller.isPaired
            && controller.lastAttempted == nil
            && controller.isScanning
            && controller.discovered.isEmpty
    }

    private var toolbarSymbol: String {
        if AgentsPreview.requestedState != nil {
            return "arrow.clockwise"
        }
        if controller.isPaired || controller.lastAttempted != nil || controller.isScanning {
            return "arrow.clockwise"
        }
        return "plus"
    }

    private func toolbarAction() {
        if controller.isPaired {
            Task {
                if controller.isOnline {
                    await controller.refresh()
                } else {
                    await controller.reconnect()
                }
            }
        } else if controller.lastAttempted != nil {
            Task { await controller.retryLastAttempt() }
        } else if controller.isScanning {
            controller.stopDiscovery()
            controller.startDiscovery()
        } else {
            showingPairing = true
        }
    }

    /// 进页面就拉一次，别等 3 秒轮询。
    private func loadAgentsIfNeeded() async {
        controller.loadCachedAgents()
        await controller.refreshAgents()
    }

    private var deviceName: String {
        FlowCueLinkFormat.deviceName(controller.selected?.name ?? controller.lastAttempted?.name)
    }

    // MARK: Connected

    @ViewBuilder
    private var deviceActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                disconnectControl
                changeCodeControl
            }
        } else {
            HStack(spacing: 14) {
                disconnectControl
                changeCodeControl
                Spacer(minLength: 0)
            }
        }
    }

    private var disconnectControl: some View {
        Button {
            controller.disconnect()
        } label: {
            Label(L10n.language == .mandarin ? "断连" : "Disconnect", systemImage: "bolt.horizontal.circle")
                .flowCueFont(11.5, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var changeCodeControl: some View {
        Button {
            controller.disconnect()
            showingPairing = true
        } label: {
            Label(L10n.language == .mandarin ? "更换配对码" : "Change code", systemImage: "number.circle")
                .flowCueFont(11.5, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private var connectedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isOffline {
                    FlowCueInlineBanner(
                        kind: .warning,
                        title: "No network. Agents need Wi-Fi."
                    )
                    .padding(.top, 10)
                } else if controller.isConnecting {
                    FlowCueInlineBanner(
                        kind: .warning,
                        title: "Connecting to your Mac…"
                    )
                    .padding(.top, 10)
                } else if let message = controller.lastError {
                    FlowCueInlineBanner(
                        kind: .failure,
                        title: message,
                        actionTitle: "Reconnect",
                        action: { Task { await controller.reconnect() } }
                    )
                    .padding(.top, 10)
                }

                // 有待回答的问题时在顶部提醒，避免只靠推送（推送可能失败）
                if !controller.dshQuestions.isEmpty {
                    FlowCueInlineBanner(
                        kind: .warning,
                        title: "\(controller.dshQuestions.count) 个问题在等你回答"
                    )
                    .padding(.top, 12)
                }

                AgentsSectionHeader(title: "DEVICES")
                    .padding(.top, 14)

                NavigationLink {
                    RemoteDeviceView(controller: controller, tab: $tab)
                } label: {
                    AgentsDeviceCard(
                        title: deviceName,
                        isOnline: controller.isOnline && !isOffline,
                        latency: FlowCueLinkFormat.latency(controller.lastLatencyMs)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                // 断连与重新配对放在设备卡片正下方：
                // 之前在「设备详情 → 底部」里，连着的时候根本找不到，
                // 也进不去配对面板（它只在未连接状态可打开）。
                deviceActions
                    .padding(.horizontal, AgentsLayout.margin)
                    .padding(.top, 10)

                AgentsSectionHeader(title: "AGENTS ON THIS MAC")
                    .padding(.top, 16)

                VStack(spacing: 0) {
                    if controller.agentInfos.isEmpty {
                        if let agentsError = controller.agentsError {
                            FlowCueInlineBanner(
                                kind: .failure,
                                title: "Couldn't load agents — \(agentsError)",
                                actionTitle: "Retry",
                                action: { Task { await controller.refreshAgents() } }
                            )
                            .padding(.horizontal, AgentsLayout.margin)
                            .padding(.vertical, 12)
                        } else {
                            // 刚连上时第一次统计要扫各家的会话目录，先给个占位，
                            // 不要留一片空白让人以为没装上 Agent。
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在读取这台 Mac 上的 Agent…")
                                    .flowCueFont(12, relativeTo: .caption)
                                    .foregroundStyle(FlowCueTheme.textSecondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, AgentsLayout.margin)
                            .padding(.vertical, 16)
                        }
                    }
                    ForEach(controller.agentInfos) { agent in
                        NavigationLink {
                            AgentSessionsView(controller: controller, tab: $tab, agent: agent)
                        } label: {
                            AgentsAgentRow(
                                title: agent.displayName,
                                meta: agentMeta(agent),
                                isActive: controller.isOnline && !isOffline && agent.sessionCount > 0,
                                agentID: agent.id
                            )
                        }
                        .buttonStyle(.plain)
                        Rectangle()
                            .fill(FlowCueTheme.hairline)
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }

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

    /// Agents 页每行的副标题：会话数 · 项目数。
    private func agentMeta(_ agent: RemoteAgentInfo) -> String {
        let sessions = "\(agent.sessionCount) sessions"
        guard agent.projectCount > 0 else { return sessions }
        return "\(sessions) · \(agent.projectCount) projects"
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
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
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

private struct FlowCueMacPairingCard: View {
    private var isMandarin: Bool { L10n.language == .mandarin }

    var body: some View {
        VStack(spacing: 10) {
            Text(isMandarin ? "还没有配对的 Mac？" : "No Mac paired yet?")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)

            Text(isMandarin
                 ? "Mac 上没有 FlowCue？先下载安装，再用它显示的配对码连接。"
                 : "Install FlowCue on your Mac first, then enter the code it shows.")
                .flowCueFont(11, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                UIApplication.shared.open(FlowCueMacDownload.pairingURL)
            } label: {
                Text(isMandarin ? "在浏览器打开 Mac 下载页" : "Open the Mac download page")
                    .flowCueFont(11.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.accent)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isMandarin ? "打开 Mac 版下载页" : "Opens the Mac download page")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
    }
}


private struct PairMacSheet: View {
    @Bindable var controller: LANRemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var target: DiscoveredMac?
    @State private var showingManual = false
    @State private var remoteCode = ""
    @State private var remoteBusy = false
    @State private var remoteError: String?
    @State private var showingRemote = true
    @FocusState private var codeFocused: Bool

    private var canConnect: Bool {
        guard controller.pairingCode.count == 6 else { return false }
        if target != nil { return true }
        return showingManual && !controller.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPairing {
                    pairingView
                } else if hasFailed {
                    pairingFailedView
                } else {
                    form
                }
            }
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
                if !isPairing && !hasFailed {
                    connectButton
                }
            }
            .task {
                if !controller.isScanning { controller.startDiscovery() }
                // 5G/不同 Wi-Fi 时没有 nearby Mac，直接展开远程配对，
                // 避免把本机“同一 Wi-Fi 配对码”误当成远程码。
                if controller.discovered.isEmpty { showingRemote = true }
            }
            .onChange(of: controller.pairingCode) { _, value in
                let digits = String(value.filter { "0123456789".contains($0) }.prefix(6))
                if digits != value { controller.pairingCode = digits }
            }
            .onChange(of: controller.isPaired) { _, paired in
                if paired { dismiss() }
            }
        }
    }

    private var isPairing: Bool { controller.isLoading }
    private var hasFailed: Bool { !controller.isLoading && controller.lastError != nil }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 没有发现同一 Wi-Fi 的 Mac（典型是 5G）时，只显示远程配对：
                // 不能再把“同一 Wi-Fi 配对码”输入框放在最前面，否则用户会把
                // 本地码填进去，远程 claim 永远查不到。
                if controller.discovered.isEmpty {
                    remoteSection
                    manualSection
                } else {
                    codeSection
                    nearbySection
                    manualSection
                    remoteSection
                }
                FlowCueMacPairingCard()
                    .padding(.top, 22)

                Text(controller.versionHandshakeText)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 14)
            }
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var pairingView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AgentsRingSpinner(size: 34)
            Text("Pairing with \(pairingDeviceName)")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 18)
            Text("Approve the code on your Mac")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.top, 4)
            Text(controller.pairingCode.map(String.init).joined(separator: " "))
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AgentsLayout.margin)
    }

    private var pairingFailedView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(FlowCueTheme.failure.opacity(0.16)).frame(width: 56, height: 56)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.failure)
            }
            Text("Pairing failed")
                .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 14)
            Text(controller.lastError ?? "The code expired or the Mac went offline.")
                .flowCueFont(12, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
                .padding(.top, 6)
            Text(controller.versionHandshakeText)
                .flowCueFont(11, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if controller.needsMacUpdate {
                Link(destination: FlowCueMacDownload.settingsURL) {
                    Text("Update Mac FlowCue")
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.accent)
                }
                .padding(.top, 10)
            }
            Button {
                Task { await connect() }
            } label: {
                Text("Try again")
                    .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            Button("Pair a different Mac") {
                controller.lastError = nil
                target = nil
                showingManual = false
            }
            .flowCueFont(12, relativeTo: .caption)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AgentsLayout.margin)
    }

    private var pairingDeviceName: String {
        FlowCueLinkFormat.deviceName(target?.name ?? controller.lastAttempted?.name)
    }

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter the code (same Wi-Fi)")
                .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Text("Shown in Mac FlowCue → iPhone. On 5G, open the remote section below.")
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
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                        .fill(FlowCueTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
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
                cornerRadius: FlowCueTheme.radiusInline,
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
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(selected ? FlowCueTheme.accent.opacity(0.6) : FlowCueTheme.hairline)
        )
        .contentShape(Rectangle())
    }

    /// 不在同一 Wi-Fi 时：用 6 位码通过中继配对。
    private var remoteSection: some View {
        DisclosureGroup(isExpanded: $showingRemote) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("先在 Mac 的 FlowCue → 设置 → Remote 打开远程连接，然后把那里的 6 位码输进来。"))
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(L10n.text("6 位配对码"), text: $remoteCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .multilineTextAlignment(.center)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                            .fill(FlowCueTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                            .strokeBorder(FlowCueTheme.hairline)
                    )
                    .onChange(of: remoteCode) { _, value in
                        let digits = String(value.filter { "0123456789".contains($0) }.prefix(6))
                        if digits != value { remoteCode = digits }
                    }

                if let remoteError {
                    Text(remoteError)
                        .flowCueFont(11, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.failure)
                }

                Button {
                    Task {
                        remoteBusy = true
                        remoteError = nil
                        let failure = await controller.pairRemote(code: remoteCode)
                        remoteBusy = false
                        if let failure {
                            remoteError = failure
                        } else {
                            controller.adoptRemoteDevice()
                            await controller.refresh()
                            dismiss()
                        }
                    }
                } label: {
                    Text(L10n.text(remoteBusy ? "正在等待 Mac 批准…" : "通过中继配对"))
                        .flowCueFont(13.5, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                                .fill(FlowCueTheme.accent.opacity(remoteCode.count == 6 && !remoteBusy ? 1 : 0.4))
                        )
                }
                .buttonStyle(.plain)
                .disabled(remoteCode.count != 6 || remoteBusy)
            }
            .padding(.top, 8)
        } label: {
            Text(L10n.text("5G / 不在同一 Wi-Fi？用远程配对码"))
                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(FlowCueTheme.accent)
        }
        .tint(FlowCueTheme.textSecondary)
        .padding(.top, 12)
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
                        RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                            .fill(FlowCueTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
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
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .fill(canConnect ? FlowCueTheme.accent : FlowCueTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .strokeBorder(canConnect ? Color.clear : FlowCueTheme.hairline)
                )
                .contentShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous))
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
        if controller.isPaired { dismiss() }
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
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var reconnecting = false

    private var name: String {
        FlowCueLinkFormat.deviceName(controller.selected?.name ?? controller.lastAttempted?.name)
    }

    private var isOnline: Bool { controller.isOnline }

    private var statusText: String {
        switch controller.linkState {
        case .online: return controller.isRemote ? "Online · Remote" : "Online · Wi-Fi"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        case .offline: return "Offline"
        }
    }

    private var statusTint: Color {
        switch controller.linkState {
        case .online: return FlowCueTheme.mint
        case .connecting: return FlowCueTheme.accent
        case .offline: return FlowCueTheme.failure
        case .disconnected: return FlowCueTheme.textSecondary
        }
    }

    private var showsConnecting: Bool { controller.isConnecting || reconnecting }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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
                        cornerRadius: FlowCueTheme.radiusPanel,
                        bordered: true
                    )
                    Text(name)
                        .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .padding(.top, 14)
                    HStack(spacing: 5) {
                        if showsConnecting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle()
                                .fill(statusTint)
                                .frame(width: 5, height: 5)
                        }
                        Text(statusText)
                    }
                    .flowCueFont(12, relativeTo: .caption)
                    .foregroundStyle(statusTint)
                    .padding(.top, 6)

                    if case .offline(let reason) = controller.linkState, !reason.isEmpty {
                        Text(reason)
                            .flowCueFont(11, relativeTo: .caption2)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.horizontal, AgentsLayout.margin)
                    }

                    VStack(spacing: 0) {
                        infoRow("Latency", FlowCueLinkFormat.latency(controller.lastLatencyMs) ?? "—")
                        infoRow("Last sync", FlowCueLinkFormat.relative(controller.lastRefreshAt))
                        infoRow("Version", controller.versionHandshakeText, monospaced: true)
                        infoRow(
                            "Pairing",
                            FlowCueLinkFormat.fingerprint(pairingFingerprintSeed(name)),
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
        .edgeSwipeBack()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if isOnline {
                    NavigationLink {
                        chatDestination
                    } label: {
                        Text("Open chat")
                            .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open chat")

                    disconnectButton
                } else {
                    // 掉线时也要能重连：以前这里调用 retryLastAttempt()，
                    // 而远程模式没有 lastAttempted，点下去什么都不会发生。
                    Button {
                        guard !showsConnecting else { return }
                        reconnecting = true
                        Task {
                            await controller.reconnect()
                            reconnecting = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if showsConnecting {
                                ProgressView().controlSize(.small).tint(FlowCueTheme.onAccent)
                            }
                            Text(showsConnecting ? "Connecting…" : "Reconnect")
                                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                        }
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .background(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                                .fill(FlowCueTheme.accent.opacity(showsConnecting ? 0.55 : 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(showsConnecting)
                    .accessibilityLabel(showsConnecting ? "Connecting" : "Reconnect")

                    if controller.isPaired {
                        NavigationLink {
                            chatDestination
                        } label: {
                            Text("Open saved sessions")
                                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                                .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.surface))
                                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open saved sessions")
                    }

                    disconnectButton
                }
            }
            .padding(.horizontal, AgentsLayout.margin)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(FlowCueTheme.canvas)
        }
    }

    private var disconnectButton: some View {
        Button {
            controller.disconnect()
            dismiss()
        } label: {
            Text("Disconnect")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Disconnect from this Mac")
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
            ChatScreen(controller: controller, tab: $tab, initialTarget: .codex(thread))
        } else {
            CodexAgentView(controller: controller, tab: $tab)
        }
    }

    /// 远程模式没有 LAN 配对码；再用它做指纹会对所有 Mac 都显示同一串。
    private func pairingFingerprintSeed(_ name: String) -> String {
        if controller.isRemote {
            return "remote|\(RemoteCredentials.pairID ?? "")|\(RemoteCredentials.macID ?? "")"
        }
        return "\(name)|\(controller.pairingCode)"
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    infoLabel(label)
                    infoValue(value, monospaced: monospaced)
                }
            } else {
                HStack {
                    infoLabel(label)
                    Spacer()
                    infoValue(value, monospaced: monospaced)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowCueTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func infoLabel(_ label: String) -> some View {
        Text(label)
            .flowCueFont(12.5, relativeTo: .caption)
            .foregroundStyle(FlowCueTheme.textSecondary)
    }

    private func infoValue(_ value: String, monospaced: Bool) -> some View {
        // 用语义 caption 而不是固定 12.5pt：否则大字号下标签放大了、值还是小的。
        Text(value)
            .font(.system(.caption, design: monospaced ? .monospaced : .default))
            .foregroundStyle(FlowCueTheme.textPrimary)
            .multilineTextAlignment(.trailing)
    }
}


private struct DSHApprovalCard: View {
    let approval: DSHRemoteApproval
    let decide: (String) async -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("APPROVAL REQUIRED")
                .flowCueFont(9.5, relativeTo: .caption2)
                .tracking(1.3)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Text(approval.title)
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .lineLimit(4)
                .padding(.top, 6)
            if let tool = approval.toolName {
                Text(tool)
                    .flowCueFont(9.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            if let reason = approval.reason, reason != approval.title {
                Text(reason)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(4)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                Button {
                    busy = true
                    Task { await decide("allowed-once"); busy = false }
                } label: {
                    Text("Approve")
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                                .fill(FlowCueTheme.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    busy = true
                    Task { await decide("rejected"); busy = false }
                } label: {
                    Text("Deny")
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                                .strokeBorder(FlowCueTheme.hairline)
                        )
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            .padding(.top, 12)
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
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
    var detail: String?
    let retry: () -> Void

    init(detail: String? = nil, retry: @escaping () -> Void) {
        self.detail = detail
        self.retry = retry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowCueInlineBanner(
                kind: .failure,
                title: detail.map { "Couldn't load sessions — \($0)" } ?? "Couldn't load sessions",
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
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
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

private struct DSHQuestionCard: View {
    let question: DSHRemoteQuestionBatch.Question
    let answer: ([String]) async -> Void

    @State private var selection: Set<String> = []
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUESTION")
                .flowCueFont(9.5, relativeTo: .caption2)
                .tracking(1.3)
                .foregroundStyle(FlowCueTheme.textSecondary)
            Text(question.title)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
            if let detail = question.detail, !detail.isEmpty {
                Text(detail)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(6)
            }
            VStack(spacing: 8) {
                ForEach(question.options, id: \.label) { option in
                    Button {
                        choose(option.label)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(option.label)
                                    .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                                    .foregroundStyle(selection.contains(option.label)
                                                     ? FlowCueTheme.onAccent
                                                     : FlowCueTheme.textPrimary)
                                Spacer(minLength: 0)
                                if selection.contains(option.label) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(FlowCueTheme.onAccent)
                                }
                            }
                            if let detail = option.detail, !detail.isEmpty {
                                Text(detail)
                                    .flowCueFont(10, relativeTo: .caption2)
                                    .foregroundStyle(selection.contains(option.label)
                                                     ? FlowCueTheme.onAccent.opacity(0.8)
                                                     : FlowCueTheme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                                .fill(selection.contains(option.label)
                                      ? FlowCueTheme.accent
                                      : FlowCueTheme.canvas)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            if question.multiSelect {
                Button {
                    submit()
                } label: {
                    Text("回答")
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                            .fill(selection.isEmpty ? FlowCueTheme.hairline : FlowCueTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(busy || selection.isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
    }

    /// 单选：点一下直接提交；多选：切换后按「回答」。
    private func choose(_ label: String) {
        guard !question.multiSelect else {
            if selection.contains(label) { selection.remove(label) } else { selection.insert(label) }
            return
        }
        selection = [label]
        submit()
    }

    private func submit() {
        guard !busy, !selection.isEmpty else { return }
        busy = true
        let chosen = question.options.map(\.label).filter { selection.contains($0) }
        Task {
            await answer(chosen)
            busy = false
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
            // 多条时把剩余数量放进标题，用户知道还有没有下一条。
            .navigationTitle(controller.dshApprovals.count > 1
                             ? "Approvals · \(controller.dshApprovals.count)"
                             : "Approvals")
            .navigationBarTitleDisplayMode(.inline)
            // 最后一条决定完就自己关，不必再去点 Done。
            .onChange(of: controller.dshApprovals.isEmpty) { _, isEmpty in
                guard isEmpty else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    dismiss()
                }
            }
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        // 半屏卡片：单条审批时不占满整屏，背景还能看见；多条可以上拉看全部。
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
        controller.isOnline && network.isOnline
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
        .edgeSwipeBack()
        .task {
            network.start()
            controller.loadCachedSkills()
            await controller.refreshSkills()
        }
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
                                ChatScreen(controller: controller, tab: $tab, initialTarget: .codex(thread))
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
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .strokeBorder(
                            FlowCueTheme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous))
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

    /// 按项目文件夹分组。Mac 端侧栏就是这么分的，iOS 之前把所有项目混在一个列表里，
    /// 会话一多就分不清哪个属于哪个项目。
    private var groupedSessions: [(project: String, sessions: [DSHSessionSnapshot])] {
        Dictionary(grouping: sessions) { session in
            let path = session.projectDirectory
            guard !path.isEmpty else { return "未关联项目" }
            return (path as NSString).lastPathComponent
        }
        .map { (project: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
        .sorted { lhs, rhs in
            (lhs.sessions.first?.updatedAt ?? .distantPast) > (rhs.sessions.first?.updatedAt ?? .distantPast)
        }
    }

    private var isOnline: Bool {
        controller.isOnline && network.isOnline
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
        .edgeSwipeBack()
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
                        ForEach(groupedSessions, id: \.project) { group in
                            // 项目标题：和 Mac 侧栏一致，按文件夹名分组
                            HStack(spacing: 6) {
                                Text(group.project.uppercased())
                                    .flowCueFont(10, relativeTo: .caption2)
                                    .tracking(1.0)
                                    .foregroundStyle(FlowCueTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(group.sessions.count)")
                                    .flowCueFont(10, relativeTo: .caption2)
                                    .foregroundStyle(FlowCueTheme.textSecondary)
                            }
                            .padding(.horizontal, AgentsLayout.margin)
                            .padding(.top, 16)
                            .padding(.bottom, 6)

                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    ChatScreen(controller: controller, tab: $tab, initialTarget: .dsh(session))
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
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .strokeBorder(
                            FlowCueTheme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityLabel("New session")
    }
}


// MARK: - Chat

private enum ChatKind: String {
    case codex
    case dsh

    var agentName: String {
        switch self {
        case .codex: "Codex"
        case .dsh: "DSH"
        }
    }
}

private enum ChatTarget: Equatable {
    case codex(RemoteThreadSnapshot)
    case dsh(DSHSessionSnapshot)

    var kind: ChatKind {
        switch self {
        case .codex: .codex
        case .dsh: .dsh
        }
    }

    var id: String {
        switch self {
        case .codex(let thread): "codex-\(thread.id)"
        case .dsh(let session): "dsh-\(session.id)"
        }
    }

    var agentName: String { kind.agentName }

    var codexThread: RemoteThreadSnapshot? {
        if case .codex(let thread) = self { return thread }
        return nil
    }

    var dshSession: DSHSessionSnapshot? {
        if case .dsh(let session) = self { return session }
        return nil
    }

    var projectDirectory: String? {
        switch self {
        case .codex(let thread): thread.projectDirectory
        case .dsh(let session): session.projectDirectory
        }
    }
}

private struct PendingChatMessage: Identifiable {
    enum State {
        case sending
        case failed
    }

    let id = UUID()
    let text: String
    let images: [Data]
    var state: State
}

private struct ChatScreen: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    let initialTarget: ChatTarget

    @Environment(\.dismiss) private var dismiss
    @State private var switchedTarget: ChatTarget?
    @State private var messages: [RemoteConversationMessage] = []
    @State private var dshTotal = 0
    @State private var dshOldestOffset = 0
    @State private var lastInitialLoadAt = Date.distantPast
    @State private var loadingOlder = false
    @State private var subagents: [DSHSessionSnapshot] = []
    @State private var text = ""
    @State private var pending: PendingChatMessage?
    @State private var sending = false
    @State private var loading = false
    @State private var loadError: String?
    @State private var network = FlowCueNetworkMonitor()
    @State private var showingSwitcher = false
    @State private var showingDevice = false
    @State private var showingDisconnect = false
    @State private var showingApprovals = false
    @State private var isAtBottom = true

    /// 输入 `/xxx`（尚未空格）时展示 skill 候选。
    private var skillQuery: String {
        guard text.hasPrefix("/"), !text.dropFirst().contains(" ") else { return "" }
        return String(text.dropFirst())
    }
    private var showsSkillMenu: Bool {
        text.hasPrefix("/") && !text.dropFirst().contains(" ")
    }
    @State private var live = FlowCueLiveActivityController.shared

    private var target: ChatTarget { switchedTarget ?? initialTarget }

    private var isOnline: Bool {
        controller.isOnline && network.isOnline
    }

    private var displayMessages: [RemoteConversationMessage] {
        if messages.isEmpty,
           let thread = target.codexThread,
           !thread.lastReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [
                RemoteConversationMessage(
                    id: "fallback-\(thread.id)",
                    role: "assistant",
                    text: thread.lastReply,
                    timestamp: thread.updatedAt
                )
            ]
        }
        return messages
    }

    private var approvals: [DSHRemoteApproval] {
        guard let session = target.dshSession else { return [] }
        return controller.dshApprovals.filter { $0.sessionId == session.id }
    }

    private var showsEmptyState: Bool {
        displayMessages.isEmpty
            && pending == nil
            && approvals.isEmpty
            && !loading
    }

    /// 属于当前会话的提问卡。提问卡只在对应 chat 里出现，不全局弹。
    private var sessionQuestions: [DSHRemoteQuestionBatch] {
        guard case .dsh(let session) = target else { return [] }
        return controller.dshQuestions.filter { $0.sessionId == session.id }
    }

    /// Mac 上正在执行的动作，来自 DSH 会话日志里的 tool/call 或 turn。
    @State private var activityLabel: String?
    @State private var activitySince: Date?

    private var isWorking: Bool {
        isOnline && (sending || activityLabel != nil || displayMessages.last?.role == "user")
    }

    /// 和电脑端一致的写法：动作 · 已耗时
    private func activityText(at date: Date) -> String {
        guard let activityLabel else { return "\(target.agentName) is working…" }
        guard let activitySince else { return activityLabel }
        let seconds = max(0, Int(date.timeIntervalSince(activitySince)))
        return "\(activityLabel) · \(seconds)s"
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            chatStatus
            if !isOnline {
                FlowCueInlineBanner(
                    kind: .warning,
                    title: "Offline — messages can be retried when reconnected."
                )
                .padding(.horizontal, 18)
                .padding(.top, 8)
            } else if let loadError, !displayMessages.isEmpty {
                FlowCueInlineBanner(
                    kind: .failure,
                    title: "Couldn't refresh — \(loadError)",
                    actionTitle: "Retry",
                    action: { Task { await reloadOnce() } }
                )
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            content
            if isWorking {
                // 每秒刷新一次，显示「执行命令 · … · 12s」，和电脑端的
                // "Deep diving for 12s" 同一个意思。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(FlowCueTheme.textSecondary)
                        Text(activityText(at: context.date))
                            .flowCueFont(11, relativeTo: .caption2)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 2)
                }
            }
            ForEach(sessionQuestions) { batch in
                VStack(spacing: 10) {
                    ForEach(batch.questions) { question in
                        DSHQuestionCard(question: question) { chosen in
                            _ = await controller.answerDSH(
                                batchID: batch.id, questionID: question.id, chosen: chosen
                            )
                        }
                    }
                }
                .padding(.horizontal, AgentsLayout.margin)
                .padding(.bottom, 8)
            }
            if showsSkillMenu {
                SlashSkillMenu(skills: controller.skills, query: skillQuery) { name in
                    text = "/" + name + " "
                }
                .task(id: showsSkillMenu) {
                    if controller.skills.isEmpty { await controller.refreshSkills() }
                }
            }
            ChatComposer(text: $text, sending: sending) { images in
                send(images)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background { FlowCueScreenBackground() }
        .toolbar(.hidden, for: .navigationBar)
        .edgeSwipeBack()
        .task { network.start() }
        .onDisappear { network.stop() }
        .task(id: target.id) { await runChat() }
        .onChange(of: controller.isOnline) { _, online in
            // 只在真正重连后补一次；视图初次出现由 runChat 负责，
            // 否则会并发拉两遍 2MB 历史，5G 下很容易把首个请求拖到超时。
            if online { Task { await reloadOnce() } }
        }
        .onChange(of: displayMessages.last?.id) { _, _ in updateLiveActivity() }
        .onChange(of: isWorking) { _, _ in updateLiveActivity() }
        .onChange(of: pending?.state == .failed) { _, _ in updateLiveActivity() }
        .sheet(isPresented: $showingApprovals) {
            DSHApprovalsSheet(controller: controller)
        }
        .sheet(isPresented: $showingSwitcher) {
            ChatSwitcherSheet(
                controller: controller,
                target: target,
                subagents: subagents,
                onSelect: { select($0) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showingDevice) {
            RemoteDeviceView(controller: controller, tab: $tab)
        }
        .confirmationDialog(
            "Disconnect from this Mac?",
            isPresented: $showingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                controller.disconnect()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions stay on your Mac. You can pair again anytime.")
        }
    }

    // MARK: Header

    private var chatHeader: some View {
        ZStack {
            Button {
                showingSwitcher = true
            } label: {
                HStack(spacing: 4) {
                    Text(target.agentName)
                        .flowCueFont(16, relativeTo: .headline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch session")

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

                Menu {
                    Button("Refresh") {
                        Task { await reloadOnce() }
                    }
                    Button(live.isActive ? "Stop Live Activity" : "Start Live Activity") {
                        if live.isActive {
                            stopLiveActivity()
                        } else {
                            startLiveActivity()
                        }
                    }
                    Button("Device info") {
                        showingDevice = true
                    }
                    Divider()
                    Button("Disconnect", role: .destructive) {
                        showingDisconnect = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Session options")
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 10)
    }

    private var chatStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? FlowCueTheme.mint : FlowCueTheme.failure)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(isOnline ? "online · \(FlowCueLinkFormat.deviceName(controller.selected?.name))" : "offline")
        }
        .flowCueFont(11, relativeTo: .caption2)
        .foregroundStyle(isOnline ? FlowCueTheme.mint : FlowCueTheme.failure)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loading && displayMessages.isEmpty && pending == nil {
            ProgressView()
                .tint(FlowCueTheme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, displayMessages.isEmpty, pending == nil {
            VStack(spacing: 12) {
                FlowCueInlineBanner(
                    kind: .failure,
                    title: "Couldn't load conversation — \(loadError)",
                    actionTitle: "Retry",
                    action: { Task { await reloadOnce() } }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
        } else if showsEmptyState {
            ChatEmptyState()
        } else {
            messageList
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if case .dsh = target, dshOldestOffset > 0 {
                        Button {
                            Task { await loadOlder() }
                        } label: {
                            HStack(spacing: 6) {
                                if loadingOlder {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.up.circle")
                                }
                                Text(L10n.text("加载更早的消息"))
                            }
                            .flowCueFont(11.5, relativeTo: .caption, weight: .medium)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingOlder)
                    }
                    ForEach(displayMessages) { message in
                        ChatMessageBubble(message: message)
                            .id(message.id)
                    }
                    if let pending {
                        ChatPendingBubble(pending: pending) {
                            retry()
                        }
                        .id(pending.id)
                    }
                    ForEach(approvals) { approval in
                        DSHApprovalCard(approval: approval) { decision in
                            _ = await controller.decideDSH(approval, decision: decision)
                        }
                        .id("approval-\(approval.id)")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("chat-bottom")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onAppear { scrollToBottom(proxy) }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FlowCueTheme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(FlowCueTheme.surface))
                            .overlay(Circle().strokeBorder(FlowCueTheme.hairline))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Scroll to latest")
                }
            }
            .onChange(of: displayMessages.last?.id) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: pending?.id) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: approvals.count) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Data

    private var liveSessionTitle: String {
        target.codexThread?.title ?? target.dshSession?.title ?? target.agentName
    }

    private func liveState(status: FlowCueActivityStatus) -> FlowCueActivityAttributes.ContentState {
        let detailSource = displayMessages.last(where: { $0.role == "assistant" })?.text
            ?? pending?.text
            ?? "Waiting for the next reply"
        let elapsed: String
        if let startedAt = live.startedAt {
            let seconds = max(0, Int(Date.now.timeIntervalSince(startedAt)))
            elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        } else {
            elapsed = "0s"
        }
        return FlowCueActivityAttributes.ContentState(
            title: liveSessionTitle,
            detail: String(detailSource.prefix(90)),
            status: status,
            elapsed: elapsed,
            updatedAt: .now
        )
    }

    private func startLiveActivity() {
        guard !live.isActive else { return }
        live.start(
            attributes: FlowCueActivityAttributes(
                sessionID: target.id,
                agent: target.agentName,
                startedAt: .now
            ),
            state: liveState(status: .running)
        )
    }

    private func stopLiveActivity() {
        guard live.isActive else { return }
        live.stop(liveState(status: .completed))
    }

    private func updateLiveActivity() {
        guard live.isActive else { return }
        let failed = pending?.state == .failed
        live.update(liveState(status: failed ? .failed : .running))
    }

    private func runChat() async {
        loading = true
        await refreshApprovalsIfNeeded()
        await refreshSubagentsIfNeeded()
        do {
            try await loadInitialMessages()
            loadError = nil
        } catch {
            loadError = LANRemoteController.connectionMessage(for: error)
        }
        loading = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            await refreshApprovalsIfNeeded()
            await refreshSubagentsIfNeeded()
            do {
                try await loadIncrementalMessages()
                loadError = nil
            } catch {
                // 保留已经显示的消息，只在顶部显示原因。
                loadError = LANRemoteController.connectionMessage(for: error)
            }
            if case .dsh(let session) = target {
                let next = await controller.dshActivity(for: session)
                if next?.label != activityLabel {
                    activityLabel = next?.label
                    activitySince = next?.since
                }
            }
        }
    }

    private func reloadOnce() async {
        // 首屏与“刚重连”可能同时触发；1MB 历史不能并发拉两遍。
        guard !loading, Date().timeIntervalSince(lastInitialLoadAt) > 2 else { return }
        await refreshApprovalsIfNeeded()
        do {
            try await loadInitialMessages()
            loadError = nil
        } catch {
            loadError = LANRemoteController.connectionMessage(for: error)
        }
    }

    /// 初始只取最近 60 条，避免 5G 首屏拉 2MB+ 历史。
    private func loadInitialMessages() async throws {
        switch target {
        case .dsh(let session):
            let page = try await controller.dshMessagePage(for: session, tail: 20)
            messages = page.messages
            dshTotal = page.total
            dshOldestOffset = page.start
        case .codex(let thread):
            messages = try await controller.messages(for: thread)
            dshTotal = 0
            dshOldestOffset = 0
        }
        lastInitialLoadAt = Date()
    }

    private func loadIncrementalMessages() async throws {
        switch target {
        case .dsh(let session):
            let page = try await controller.dshMessagePage(for: session, after: dshTotal)
            if !page.messages.isEmpty {
                messages.append(contentsOf: page.messages)
            }
            dshTotal = page.total
        case .codex(let thread):
            let updated = try await controller.messages(for: thread)
            if updated != messages { messages = updated }
        }
    }

    private func loadOlder() async {
        guard case .dsh(let session) = target, dshOldestOffset > 0, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await controller.dshMessagePage(
                for: session, before: dshOldestOffset, limit: 20
            )
            messages = page.messages + messages
            dshOldestOffset = page.start
            dshTotal = page.total
        } catch {
            loadError = LANRemoteController.connectionMessage(for: error)
        }
    }

    private func refreshApprovalsIfNeeded() async {
        await controller.refreshApprovals()
    }

    private func refreshSubagentsIfNeeded() async {
        if let session = target.dshSession {
            subagents = await controller.dshSubagents(for: session)
        } else {
            subagents = []
        }
    }

    private func fetchMessages(for target: ChatTarget, afterCount: Int = 0) async throws -> [RemoteConversationMessage] {
        switch target {
        case .codex(let thread):
            return try await controller.messages(for: thread)
        case .dsh(let session):
            // afterCount > 0 时只取新增，避免每 3 秒重传 751KB 历史。
            return try await controller.dshMessages(for: session, after: afterCount)
        }
    }

    private func select(_ newTarget: ChatTarget) {
        guard newTarget != target else {
            showingSwitcher = false
            return
        }
        switchedTarget = newTarget
        messages = []
        dshTotal = 0
        dshOldestOffset = 0
        pending = nil
        subagents = []
        loading = true
        showingSwitcher = false
    }

    // MARK: Sending

    private func send(_ images: [Data]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !images.isEmpty), pending?.state != .sending else { return }
        let item = PendingChatMessage(text: trimmed, images: images, state: .sending)
        let sessionTarget = target
        pending = item
        text = ""
        sending = true
        startWatchdog()
        Task { await deliver(item, to: sessionTarget) }
    }

    /// 兜底：任何一次发送如果没能回到 deliver 的收尾（连接半死、任务被取消），
    /// `sending` 会永远为 true，输入框从此锁死。超过 45 秒强制解开。
    private func startWatchdog() {
        Task {
            try? await Task.sleep(for: .seconds(45))
            guard sending else { return }
            sending = false
            if pending?.state == .sending { pending?.state = .failed }
        }
    }

    private func retry() {
        guard var item = pending, item.state == .failed else { return }
        let sessionTarget = target
        item.state = .sending
        pending = item
        sending = true
        startWatchdog()
        Task { await deliver(item, to: sessionTarget) }
    }

    private func deliver(_ item: PendingChatMessage, to sessionTarget: ChatTarget) async {
        guard isOnline else {
            if sessionTarget == target { pending?.state = .failed }
            sending = false
            return
        }
        let ok: Bool
        switch sessionTarget {
        case .codex(let thread):
            ok = await controller.send(to: thread, text: item.text, images: item.images)
        case .dsh(let session):
            ok = await controller.sendDSH(
                to: session,
                text: item.text,
                images: item.images,
                requestID: item.id.uuidString
            )
        }
        if ok {
            if sessionTarget == target {
                pending = nil
                messages = (try? await fetchMessages(for: sessionTarget)) ?? messages
                loadError = nil
            }
        } else if sessionTarget == target {
            // 超时 ≠ 没送到：桥接转发前要先唤醒 DSH 的 agent，消息可能已经进队列。
            // 核对最近几条，命中就当已送达，避免用户反复重发。
            let refreshed = (try? await fetchMessages(for: sessionTarget)) ?? []
            let delivered = !item.text.isEmpty
                && refreshed.suffix(3).contains { $0.text.contains(item.text) }
            if delivered {
                pending = nil
                messages = refreshed
            } else {
                pending?.state = .failed
                loadError = controller.lastError ?? L10n.text("发送失败。")
            }
        }
        sending = false
    }
}

// MARK: Chat components

private struct ChatPreviewHost: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab

    var body: some View {
        Group {
            if AgentsPreview.requestedState == "chatEmpty" {
                ChatScreen(
                    controller: controller,
                    tab: $tab,
                    initialTarget: .codex(
                        RemoteThreadSnapshot(
                            id: "preview-empty",
                            title: "New session",
                            projectDirectory: nil,
                            lastReply: "",
                            updatedAt: .now,
                            executorID: UUID()
                        )
                    )
                )
            } else if AgentsPreview.requestedState == "chatDsh" {
                if let session = controller.dshSessions.first {
                    ChatScreen(controller: controller, tab: $tab, initialTarget: .dsh(session))
                } else {
                    ProgressView()
                        .tint(FlowCueTheme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let thread = controller.threads.first {
                ChatScreen(controller: controller, tab: $tab, initialTarget: .codex(thread))
            } else {
                ProgressView()
                    .tint(FlowCueTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { FlowCueScreenBackground() }
        .task {
            if controller.threads.isEmpty {
                await controller.refresh()
            }
        }
    }
}

private struct ChatMessageBubble: View {
    let message: RemoteConversationMessage

    var body: some View {
        if message.role == "user" {
            userBubble
        } else {
            assistantBubble
        }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if let images = message.images, !images.isEmpty {
                    MessageImageGrid(images: images)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .flowCueFont(13, relativeTo: .subheadline)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
            }
            // 纯图片消息不要气泡底：气泡色和图片边缘不一致时会出现白边/色块。
            .padding(.horizontal, imageOnly ? 0 : 13)
            .padding(.vertical, imageOnly ? 0 : 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(imageOnly ? Color.clear : FlowCueTheme.accent)
            )
        }
    }

    /// 只有图片、没有文字：此时不应该画气泡背景。
    private var imageOnly: Bool {
        let hasImages = !(message.images?.isEmpty ?? true)
        return hasImages && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if let images = message.images, !images.isEmpty {
                    MessageImageGrid(images: images)
                }
                if !message.text.isEmpty {
                    MarkdownMessageView(text: message.text)
                }
            }
            .padding(.horizontal, imageOnly ? 0 : 13)
            .padding(.vertical, imageOnly ? 0 : 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(imageOnly ? Color.clear : FlowCueTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .strokeBorder(imageOnly ? Color.clear : FlowCueTheme.hairline.opacity(0.6))
            )
            Spacer(minLength: 32)
        }
    }
}

/// 左边缘拖拽返回。系统自带的交互式返回在这里会被 TabView 的翻页手势抢走，
/// 所以用一个高优先级手势兜住：只有从最左 24pt 起手、横向拖过 90pt 才触发。
private struct EdgeSwipeBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    /// 跟随手指的位移；手势结束会自动回零，配上下面的动画就是弹性回弹。
    @GestureState private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // 页面跟着手指往右走，松手回弹或返回。
            .offset(x: dragOffset)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: dragOffset)
            // 只在整个视图的最左 24pt 铺一条透明触控带：不抢列表的垂直滚动，
            // 也不影响页面中间的横向内容。
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .updating($dragOffset) { value, state, _ in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                // 只在横向为主时才跟手，避免竖滑时页面乱动。
                                state = abs(dx) > abs(dy) ? max(0, dx) : 0
                            }
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard dx > 90, abs(dy) < abs(dx) else { return }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dismiss()
                            }
                    )
            }
    }
}

extension View {
    /// 给推入的页面加上「从左边缘右拖返回」。
    func edgeSwipeBack() -> some View { modifier(EdgeSwipeBackModifier()) }
}

private struct ChatPendingBubble: View {
    let pending: PendingChatMessage
    let onRetry: () -> Void

    private var failed: Bool { pending.state == .failed }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 8) {
                    if !pending.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(pending.images.enumerated()), id: \.offset) { _, data in
                                if let image = UIImage(data: data) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 86, height: 86)
                                        .clipShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous))
                                }
                            }
                        }
                    }
                    if !pending.text.isEmpty {
                        Text(pending.text)
                            .flowCueFont(13, relativeTo: .subheadline)
                            .foregroundStyle(failed ? FlowCueTheme.textPrimary : FlowCueTheme.onAccent)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                        .fill(failed ? FlowCueTheme.failure.opacity(0.16) : FlowCueTheme.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                        .strokeBorder(failed ? FlowCueTheme.failure.opacity(0.5) : Color.clear)
                )
            }

            if failed {
                HStack(spacing: 8) {
                    Label("Not delivered", systemImage: "exclamationmark.circle.fill")
                        .flowCueFont(10, relativeTo: .caption2, weight: .medium)
                        .foregroundStyle(FlowCueTheme.failure)
                    Button(action: onRetry) {
                        Label(L10n.text("重试"), systemImage: "arrow.clockwise")
                            .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.failure)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                            .background(
                                Capsule().fill(FlowCueTheme.failure.opacity(0.14))
                            )
                            .overlay(
                                Capsule().strokeBorder(FlowCueTheme.failure.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("重试发送失败的消息"))
                }
            } else {
                Text("SENDING.")
                    .flowCueFont(9.5, relativeTo: .caption2)
                    .tracking(1.2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
        }
    }
}

private struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 46, height: 46)
            Text("Start a conversation")
                .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 16)
            Text("Ask about a session, or send the next idea.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
    }
}

private struct ChatComposer: View {
    @Binding var text: String
    let sending: Bool
    let onSend: ([Data]) -> Void

    @State private var dictation = VoiceDictation()
    @State private var baseText = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [Data] = []

    private var canSend: Bool {
        !sending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

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
                                    .clipShape(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous))
                            }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 17))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach images")

                TextField("Reply...", text: $text, axis: .vertical)
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(1...4)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Reply")

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
                    Image(systemName: dictation.isRecording ? "waveform" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(dictation.isRecording ? FlowCueTheme.accent : FlowCueTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictation.isRecording ? "Stop voice input" : "Start voice input")

                Button {
                    guard canSend else { return }
                    dictation.stop()
                    onSend(images)
                    images = []
                    pickerItems = []
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(FlowCueTheme.accent.opacity(canSend ? 1 : 0.35))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(FlowCueTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FlowCueTheme.hairline)
            )
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
                Text("Listening…")
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .padding(.leading, 8)
            }
            if let error = dictation.error {
                Text(error)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.warning)
                    .lineLimit(2)
                    .padding(.leading, 8)
            }
        }
    }
}

private struct ChatSwitcherSheet: View {
    @Bindable var controller: LANRemoteController
    let target: ChatTarget
    let subagents: [DSHSessionSnapshot]
    let onSelect: (ChatTarget) -> Void
    @Environment(\.dismiss) private var dismiss

    private var codexSessions: [RemoteThreadSnapshot] {
        controller.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var dshSessions: [DSHSessionSnapshot] {
        controller.dshSessions
            .filter { !$0.isSubagent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch target.kind {
                    case .codex:
                        AgentsSectionHeader(title: "CODEX SESSIONS")
                            .padding(.top, 8)
                        ForEach(codexSessions) { thread in
                            Button {
                                onSelect(.codex(thread))
                                dismiss()
                            } label: {
                                ChatSwitcherRow(
                                    title: thread.title,
                                    subtitle: subtitle(for: thread),
                                    selected: target.id == "codex-\(thread.id)"
                                )
                            }
                            .buttonStyle(.plain)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    case .dsh:
                        AgentsSectionHeader(title: "DSH SESSIONS")
                            .padding(.top, 8)
                        ForEach(dshSessions) { session in
                            Button {
                                onSelect(.dsh(session))
                                dismiss()
                            } label: {
                                ChatSwitcherRow(
                                    title: session.title,
                                    subtitle: projectName(session.projectDirectory),
                                    selected: target.id == "dsh-\(session.id)"
                                )
                            }
                            .buttonStyle(.plain)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                        if !subagents.isEmpty {
                            AgentsSectionHeader(title: "SUBAGENTS")
                                .padding(.top, 20)
                            ForEach(subagents) { subagent in
                                Button {
                                    onSelect(.dsh(subagent))
                                    dismiss()
                                } label: {
                                    ChatSwitcherRow(
                                        title: subagent.title,
                                        subtitle: projectName(subagent.projectDirectory),
                                        selected: target.id == "dsh-\(subagent.id)"
                                    )
                                }
                                .buttonStyle(.plain)
                                Rectangle()
                                    .fill(FlowCueTheme.hairline)
                                    .frame(height: 1)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("Switch session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
            }
        }
    }

    private func subtitle(for thread: RemoteThreadSnapshot) -> String {
        if let project = thread.projectDirectory, !project.isEmpty {
            return URL(fileURLWithPath: project).lastPathComponent
        }
        return FlowCueLinkFormat.shortRelative(thread.updatedAt)
    }

    private func projectName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "DSH session" : URL(fileURLWithPath: trimmed).lastPathComponent
    }
}

private struct ChatSwitcherRow: View {
    let title: String
    let subtitle: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "Untitled session" : title)
                    .flowCueFont(13.5, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.accent)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
        // iOS 17+ 的新入口；旧 API 已废弃。
        AVAudioApplication.requestRecordPermission(completionHandler: completion)
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

private struct MessageImageGrid: View {
    let images: [RemoteMessageImage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(images) { image in
                if let data = Data(base64Encoded: image.base64), let uiImage = UIImage(data: data) {
                    // 自带深色底并自己裁剪：外部容器是什么底色都盖得住，
                    // 也避免透明区域被系统垫成白色。
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(FlowCueTheme.canvas)
                        Image(uiImage: uiImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    }
                    .frame(maxWidth: 240, maxHeight: 240)
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
    case numbered(start: Int, items: [String])
    case quote(String)
    case rule
    /// Markdown 表格：表头 + 数据行。手机上横向空间有限，按列等宽铺开。
    case table(header: [String], rows: [[String]])
}

private enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0
        // Markdown allows every ordered item to be written as `1.`. Our
        // renderer renumbers, but items separated by explanation paragraphs
        // become separate blocks; keep one cursor so they still read 1,2,3…
        var numberedCursor = 1

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
                    numberedCursor = 1
                    index += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while index < lines.count {
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    guard value.hasPrefix("|") else { break }
                    let cells = value
                        .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                    }
                    if !isSeparator { rows.append(cells) }
                    index += 1
                }
                if rows.count > 1 {
                    blocks.append(.table(header: rows[0], rows: Array(rows.dropFirst())))
                } else if let only = rows.first {
                    blocks.append(.paragraph(only.joined(separator: " · ")))
                }
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
                let start = numberedCursor
                numberedCursor += items.count
                blocks.append(.numbered(start: start, items: items))
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

    private var blocks: [MarkdownBlock] {
        let plain = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        return MarkdownParser.parse(plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .flowCueFont(13, relativeTo: .subheadline)
                .lineSpacing(3)
                .textSelection(.enabled)
        case .heading(let level, let text):
            InlineMarkdownText(text: text)
                .flowCueFont(level <= 2 ? 15 : 14, relativeTo: .subheadline, weight: .semibold)
                .textSelection(.enabled)
                .padding(.top, 2)
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(FlowCueTheme.accent).frame(width: 5, height: 5)
                        InlineMarkdownText(text: item)
                            .flowCueFont(13, relativeTo: .subheadline)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(start + index).").flowCueFont(13, relativeTo: .subheadline).monospacedDigit().foregroundStyle(.secondary)
                        InlineMarkdownText(text: item)
                            .flowCueFont(13, relativeTo: .subheadline)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
            }
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .flowCueFont(11, relativeTo: .caption2, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Rectangle()
                    .fill(FlowCueTheme.hairline)
                    .frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            InlineMarkdownText(text: cell)
                                .flowCueFont(12, relativeTo: .caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(FlowCueTheme.accent.opacity(0.6)).frame(width: 3)
                InlineMarkdownText(text: text)
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
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

private enum FlowCueProfile {
    static let name = "Jorgut"
    static let handle = "altn.vision"
}

private enum MePreview {
    static let state: String? = {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-me=")
        }) else { return nil }
        return String(argument.dropFirst("--flowcue-me=".count))
        #else
        return nil
        #endif
    }()
}

// MARK: - Me

private struct MeView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    @Binding var tab: FlowCueTab
    let showOnboarding: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID

    @State private var network = FlowCueNetworkMonitor()
    @State private var showingPairing = MePreview.state == "pairing"
    @State private var showingDevice = false
    @State private var showingAppearance = MePreview.state == "appearance"
    @State private var showingLanguage = MePreview.state == "language"
    @State private var showingAbout = MePreview.state == "about"
    @State private var showingFeedback = MePreview.state == "feedback"
    @State private var showingWidgets = MePreview.state == "widgets"
    @State private var showingLiveActivity = MePreview.state == "liveactivity"
    @State private var showingSettings = MePreview.state == "settings"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                meHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !network.isOnline {
                            FlowCueInlineBanner(
                                kind: .warning,
                                title: "Offline — changes stay on this iPhone."
                            )
                            .padding(.top, 10)
                        } else if FlowCueSyncState.hasFailure(syncController) {
                            FlowCueInlineBanner(
                                kind: .failure,
                                title: "Last sync failed",
                                actionTitle: "Retry",
                                action: { Task { await syncController.synchronizeNow() } }
                            )
                            .padding(.top, 10)
                        }

                        profile
                            .padding(.top, 12)
                        stats
                            .padding(.top, 16)
                        settingsRows
                            .padding(.top, 18)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)

                FlowCueTabBar(selection: $tab)
            }
            .background { FlowCueScreenBackground() }
            .toolbar(.hidden, for: .navigationBar)
        .edgeSwipeBack()
            .task { network.start() }
            .onDisappear { network.stop() }
            .sheet(isPresented: $showingPairing) {
                PairMacSheet(controller: remoteController)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingLanguage) {
                LanguageSheet(language: $language)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showingDevice) {
                RemoteDeviceView(controller: remoteController, tab: $tab)
            }
            .navigationDestination(isPresented: $showingAppearance) {
                AppearanceView(showsDone: false)
            }
            .navigationDestination(isPresented: $showingAbout) {
                AboutView(showOnboarding: showOnboarding)
            }
            .navigationDestination(isPresented: $showingFeedback) {
                FeedbackView()
            }
            .navigationDestination(isPresented: $showingWidgets) {
                WidgetGalleryView()
            }
            .navigationDestination(isPresented: $showingLiveActivity) {
                LiveActivityGalleryView()
            }
            .navigationDestination(isPresented: $showingSettings) {
                SettingsView(
                    syncController: syncController,
                    remoteController: remoteController,
                    showOnboarding: showOnboarding
                )
            }
        }
    }

    private var meHeader: some View {
        ZStack {
            Text("Me")
                .flowCueFont(17, relativeTo: .headline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)

            HStack {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .padding(.top, 10)
    }

    private var profile: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(FlowCueTheme.surface)
                Circle().strokeBorder(FlowCueTheme.hairline)
                FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                    .frame(width: 28, height: 28)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(FlowCueProfile.name)
                    .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text(FlowCueProfile.handle)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var stats: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
            ),
            spacing: 8
        ) {
            MeStatCard(value: activeIdeas.count, label: "IDEAS")
            MeStatCard(value: queuedIdeas.count, label: "QUEUED")
            MeStatCard(value: agentCount, label: "AGENTS")
            MeStatCard(value: deviceCount, label: "DEVICES")
        }
    }

    private var settingsRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Sync to iCloud")
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: syncBinding)
                    .labelsHidden()
                    .tint(FlowCueTheme.accent)
                    .disabled(!syncController.isAvailable)
                    .accessibilityLabel("Sync to iCloud")
            }
            .padding(.vertical, 8)
            .frame(minHeight: 48)

            divider

            Button {
                if remoteController.isPaired {
                    showingDevice = true
                } else {
                    showingPairing = true
                }
            } label: {
                MeRowLabel(title: "Devices", value: deviceValue, valueColor: deviceValueColor)
            }
            .buttonStyle(.plain)

            divider

            Button {
                showingAppearance = true
            } label: {
                MeRowLabel(
                    title: "Appearance",
                    value: FlowCueThemeCatalog.spec(for: themeID).name
                )
            }
            .buttonStyle(.plain)

            divider

            Button {
                showingLanguage = true
            } label: {
                MeRowLabel(
                    title: "Language",
                    value: AppLanguage(rawValue: language)?.displayName ?? "English"
                )
            }
            .buttonStyle(.plain)

            divider

            NavigationLink {
                ArchiveView(store: store, remoteController: remoteController)
            } label: {
                MeRowLabel(title: "Archive")
            }
            .buttonStyle(.plain)

            divider

            NavigationLink {
                TrashView(store: store, remoteController: remoteController)
            } label: {
                MeRowLabel(
                    title: "Trash",
                    value: store.trashedCaptures.isEmpty ? nil : "\(store.trashedCaptures.count)"
                )
            }
            .buttonStyle(.plain)

            divider

            NavigationLink {
                AboutView(showOnboarding: showOnboarding)
            } label: {
                MeRowLabel(title: "About", value: versionString)
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(FlowCueTheme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: Values

    private var activeIdeas: [CaptureItem] {
        store.captures.filter { $0.status != .draft && $0.status != .archived }
    }

    private var queuedIdeas: [CaptureItem] {
        store.captures.filter { $0.status == .queued || $0.status == .queueing }
    }

    private var agentCount: Int {
        guard remoteController.isPaired else { return 0 }
        return remoteController.dshBridgeAvailable ? 2 : 1
    }

    private var deviceCount: Int {
        remoteController.selected == nil ? 0 : 1
    }

    private var deviceValue: String {
        guard let selected = remoteController.selected else { return "Not paired" }
        let name = FlowCueLinkFormat.deviceName(selected.name)
        switch remoteController.linkState {
        case .online: return "\(name) · online"
        case .connecting: return "\(name) · connecting"
        case .offline: return "\(name) · offline"
        case .disconnected: return "\(name) · disconnected"
        }
    }

    private var deviceValueColor: Color {
        guard remoteController.isPaired else { return FlowCueTheme.textSecondary }
        switch remoteController.linkState {
        case .online: return FlowCueTheme.textPrimary
        case .connecting: return FlowCueTheme.textSecondary
        case .offline, .disconnected: return FlowCueTheme.warning
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { syncController.isEnabled },
            set: { enabled in
                syncController.setEnabled(enabled)
                if enabled {
                    Task { await syncController.synchronizeNow() }
                }
            }
        )
    }

}

private struct MeStatCard: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text("\(value)")
                .flowCueFont(15, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Text(label)
                .flowCueFont(9.5, relativeTo: .caption2)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline.opacity(0.6))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label.capitalized)")
    }
}

private struct MeRowLabel: View {
    let title: String
    var value: String?
    var valueColor: Color = FlowCueTheme.textSecondary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .flowCueFont(10, relativeTo: .caption2)
                    .foregroundStyle(valueColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 13)
        .background(FlowCueTheme.canvas)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    let showOnboarding: () -> Void

    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue

    @State private var showingAppearance = false
    @State private var showingLanguage = false
    @State private var showingAbout = false
    @State private var showingFeedback = false
    @State private var showingClearCache = false
    @State private var diagnosticsCopied = false
    @State private var syncNowWorking = false
    @State private var dataSize = "—"
    @State private var cacheSize = "—"

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var themeName: String {
        FlowCueThemeCatalog.spec(for: themeID).name
    }

    private var languageName: String {
        AppLanguage(rawValue: language)?.displayName ?? language
    }

    private var iCloudStatus: String {
        FileManager.default.ubiquityIdentityToken == nil ? "Not signed in" : "Signed in"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("ACCOUNT") {
                    syncRow
                    syncStatus
                    divider
                    syncNowRow
                    divider
                    SettingsValueRow(title: "iCloud account", value: iCloudStatus)
                }

                section("MAC") {
                    Button {
                        UIApplication.shared.open(FlowCueMacDownload.settingsURL)
                    } label: {
                        HStack(spacing: 8) {
                            Text(L10n.language == .mandarin ? "Mac 版" : "Mac app")
                                .flowCueFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Spacer(minLength: 8)
                            Text("GitHub Releases")
                                .flowCueFont(10, relativeTo: .caption2)
                                .foregroundStyle(FlowCueTheme.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(L10n.language == .mandarin ? "在 Mac 上安装，配对后可以继续编辑" : "Install on Mac, pair, then keep editing.")
                        .flowCueFont(10, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textTertiary)
                        .padding(.top, 6)
                }

                section("APPEARANCE") {
                    Button {
                        showingAppearance = true
                    } label: {
                        MeRowLabel(title: "Theme", value: themeName)
                    }
                    .buttonStyle(.plain)
                }

                section("LANGUAGE") {
                    Button {
                        showingLanguage = true
                    } label: {
                        MeRowLabel(title: "Language", value: languageName)
                    }
                    .buttonStyle(.plain)
                }

                section("STORAGE") {
                    SettingsValueRow(title: "Local data", value: dataSize)
                    divider
                    Button {
                        showingClearCache = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("Clear cache")
                                .flowCueFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Spacer(minLength: 8)
                            Text(cacheSize)
                                .flowCueFont(10, relativeTo: .caption2)
                                .foregroundStyle(FlowCueTheme.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                section("DEVICE") {
                    SettingsValueRow(title: "Device name", value: UIDevice.current.name)
                }

                section("DIAGNOSTICS") {
                    Button {
                        copyDiagnostics()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Copy diagnostics")
                                .flowCueFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Spacer(minLength: 8)
                            Text("Local only")
                                .flowCueFont(10, relativeTo: .caption2)
                                .foregroundStyle(FlowCueTheme.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text("No account needed. Nothing is uploaded automatically.")
                        .flowCueFont(10, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textTertiary)
                        .padding(.top, 6)
                }

                section("ABOUT") {
                    SettingsValueRow(title: "Version", value: versionString)
                    divider
                    SettingsLinkRow(title: "Privacy Policy", destination: FlowCueProduct.privacyURL)
                    divider
                    SettingsLinkRow(title: "Terms of Use", destination: FlowCueProduct.termsURL)
                    divider
                    Button {
                        showingFeedback = true
                    } label: {
                        MeRowLabel(title: "Send feedback")
                    }
                    .buttonStyle(.plain)
                    divider
                    Button {
                        showingAbout = true
                    } label: {
                        MeRowLabel(title: "About FlowCue")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showingLanguage) {
            LanguageSheet(language: $language)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showingAppearance) {
            AppearanceView(showsDone: false)
        }
        .navigationDestination(isPresented: $showingAbout) {
            AboutView(showOnboarding: showOnboarding)
        }
        .navigationDestination(isPresented: $showingFeedback) {
            FeedbackView()
        }
        .confirmationDialog(
            "Clear cache?",
            isPresented: $showingClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear cache", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached images and temporary files will be removed. Your ideas stay.")
        }
        .alert("Diagnostics copied", isPresented: $diagnosticsCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No chat content was included.")
        }
        .task { refreshStorage() }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .flowCueFont(10, relativeTo: .caption2, weight: .medium)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                content()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(FlowCueTheme.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var syncRow: some View {
        HStack(spacing: 8) {
            Text("Sync to iCloud")
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Spacer(minLength: 8)
            Toggle("", isOn: syncBinding)
                .labelsHidden()
                .tint(FlowCueTheme.accent)
                .disabled(!syncController.isAvailable)
                .accessibilityLabel("Sync to iCloud")
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }

    private var syncStatus: some View {
        Text(L10n.text(syncController.statusMessage))
            .flowCueFont(10.5, relativeTo: .caption2)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .padding(.bottom, 10)
    }

    private var syncNowRow: some View {
        Button {
            syncNow()
        } label: {
            HStack(spacing: 8) {
                Text("Sync now")
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Spacer(minLength: 8)
                if syncNowWorking || syncController.isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(FlowCueTheme.textSecondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                }
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!syncController.isEnabled || syncController.isSyncing)
        .opacity(syncController.isEnabled ? 1 : 0.45)
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { syncController.isEnabled },
            set: { enabled in
                syncController.setEnabled(enabled)
                if enabled {
                    Task { await syncController.synchronizeNow() }
                }
            }
        )
    }

    private func syncNow() {
        guard !syncNowWorking else { return }
        syncNowWorking = true
        Task {
            await syncController.synchronizeNow()
            syncNowWorking = false
        }
    }

    private func refreshStorage() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        dataSize = support.map { byteString(directorySize($0)) } ?? "—"
        cacheSize = caches.map { byteString(directorySize($0)) } ?? "—"
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        let fm = FileManager.default
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let contents = (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                try? fm.removeItem(at: url)
            }
        }
        refreshStorage()
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func copyDiagnostics() {
        let diagnostics = """
        App: FlowCue \(versionString)
        Device: \(UIDevice.current.name) · \(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)
        Theme: \(themeName)
        Language: \(languageName)
        Mac: \(remoteController.isOnline ? "online" : (remoteController.isPaired ? "offline" : "not connected")) · \(remoteController.isRemote ? "remote" : "LAN")
        iCloud sync: \(syncController.isEnabled ? "on" : "off") · \(L10n.text(syncController.statusMessage))
        """
        UIPasteboard.general.string = diagnostics
        diagnosticsCopied = true
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .flowCueFont(10, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }
}

private struct SettingsLinkRow: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 8) {
                Text(title)
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Appearance / language

private struct AppearanceView: View {
    let showsDone: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID
    @AppStorage("FlowCue.textScale") private var textScale = 1.0
    @State private var group: FlowCueThemeGroup?

    private var currentSpec: FlowCueThemeSpec {
        FlowCueThemeCatalog.spec(for: themeID)
    }

    private var activeGroup: FlowCueThemeGroup {
        group ?? currentSpec.group
    }

    private var themes: [FlowCueThemeSpec] {
        FlowCueThemeCatalog.themes(in: activeGroup)
    }

    private var textSizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TEXT SIZE")
                    .flowCueFont(10, relativeTo: .caption2, weight: .medium)
                    .tracking(1.0)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Spacer()
                Button("Reset") { textScale = 1 }
                    .flowCueFont(11, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.accent)
                    .opacity(textScale == 1 ? 0 : 1)
                    .disabled(textScale == 1)
            }
            HStack(spacing: 12) {
                Text("A")
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Slider(value: $textScale, in: 0.9...1.3, step: 0.05)
                    .tint(FlowCueTheme.accent)
                    .accessibilityLabel("Text size")
                    .accessibilityValue("\(Int((textScale * 100).rounded()))%")
                Text("A")
                    .flowCueFont(17, relativeTo: .body)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Text("Applies on top of the system text size.")
                .flowCueFont(11, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textTertiary)
        }
        .padding(.top, 10)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                textSizeSection

                groupPicker
                    .padding(.top, 18)

                Text("\(themes.count) THEMES · ALL FREE")
                    .flowCueFont(10, relativeTo: .caption2, weight: .medium)
                    .tracking(1.0)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .padding(.top, 18)

                VStack(spacing: 14) {
                    ForEach(Array(stride(from: 0, to: themes.count, by: 2)), id: \.self) { index in
                        if index + 1 < themes.count {
                            HStack(alignment: .top, spacing: 12) {
                                themeCard(themes[index])
                                themeCard(themes[index + 1])
                            }
                        } else {
                            themeCard(themes[index])
                        }
                    }
                }
                .padding(.top, 12)

            }
            .padding(.horizontal, 18)
            .padding(.bottom, 26)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FlowCueTheme.accent)
                }
            }
        }
    }

    private var groupPicker: some View {
        HStack(spacing: 3) {
            ForEach(FlowCueThemeGroup.allCases) { value in
                Button {
                    group = value
                } label: {
                    Text(value.title)
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(activeGroup == value ? FlowCueTheme.onAccent : FlowCueTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(activeGroup == value ? FlowCueTheme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
    }

    private func themeCard(_ spec: FlowCueThemeSpec) -> some View {
        let selected = spec.id == themeID
        return Button {
            select(spec)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                themePreview(spec)

                HStack(spacing: 5) {
                    Text(spec.name)
                        .flowCueFont(11, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Text("FREE")
                        .font(.system(size: 9.5, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FlowCueTheme.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func themePreview(_ spec: FlowCueThemeSpec) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: spec.background))

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                    .fill(Color(hex: spec.foreground).opacity(0.85))
                    .frame(width: 34, height: 5)
                RoundedRectangle(cornerRadius: min(8, spec.radius), style: .continuous)
                    .fill(Color(hex: spec.card))
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: min(8, spec.radius), style: .continuous)
                    .fill(Color(hex: spec.card))
                    .frame(height: 22)
            }
            .padding(9)

            Circle()
                .fill(Color(hex: spec.accent))
                .frame(width: 12, height: 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(9)
        }
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06))
        )
    }

    private func select(_ spec: FlowCueThemeSpec) {
        themeID = spec.id
    }
}

private struct LanguageSheet: View {
    @Binding var language: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { option in
                        Button {
                            language = option.rawValue
                            dismiss()
                        } label: {
                            HStack {
                                Text(option.displayName)
                                    .flowCueFont(14, relativeTo: .subheadline)
                                    .foregroundStyle(FlowCueTheme.textPrimary)
                                Spacer()
                                if language == option.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(FlowCueTheme.accent)
                                }
                            }
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if option != AppLanguage.allCases.last {
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("Language")
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

private struct ProStatusSheet: View {
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(FlowCueTheme.mint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FlowCue Pro")
                                .flowCueFont(20, relativeTo: .title3, weight: .semibold)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Text("Active")
                                .flowCueFont(11, relativeTo: .caption2)
                                .foregroundStyle(FlowCueTheme.mint)
                        }
                        Spacer()
                    }
                    Text("iCloud sync and remote continuation are active.")
                        .flowCueFont(12.5, relativeTo: .caption)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .padding(.top, 12)

                    VStack(spacing: 0) {
                        Button {
                            UIApplication.shared.open(FlowCueProduct.manageSubscriptionsURL)
                        } label: {
                            HStack {
                                Text("Manage subscription")
                                    .flowCueFont(13, relativeTo: .subheadline)
                                    .foregroundStyle(FlowCueTheme.textPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(FlowCueTheme.textSecondary)
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                        Button {
                            Task { await subscription.restore() }
                        } label: {
                            HStack {
                                Text("Restore purchases")
                                    .flowCueFont(13, relativeTo: .subheadline)
                                    .foregroundStyle(FlowCueTheme.textPrimary)
                                Spacer()
                            }
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 18)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("Subscription")
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

// MARK: - Archive

/// 垃圾箱：删除的想法先放这里，可以恢复，也可以彻底清掉。
private struct TrashView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var remoteController: LANRemoteController
    @State private var showingEmptyConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.trashedCaptures.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 26))
                            .foregroundStyle(FlowCueTheme.textSecondary)
                        Text("Trash is empty")
                            .flowCueFont(14, relativeTo: .subheadline)
                            .foregroundStyle(FlowCueTheme.textPrimary)
                        Text("Deleted ideas stay here so you can restore them.")
                            .flowCueFont(11, relativeTo: .caption)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                    .padding(.horizontal, 32)
                } else {
                    Text("\(store.trashedCaptures.count) IN TRASH")
                        .flowCueFont(10, relativeTo: .caption2)
                        .tracking(1.0)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)

                    VStack(spacing: 0) {
                        ForEach(store.trashedCaptures) { capture in
                            row(capture)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)

                    Text("Ideas deleted here are kept on this iPhone until you empty the trash.")
                        .flowCueFont(10, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                }
            }
            .padding(.bottom, 32)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !store.trashedCaptures.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Empty", role: .destructive) { showingEmptyConfirmation = true }
                }
            }
        }
        .confirmationDialog("清空垃圾箱？", isPresented: $showingEmptyConfirmation, titleVisibility: .visible) {
            Button("全部彻底删除", role: .destructive) {
                for capture in store.trashedCaptures {
                    store.deletePermanently(capture.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清空后这些想法无法再恢复。")
        }
    }

    private func row(_ capture: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(capture.text)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Button {
                    Task {
                        if store.restore(capture.id),
                           let restored = store.captures.first(where: { $0.id == capture.id }) {
                            await remoteController.pushIdea(restored)
                        }
                    }
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                        .flowCueFont(11, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.accent)
                }
                .buttonStyle(.plain)

                Button {
                    store.deletePermanently(capture.id)
                } label: {
                    Label("彻底删除", systemImage: "trash.slash")
                        .flowCueFont(11, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.failure)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct ArchiveView: View {
    @Bindable var store: IdeaDockStore
    @Bindable var remoteController: LANRemoteController
    @State private var showingSearch = false

    private var archived: [CaptureItem] {
        #if DEBUG
        if HomePreview.usesSamples { return HomePreview.archivedSamples }
        #endif
        return store.captures.filter { $0.status == .archived }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if archived.isEmpty {
                    emptyState
                } else {
                    searchEntry
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                    Text("\(archived.count) ARCHIVED")
                        .flowCueFont(10, relativeTo: .caption2)
                        .tracking(1.0)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)

                    VStack(spacing: 0) {
                        ForEach(archived) { capture in
                            archiveRow(capture)
                            Rectangle()
                                .fill(FlowCueTheme.hairline)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                }
            }
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationDestination(isPresented: $showingSearch) {
            SearchView(store: store, remoteController: remoteController, startVoice: false, scope: .archived)
        }
    }

    private var searchEntry: some View {
        Button {
            showingSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Text("Search archive")
                    .flowCueFont(12.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                .fill(FlowCueTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
        )
        .accessibilityLabel("Search archive")
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 60, height: 60)
            Text("No archived ideas")
                .flowCueFont(18, relativeTo: .title3, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 18)
            Text("Archived ideas stay here until you restore them.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, 18)
    }

    private func archiveRow(_ capture: CaptureItem) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(FlowCueTheme.textTertiary)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(capture.text)
                    .flowCueFont(14, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(2)
                Text("ARCHIVED · \(HomeFormat.meta(for: capture.updatedAt))")
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .tracking(0.2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Button("Restore") {
                store.undoArchive(capture.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            .flowCueFont(12, relativeTo: .caption, weight: .semibold)
            .foregroundStyle(FlowCueTheme.accent)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - About

private struct AboutView: View {
    let showOnboarding: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                        .fill(FlowCueTheme.surface)
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                        .strokeBorder(FlowCueTheme.hairline)
                    FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                        .frame(width: 40, height: 40)
                }
                .frame(width: 56, height: 56)

                Text("FlowCue")
                    .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .padding(.top, 16)
                Text("Version \(versionString)")
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .padding(.top, 4)
                Text("A quiet place for the ideas that deserve a next step. Capture now, continue with your agents later.")
                    .flowCueFont(12.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineSpacing(3)
                    .padding(.top, 14)

                VStack(spacing: 0) {
                    aboutLink("Privacy Policy", destination: FlowCueProduct.privacyURL)
                    Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                    aboutLink("Terms of Use", destination: FlowCueProduct.termsURL)
                    Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        HStack {
                            Text("Send feedback")
                                .flowCueFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                    Button {
                        dismiss()
                        showOnboarding()
                    } label: {
                        HStack {
                            Text("Replay welcome")
                                .flowCueFont(13, relativeTo: .subheadline)
                                .foregroundStyle(FlowCueTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 20)

                Text("Independent app, not affiliated with any agent provider. FlowCue never reads your coding-agent conversations for sync.")
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textTertiary)
                    .lineSpacing(3)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func aboutLink(_ title: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case problem = "Problem"
    case idea = "Idea"
    case other = "Other"

    var id: String { rawValue }
}

private struct FeedbackView: View {
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID

    @State private var kind: FeedbackKind = .problem
    @State private var message = ""
    @State private var includeDiagnostics = true
    @FocusState private var focused: Bool

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var diagnostics: String {
        """
        — Diagnostics —
        App: FlowCue \(appVersion)
        Device: \(UIDevice.current.model)
        iOS: \(UIDevice.current.systemVersion)
        Appearance: \(FlowCueThemeCatalog.spec(for: themeID).name)
        Language: \(AppLanguage(rawValue: language)?.displayName ?? language)
        """
    }

    private var feedbackText: String {
        var text = "\(kind.rawValue)\n\n\(trimmedMessage)"
        if includeDiagnostics {
            text += "\n\n\(diagnostics)"
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tell us what's not right")
                    .flowCueFont(22, relativeTo: .title2, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                Text("No account needed. We read every note. Please don't include chat content.")
                    .flowCueFont(11.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineSpacing(2)
                    .padding(.top, 4)

                typeChips
                    .padding(.top, 18)

                editor
                    .padding(.top, 14)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attach diagnostics")
                            .flowCueFont(13, relativeTo: .subheadline)
                            .foregroundStyle(FlowCueTheme.textPrimary)
                        Text("App version, device, iOS, language. No chat content.")
                            .flowCueFont(10.5, relativeTo: .caption2)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $includeDiagnostics)
                        .labelsHidden()
                        .tint(FlowCueTheme.accent)
                        .accessibilityLabel("Attach diagnostics")
                }
                .padding(.top, 18)

                Text("Screenshots can be attached in the share sheet.")
                    .flowCueFont(10, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textTertiary)
                    .padding(.top, 18)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { FlowCueScreenBackground() }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                ShareLink(item: feedbackText) {
                    Text("Send feedback")
                        .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
                }
                .disabled(trimmedMessage.isEmpty)
                .opacity(trimmedMessage.isEmpty ? 0.45 : 1)

                Text("No account needed. No chat content.")
                    .flowCueFont(9.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(FlowCueTheme.canvas)
        }
    }

    private var typeChips: some View {
        HStack(spacing: 8) {
            ForEach(FeedbackKind.allCases) { option in
                Button {
                    kind = option
                } label: {
                    Text(option.rawValue)
                        .flowCueFont(12.5, relativeTo: .caption, weight: kind == option ? .semibold : .regular)
                        .foregroundStyle(kind == option ? FlowCueTheme.onAccent : FlowCueTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                                .fill(kind == option ? FlowCueTheme.accent : FlowCueTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                                .strokeBorder(kind == option ? Color.clear : FlowCueTheme.hairline)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == option ? .isSelected : [])
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if message.isEmpty {
                Text("What happened?")
                    .flowCueFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $message)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(minHeight: 180)
        }
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(focused ? FlowCueTheme.accent.opacity(0.6) : FlowCueTheme.hairline)
        )
    }
}


// MARK: - Widget gallery (DEBUG preview)

private struct WidgetGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                widgetCard("SMALL · 2×2", family: .systemSmall, width: 158, height: 158)
                widgetCard("MEDIUM · 4×2", family: .systemMedium, width: 338, height: 158)
                widgetCard("LARGE · 4×4", family: .systemLarge, width: 338, height: 354)
            }
            .padding(18)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func widgetCard(
        _ title: String,
        family: WidgetFamily,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)

            FlowCueWidgetView(snapshot: .sample, family: family)
                .frame(width: width, height: height)
                .background(FlowCueWidgetBackground())
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(FlowCueTheme.hairline)
                )
        }
    }
}

// MARK: - Live Activity gallery (DEBUG preview)

private struct LiveActivityGalleryView: View {
    private let attributes: FlowCueActivityAttributes = {
        FlowCueActivityAttributes(
            sessionID: "preview",
            agent: "Codex",
            startedAt: .now.addingTimeInterval(-122)
        )
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card("RUNNING", state: state(
                    .running,
                    detail: "Editing CharacterView.swift",
                    elapsed: "2m"
                ))
                card("COMPLETED", state: state(
                    .completed,
                    detail: "Changed 2 files · 3m 12s",
                    elapsed: "3m 12s"
                ))
                card("FAILED", state: state(
                    .failed,
                    detail: "Permission denied — write confirmation needed",
                    elapsed: "1m 40s"
                ))
            }
            .padding(18)
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func state(
        _ status: FlowCueActivityStatus,
        detail: String,
        elapsed: String
    ) -> FlowCueActivityAttributes.ContentState {
        FlowCueActivityAttributes.ContentState(
            title: "Character should blink once on save",
            detail: detail,
            status: status,
            elapsed: elapsed,
            updatedAt: .now
        )
    }

    private func card(_ title: String, state: FlowCueActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .flowCueFont(10, relativeTo: .caption2)
                .tracking(1.0)
                .foregroundStyle(FlowCueTheme.textSecondary)
            FlowCueLiveActivityLockScreenView(attributes: attributes, state: state)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(FlowCueTheme.hairline)
                )
        }
    }
}

// MARK: - Paywall and onboarding

private struct PaywallView: View {
    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?
    @State private var purchasing = false
    @State private var showingAppearance = false

    private var monthly: Product? {
        subscription.products.first { $0.id == FlowCueProduct.monthly }
    }

    private var yearly: Product? {
        subscription.products.first { $0.id == FlowCueProduct.yearly }
    }

    private var selectedProduct: Product? {
        if let selectedID, let product = subscription.products.first(where: { $0.id == selectedID }) {
            return product
        }
        return monthly ?? yearly ?? subscription.products.first
    }

    private var isSelectedMonthly: Bool {
        selectedProduct?.id == monthly?.id
    }

    private var ctaTitle: String {
        if purchasing { return "Purchasing…" }
        if let product = selectedProduct, let trial = subscription.trialDescription(for: product) {
            return "Start \(trial)"
        }
        return "Continue with FlowCue Pro"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            paywallBackground
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                ScrollView {
                    if subscription.isPro {
                        proContent
                    } else {
                        purchaseContent
                    }
                }
                .scrollIndicators(.hidden)

                if !subscription.isPro {
                    footer
                }
            }
        }
        .sheet(isPresented: $showingAppearance) {
            NavigationStack {
                AppearanceView(showsDone: true)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task {
            if subscription.products.isEmpty { await subscription.refresh() }
        }
    }

    private var paywallBackground: some View {
        ZStack {
            FlowCueTheme.canvas
            RadialGradient(
                colors: [FlowCueTheme.accent.opacity(colorScheme == .dark ? 0.30 : 0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.08),
                startRadius: 0,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(FlowCueTheme.surface))
                .overlay(Circle().strokeBorder(FlowCueTheme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    private var purchaseContent: some View {
        VStack(spacing: 0) {
            FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                .frame(width: 64, height: 64)
                .padding(.top, 16)

            Text("FlowCue Pro")
                .flowCueFont(30, relativeTo: .largeTitle, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 16)

            Text("Everything unlocked, on every device.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                PaywallBenefitRow(icon: "play.rectangle.fill", text: "Remote sessions from your Mac")
                PaywallBenefitRow(icon: "icloud.fill", text: "Sync across iPhone and Mac")
                PaywallBenefitRow(icon: "checkmark.shield.fill", text: "Approve DSH commands from your phone")
            }
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.top, 30)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private var proContent: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(FlowCueTheme.mint.opacity(0.14)).frame(width: 56, height: 56)
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.mint)
            }
            .padding(.top, 80)

            Text("You're Pro")
                .flowCueFont(24, relativeTo: .title2, weight: .semibold)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .padding(.top, 16)

            Text("Remote sessions and iCloud sync are active.")
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Button {
                showingAppearance = true
            } label: {
                Text("Pick a theme")
                    .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .frame(maxWidth: 300)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if subscription.isLoading {
                ProgressView()
                    .tint(FlowCueTheme.accent)
                    .frame(height: 50)
            } else if subscription.products.isEmpty {
                VStack(spacing: 6) {
                    Text("Subscriptions are unavailable right now.")
                        .flowCueFont(12, relativeTo: .caption)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                    Button("Try again") {
                        Task { await subscription.refresh() }
                    }
                    .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.accent)
                }
                .frame(maxWidth: .infinity)
            } else {
                priceSelector
                purchaseButton
            }

            if let error = subscription.lastError {
                Text(error)
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.failure)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Text("Auto-renews. Cancel anytime in App Store settings.")
                .flowCueFont(9.5, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textTertiary)

            HStack(spacing: 18) {
                Button("Restore") { Task { await subscription.restore() } }
                Link("Terms", destination: FlowCueProduct.termsURL)
                Link("Privacy", destination: FlowCueProduct.privacyURL)
            }
            .flowCueFont(10.5, relativeTo: .caption2)
            .foregroundStyle(FlowCueTheme.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var priceSelector: some View {
        HStack(spacing: 6) {
            if let monthly {
                priceButton(monthly, suffix: "/ month")
            }
            if monthly != nil, yearly != nil {
                Text("·")
                    .flowCueFont(10.5, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textTertiary)
            }
            if let yearly {
                priceButton(yearly, suffix: "/ year", leadingWord: monthly == nil ? nil : "or")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func priceButton(_ product: Product, suffix: String, leadingWord: String? = nil) -> some View {
        let selected = selectedProduct?.id == product.id
        return Button {
            selectedID = product.id
        } label: {
            Text("\(leadingWord.map { "\($0) " } ?? "")\(product.displayPrice) \(suffix)")
                .flowCueFont(10.5, relativeTo: .caption2, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? FlowCueTheme.textPrimary : FlowCueTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var purchaseButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            purchasing = true
            Task {
                await subscription.purchase(product)
                purchasing = false
            }
        } label: {
            HStack(spacing: 8) {
                if purchasing {
                    ProgressView()
                        .tint(FlowCueTheme.onAccent)
                }
                Text(ctaTitle)
                    .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
            }
            .foregroundStyle(FlowCueTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
        }
        .buttonStyle(.plain)
        .disabled(purchasing || selectedProduct == nil)
    }
}

private struct PaywallBenefitRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowCueTheme.accent)
                .frame(width: 28, height: 28)
                .background(Circle().fill(FlowCueTheme.accentSoft))
            Text(text)
                .flowCueFont(12.5, relativeTo: .caption)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
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

/// 仅 DEBUG：--flowcue-onboarding 或 --flowcue-onboarding-page=N（1-based）直接预览。
private enum OnboardingPreview {
    static let isActive: Bool = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--flowcue-onboarding")
            || arguments.contains { $0.hasPrefix("--flowcue-onboarding-page=") }
        #else
        return false
        #endif
    }()

    static let initialPage: Int = {
        #if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--flowcue-onboarding-page=")
        }), let raw = Int(argument.dropFirst("--flowcue-onboarding-page=".count)), raw >= 1 else {
            return 0
        }
        return min(raw - 1, 2)
        #else
        return 0
        #endif
    }()
}

private enum OnboardingVisualKind {
    case capture
    case sync
    case privacy
}

private struct OnboardingPage {
    let title: String
    let body: String
    let visual: OnboardingVisualKind

    static let all: [OnboardingPage] = [
        OnboardingPage(
            title: "Catch the thought.",
            body: "A quiet inbox for ideas, snippets, and next steps. Save now; decide later.",
            visual: .capture
        ),
        OnboardingPage(
            title: "Continue on iPhone.",
            body: "With Pro, pair with your Mac on the same Wi-Fi. Read the last reply and send the next message.",
            visual: .sync
        ),
        OnboardingPage(
            title: "Private by default.",
            body: "Your ideas stay yours — local first, private iCloud sync with Pro. No public feed, no ads, no tracking.",
            visual: .privacy
        )
    ]
}

private struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = OnboardingPreview.initialPage

    private let pages = OnboardingPage.all

    var body: some View {
        VStack(spacing: 0) {
            topBar

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    OnboardingPageView(page: item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            bottomBar
        }
        .background { FlowCueScreenBackground() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(FlowCueTheme.surface)
                Circle().strokeBorder(FlowCueTheme.hairline)
                FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 28, height: 28)

            Text("FlowCue")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .tracking(-0.14)
                .foregroundStyle(FlowCueTheme.textPrimary)

            Spacer()

            Button("Skip") {
                onFinish()
            }
            .flowCueFont(12.5, relativeTo: .caption)
            .foregroundStyle(FlowCueTheme.textSecondary)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .fill(index == page ? FlowCueTheme.accent : FlowCueTheme.textTertiary.opacity(0.4))
                        .frame(width: index == page ? 20 : 6, height: 6)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")

            Button {
                advance()
            } label: {
                Text(page == pages.count - 1 ? "Get started" : "Continue")
                    .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
            }
            .buttonStyle(.plain)

            Text("No account needed. Private by design.")
                .flowCueFont(9.5, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func advance() {
        if page == pages.count - 1 {
            onFinish()
        } else if reduceMotion {
            page += 1
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                page += 1
            }
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingVisual(kind: page.visual)

                Text(page.title)
                    .flowCueFont(28, relativeTo: .largeTitle, weight: .semibold)
                    .tracking(-0.3)
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 26)

                Text(page.body)
                    .flowCueFont(12.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

private struct OnboardingVisual: View {
    let kind: OnboardingVisualKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.surface)
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)

            switch kind {
            case .capture:
                OnboardingCapturePreview()
            case .sync:
                OnboardingSyncPreview()
            case .privacy:
                OnboardingPrivacyPreview()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .accessibilityHidden(true)
    }
}

private struct OnboardingCapturePreview: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(FlowCueTheme.canvas)
                    Circle().strokeBorder(FlowCueTheme.hairline)
                    FlowCueFaceMark(ink: FlowCueTheme.textPrimary, smile: FlowCueTheme.accent)
                        .frame(width: 14, height: 14)
                }
                .frame(width: 24, height: 24)

                Text("FlowCue")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.textPrimary)

                Spacer()

                Text("3 LOCAL")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Text("Capture an idea")
                    .font(.system(size: 9.5))
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Spacer()
                Image(systemName: "mic")
                    .font(.system(size: 10))
                    .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                ZStack {
                    Circle().fill(FlowCueTheme.accent)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowCueTheme.onAccent)
                }
                .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.canvas))
            .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))

            VStack(spacing: 0) {
                OnboardingMiniIdeaRow(
                    text: "Retry backoff feels too slow",
                    meta: "DRAFT · 21:04",
                    tint: FlowCueTheme.textSecondary
                )
                Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                OnboardingMiniIdeaRow(
                    text: "Character should blink once on save",
                    meta: "QUEUED · 20:51",
                    tint: FlowCueTheme.accent
                )
                Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                OnboardingMiniIdeaRow(
                    text: "Share sheet for Safari",
                    meta: "QUEUED · 18:22",
                    tint: FlowCueTheme.mint
                )
            }
        }
        .padding(14)
    }
}

private struct OnboardingSyncPreview: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                OnboardingDeviceTile(icon: "laptopcomputer", title: "Mac", subtitle: "Online")
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.accent)
                OnboardingDeviceTile(icon: "iphone", title: "iPhone", subtitle: "Same Wi-Fi")
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text("Direct on your network · no relay")
                    .font(.system(size: 8.5))
            }
            .foregroundStyle(FlowCueTheme.textSecondary)

            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 9))
                    .foregroundStyle(FlowCueTheme.accent)
                Text("Read the last reply. Send the next message.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
        }
        .padding(14)
    }
}

private struct OnboardingPrivacyPreview: View {
    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(FlowCueTheme.accentSoft).frame(width: 58, height: 58)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.accent)
            }

            Text("Private iCloud")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textPrimary)

            Text("Your own account. Your own ideas.")
                .font(.system(size: 9))
                .foregroundStyle(FlowCueTheme.textSecondary)

            HStack(spacing: 6) {
                OnboardingPrivacyChip(text: "No feed")
                OnboardingPrivacyChip(text: "No ads")
                OnboardingPrivacyChip(text: "No tracking")
            }
            .padding(.top, 2)
        }
        .padding(14)
    }
}

private struct OnboardingDeviceTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                    .fill(FlowCueTheme.canvas)
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusInline, style: .continuous)
                    .strokeBorder(FlowCueTheme.hairline)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(FlowCueTheme.textPrimary)
            }
            .frame(width: 54, height: 54)

            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textPrimary)

            HStack(spacing: 4) {
                Circle()
                    .fill(FlowCueTheme.mint)
                    .frame(width: 4, height: 4)
                Text(subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .fill(FlowCueTheme.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowCueTheme.radiusCard, style: .continuous)
                .strokeBorder(FlowCueTheme.hairline)
        )
    }
}

private struct OnboardingMiniIdeaRow: View {
    let text: String
    let meta: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 4, height: 4)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 9.5))
                    .foregroundStyle(FlowCueTheme.textPrimary)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 7.5))
                    .tracking(0.4)
                    .foregroundStyle(FlowCueTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

private struct OnboardingPrivacyChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(FlowCueTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.canvas))
            .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
    }
}

// MARK: - 远程推送

/// APNs 注册。推送由 Mac 直接用 .p8 发往 api.push.apple.com，不需要服务端；
/// 手机这边只负责拿到 device token 并交给 Mac。
final class FlowCueAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 不挂 delegate 的话，App 在前台收到的推送会被系统静默丢弃。
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        FlowCuePushRegistration.shared.handleToken(deviceToken)
        FlowCuePushRegistration.shared.needsUpload = true
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        FlowCuePushRegistration.shared.handleFailure(error)
    }

    // 前台也显示横幅。非 async + nonisolated，避开 Swift 6 的并发检查。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

@MainActor
final class FlowCuePushRegistration {
    static let shared = FlowCuePushRegistration()

    private let tokenKey = "FlowCue.pushToken"
    private let askedKey = "FlowCue.pushAsked"
    private let errorKey = "FlowCue.pushError"

    var token: String? { UserDefaults.standard.string(forKey: tokenKey) }

    /// token 变了或 App 刚启动时要重新上报给 Mac。
    /// 之前只在「配对连接」那一刻上传一次，装新包换了 token 后 Mac 永远拿不到。
    private let needsUploadKey = "FlowCue.pushNeedsUpload"
    var needsUpload: Bool {
        get { UserDefaults.standard.bool(forKey: needsUploadKey) }
        set { UserDefaults.standard.set(newValue, forKey: needsUploadKey) }
    }
    var lastError: String? { UserDefaults.standard.string(forKey: errorKey) }

    /// 每次启动都走一遍：
    /// - 没问过才问授权
    /// - 只要已授权就重新注册 token（重装/恢复/系统重置后 token 会变，
    ///   旧逻辑只在第一次启动注册，之后永远不刷新）
    /// - 顺便把系统返回的通知设置记下来，用来诊断「为什么没声音」
    func requestIfNeeded() {
        #if DEBUG
        // 界面预览时可跳过授权弹窗，免得挡住要看的页面。
        if ProcessInfo.processInfo.arguments.contains("--flowcue-questions-preview") { return }
        #endif
        needsUpload = true
        Task {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined,
               !UserDefaults.standard.bool(forKey: askedKey) {
                UserDefaults.standard.set(true, forKey: askedKey)
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                settings = await center.notificationSettings()
            }
            record(settings)
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// 系统里这些开关决定推送有没有横幅和声音，出问题时先看它们。
    private func record(_ settings: UNNotificationSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.soundSetting == .enabled, forKey: "FlowCue.pushSoundEnabled")
        defaults.set(settings.alertSetting == .enabled, forKey: "FlowCue.pushAlertEnabled")
        defaults.set(settings.lockScreenSetting == .enabled, forKey: "FlowCue.pushLockScreenEnabled")
        defaults.set(settings.notificationCenterSetting == .enabled, forKey: "FlowCue.pushCenterEnabled")
        defaults.set(settings.authorizationStatus.rawValue, forKey: "FlowCue.pushAuthStatus")
    }

    /// 上报给 Mac 的诊断字段，和 token 一起发。
    var diagnostics: [String: Any] {
        let defaults = UserDefaults.standard
        return [
            "sound": defaults.bool(forKey: "FlowCue.pushSoundEnabled"),
            "alert": defaults.bool(forKey: "FlowCue.pushAlertEnabled"),
            "lockScreen": defaults.bool(forKey: "FlowCue.pushLockScreenEnabled"),
            "authorization": defaults.integer(forKey: "FlowCue.pushAuthStatus"),
        ]
    }

    func handleToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        UserDefaults.standard.set(hex, forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: errorKey)
    }

    func handleFailure(_ error: Error) {
        // 模拟器或未开推送能力时会到这里；不当作致命错误。
        UserDefaults.standard.set(error.localizedDescription, forKey: errorKey)
    }
}

// MARK: - 通用 Agent 会话列表（按项目分组、可折叠、可切换 Agent）

private struct AgentSessionsView: View {
    @Bindable var controller: LANRemoteController
    @Binding var tab: FlowCueTab
    let agent: RemoteAgentInfo

    @State private var sessions: [RemoteAgentSession] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var collapsed: Set<String> = []
    @State private var switchedAgent: RemoteAgentInfo?
    @State private var resume: RemoteAgentSession?
    /// 自定义项目图标：project 名 → emoji，只存本机。
    @State private var projectIcons: [String: String] = [:]
    @State private var iconTarget: String?

    private var collapsedKey: String { "FlowCue.agentCollapsed.\(agent.id)" }
    private var lastKey: String { "FlowCue.agentLast.\(agent.id)" }

    private var groups: [(project: String, sessions: [RemoteAgentSession])] {
        Dictionary(grouping: sessions) { session in
            guard let path = session.projectPath, !path.isEmpty else { return "未关联项目" }
            return (path as NSString).lastPathComponent
        }
        .map { (project: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
        .sorted { lhs, rhs in
            // 未关联项目固定排最后
            if lhs.project == "未关联项目" { return false }
            if rhs.project == "未关联项目" { return true }
            return (lhs.sessions.first?.updatedAt ?? .distantPast) > (rhs.sessions.first?.updatedAt ?? .distantPast)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if loading {
                    SessionsSkeleton()
                } else if let loadError, sessions.isEmpty {
                    SessionsLoadError(detail: loadError) {
                        Task { await reload() }
                    }
                    .padding(.top, 8)
                } else if sessions.isEmpty {
                    SessionsEmptyState(agent: agent.displayName)
                } else {
                    if let loadError {
                        FlowCueInlineBanner(
                            kind: .failure,
                            title: "Couldn't refresh sessions — \(loadError)",
                            actionTitle: "Retry",
                            action: { Task { await reload() } }
                        )
                        .padding(.horizontal, AgentsLayout.margin)
                        .padding(.top, 10)
                    }
                    if let resume {
                        NavigationLink {
                            sessionDestination(resume)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FlowCueTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("继续上次：\(resume.title.isEmpty ? "未命名会话" : resume.title)")
                                        .flowCueFont(12.5, relativeTo: .caption, weight: .semibold)
                                        .foregroundStyle(FlowCueTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(FlowCueLinkFormat.relative(resume.updatedAt))
                                        .flowCueFont(10.5, relativeTo: .caption2)
                                        .foregroundStyle(FlowCueTheme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Text("进入")
                                    .flowCueFont(11, relativeTo: .caption2, weight: .semibold)
                                    .foregroundStyle(FlowCueTheme.accent)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                                    .fill(FlowCueTheme.accent.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                                    .strokeBorder(FlowCueTheme.accent.opacity(0.35))
                            )
                            .padding(.horizontal, AgentsLayout.margin)
                            .padding(.top, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(groups, id: \.project) { group in
                        projectHeader(group.project, count: group.sessions.count)
                        if !collapsed.contains(group.project) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    sessionDestination(session)
                                } label: {
                                    sessionRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background { FlowCueScreenBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FlowCueTheme.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(controller.agentInfos) { other in
                        Button {
                            guard other.id != agent.id else { return }
                            switchedAgent = other
                        } label: {
                            if other.id == agent.id {
                                Label(other.displayName, systemImage: "checkmark")
                            } else {
                                Text(other.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(agent.displayName)
                            .flowCueFont(16, relativeTo: .headline, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(FlowCueTheme.textSecondary)
                    }
                }
            }
        }
        .navigationDestination(item: $switchedAgent) { next in
            AgentSessionsView(controller: controller, tab: $tab, agent: next)
        }
        .task {
            collapsed = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
            loadProjectIcons()
            await reload()
        }
        .sheet(isPresented: Binding(
            get: { iconTarget != nil },
            set: { if !$0 { iconTarget = nil } }
        )) {
            if let target = iconTarget {
                ProjectIconPicker(
                    project: target,
                    current: icon(for: target),
                    onPick: { emoji in
                        setIcon(emoji, for: target)
                        iconTarget = nil
                    },
                    onReset: {
                        setIcon(nil, for: target)
                        iconTarget = nil
                    }
                )
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// DSH 有审批/提问/活动状态这些富功能，仍在 ChatScreen 里；
    /// 其他 Agent 走通用对话页。
    @ViewBuilder
    private func sessionDestination(_ session: RemoteAgentSession) -> some View {
        if agent.id == "dsh" {
            ChatScreen(
                controller: controller,
                tab: $tab,
                initialTarget: .dsh(DSHSessionSnapshot(
                    id: session.id,
                    title: session.title,
                    projectDirectory: session.projectPath ?? "",
                    updatedAt: session.updatedAt
                ))
            )
        } else {
            AgentChatView(controller: controller, agent: agent, session: session)
        }
    }

    private func projectHeader(_ project: String, count: Int) -> some View {
        HStack(spacing: 9) {
            // 图标本身可点：打开 emoji 选择器。未关联项目固定 💬、不可改。
            Button {
                guard project != "未关联项目" else { return }
                iconTarget = project
            } label: {
                Text(icon(for: project))
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowCueTheme.accent.opacity(0.16))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑项目图标")

            // 名称区域可点：折叠 / 展开。
            Button {
                if collapsed.contains(project) {
                    collapsed.remove(project)
                } else {
                    collapsed.insert(project)
                }
                UserDefaults.standard.set(Array(collapsed), forKey: collapsedKey)
            } label: {
                HStack(spacing: 8) {
                    Text(project.uppercased())
                        .flowCueFont(10, relativeTo: .caption2, weight: .semibold)
                        .tracking(1.0)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .flowCueFont(10, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                    Image(systemName: collapsed.contains(project) ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    private func loadProjectIcons() {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("FlowCue.projectIcon.") {
            guard let emoji = value as? String, !emoji.isEmpty else { continue }
            projectIcons[String(key.dropFirst("FlowCue.projectIcon.".count))] = emoji
        }
    }

    private func icon(for project: String) -> String {
        if project == "未关联项目" { return "💬" }
        return projectIcons[project] ?? "📁"
    }

    private func setIcon(_ emoji: String?, for project: String) {
        let key = "FlowCue.projectIcon.\(project)"
        if let emoji {
            projectIcons[project] = emoji
            UserDefaults.standard.set(emoji, forKey: key)
        } else {
            projectIcons.removeValue(forKey: project)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func hasPendingQuestion(_ session: RemoteAgentSession) -> Bool {
        controller.dshQuestions.contains { $0.sessionId == session.id }
    }

    private func sessionRow(_ session: RemoteAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title.isEmpty ? "未命名会话" : session.title)
                .flowCueFont(14, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(FlowCueLinkFormat.relative(session.updatedAt))
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                if let count = session.messageCount, count > 0 {
                    Text("·")
                        .flowCueFont(11, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                    Text("\(count) 条消息")
                        .flowCueFont(11, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                }
                // 这个会话有等待回答的问题：即使推送没到，列表里也能看到。
                if hasPendingQuestion(session) {
                    Text("待回答")
                        .flowCueFont(10, relativeTo: .caption2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(FlowCueTheme.accent)
                        )
                }
            }
        }
        .padding(.horizontal, AgentsLayout.margin)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    private var sessionsCacheKey: String { "FlowCue.agentSessions.\(agent.id)" }

    private func loadCachedSessions() {
        guard sessions.isEmpty,
              let data = UserDefaults.standard.data(forKey: sessionsCacheKey),
              let cached = try? JSONDecoder().decode([RemoteAgentSession].self, from: data),
              !cached.isEmpty else { return }
        sessions = cached
        loading = false
    }

    private func saveCachedSessions() {
        guard !sessions.isEmpty, let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: sessionsCacheKey)
    }

    private func reload() async {
        // 先显示上次的列表，避免每次进来都看骨架屏。
        loadCachedSessions()
        if sessions.isEmpty { loading = true }
        do {
            sessions = try await controller.agentSessions(agent.id)
            loadError = nil
            saveCachedSessions()
            // 记住上次位置，供切换器显示「上次：xxx」
            if let id = UserDefaults.standard.string(forKey: lastKey),
               let match = sessions.first(where: { $0.id == id }) {
                resume = match
            }
        } catch {
            // 失败必须落到 UI：以前这里返回空数组，页面不是「没有会话」
            // 就是一直转圈，看不出是断线。
            loadError = LANRemoteController.connectionMessage(for: error)
        }
        loading = false
    }
}

/// 通用 Agent 对话页：消息 + 输入框，发送走 /v1/agents/.../send。
private struct AgentChatView: View {
    @Bindable var controller: LANRemoteController
    let agent: RemoteAgentInfo
    let session: RemoteAgentSession

    @State private var messages: [RemoteAgentMessage] = []
    @State private var text = ""
    @State private var sending = false
    @State private var loading = true
    @State private var loadError: String?
    @State private var sendError: String?
    @State private var isAtBottom = true
    @State private var activity: String?
    /// 已发出、但 Mac 的会话文件还没更新的消息；先本地显示，避免「桌面已收到、手机空白」。
    @State private var optimistic: String?
    @State private var optimisticRequestID: String?
    @State private var optimisticFailed = false

    /// 以 `/` 开头且还没敲空格时，展示 skill 候选。
    private var slashQuery: String? {
        guard text.hasPrefix("/"), !text.dropFirst().contains(" ") else { return nil }
        return String(text.dropFirst())
    }
    private var showsSlashMenu: Bool { slashQuery != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                FlowCueInlineBanner(
                    kind: .failure,
                    title: "Couldn't load conversation — \(loadError)",
                    actionTitle: "Retry",
                    action: { Task { await load() } }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if let sendError {
                FlowCueInlineBanner(
                    kind: .failure,
                    title: sendError,
                    actionTitle: L10n.text("好"),
                    action: { self.sendError = nil }
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if !agent.canSend {
                FlowCueInlineBanner(
                    kind: .warning,
                    title: agent.id == "claude"
                        ? L10n.text("Claude Code 未登录。请在 Mac 终端运行 claude auth login。")
                        : L10n.text("这个 Agent 当前不能发送。")
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            activityBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            bubble(message)
                        }
                        if let optimistic {
                            optimisticBubble(optimistic)
                        }
                        Color.clear.frame(height: 1).id("agent-chat-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear { scrollAgentToBottom(proxy) }
                .onChange(of: messages.count) { _, _ in
                    scrollAgentToBottom(proxy)
                }
                .onChange(of: optimistic) { _, _ in
                    scrollAgentToBottom(proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        Button {
                            withAnimation {
                                proxy.scrollTo(messages.last?.id, anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.onAccent)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(FlowCueTheme.accent))
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .accessibilityLabel("回到底部")
                    }
                }
                .modifier(ScrollBottomTracking(isAtBottom: $isAtBottom))
                // 浮层而不是插进 VStack：菜单 + 键盘 + ScrollView 的
                // 高度协商会在 iOS 26 模拟器上进入无限布局循环，主线程
                // 卡死 30s+。浮层不改变聊天区高度，只覆盖最后一点内容。
                .overlay(alignment: .bottom) {
                    if showsSlashMenu {
                        SlashSkillMenu(skills: controller.skills, query: slashQuery ?? "") { name in
                            text = "/" + name + " "
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                        .task(id: showsSlashMenu) {
                            if controller.skills.isEmpty { await controller.refreshSkills() }
                        }
                    }
                }
            }
            composer
        }
        .background { FlowCueScreenBackground() }
        .navigationTitle(session.title.isEmpty ? agent.displayName : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            // 对齐 DSH 的 3 秒轮询：Codex/Claude 的 queue/send 只代表「已投递」，
            // 会话文件写入有延迟；不轮询就会出现「桌面已收到、手机一直看不到」。
            while !Task.isCancelled {
                activity = await controller.agentActivity(agentID: agent.id, sessionID: session.id)
                await refreshMessages(afterCount: messages.count)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private var activityBar: some View {
        if let activity {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text(activity)
                    .flowCueFont(11, relativeTo: .caption2)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(FlowCueTheme.surface.opacity(0.6))
        }
    }

    @ViewBuilder
    private func bubble(_ message: RemoteAgentMessage) -> some View {
        let isUser = message.role == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if isUser {
                    Text(message.text)
                        .flowCueFont(13.5, relativeTo: .subheadline)
                        .foregroundStyle(FlowCueTheme.onAccent)
                        .textSelection(.enabled)
                } else {
                    // Codex / Claude 走通用 AgentChatView；以前这里直接 Text，
                    // 助理回复里的 **bold** 和 `code` 会原样露出来，只有 DSH 的
                    // ChatScreen 才经过 MarkdownMessageView。
                    MarkdownMessageView(text: message.text)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(isUser ? FlowCueTheme.accent : FlowCueTheme.surface)
            )
            .id(message.id)
            if !isUser { Spacer(minLength: 40) }
        }
    }

    /// 乐观气泡/新消息刚插入时布局还没完成，直接 scrollTo 可能落在旧位置。
    private func scrollAgentToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("agent-chat-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func optimisticBubble(_ value: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                Text(value)
                    .flowCueFont(13.5, relativeTo: .subheadline)
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .textSelection(.enabled)
                if optimisticFailed {
                    HStack(spacing: 8) {
                        Label(L10n.text("发送失败"), systemImage: "exclamationmark.circle.fill")
                            .flowCueFont(10, relativeTo: .caption2, weight: .medium)
                            .foregroundStyle(FlowCueTheme.failure)
                        Button(action: retryOptimistic) {
                            Label(L10n.text("重试"), systemImage: "arrow.clockwise")
                                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                                .foregroundStyle(FlowCueTheme.failure)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .contentShape(Capsule())
                                .background(Capsule().fill(FlowCueTheme.failure.opacity(0.14)))
                                .overlay(Capsule().strokeBorder(FlowCueTheme.failure.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-retry")
                        .accessibilityLabel(L10n.text("重试发送失败的消息"))
                    }
                } else {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini).tint(FlowCueTheme.onAccent)
                        Text(L10n.text("已发送，等待同步…"))
                            .foregroundStyle(FlowCueTheme.onAccent.opacity(0.8))
                    }
                    .flowCueFont(10, relativeTo: .caption2)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(FlowCueTheme.accent.opacity(optimisticFailed ? 0.6 : 0.85))
            )
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("发消息…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .disabled(!agent.canSend)
                .flowCueFont(13.5, relativeTo: .footnote)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous)
                        .fill(FlowCueTheme.surface)
                )
            Button {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !sending else { return }
                text = ""
                deliver(value)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowCueTheme.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(FlowCueTheme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("agent-send")
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || !agent.canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(FlowCueTheme.canvas)
    }

    private func load() async {
        loading = true
        await refreshMessages()
        controller.loadCachedSkills()
        await controller.refreshSkills()
        loading = false
        UserDefaults.standard.set(session.id, forKey: "FlowCue.agentLast.\(agent.id)")
    }

    /// 拉一次消息；如果本地待同步消息已经出现在会话里，就撤掉乐观气泡。
    private func refreshMessages(afterCount: Int = 0) async {
        do {
            let fetched = try await controller.agentMessages(
                agentID: agent.id,
                sessionID: session.id,
                after: afterCount
            )
            if afterCount > 0 {
                if !fetched.isEmpty { messages.append(contentsOf: fetched) }
            } else {
                messages = fetched
            }
            loadError = nil
            if let optimistic, Self.containsUserMessage(optimistic, in: messages) {
                self.optimistic = nil
                self.optimisticRequestID = nil
                optimisticFailed = false
            }
        } catch {
            // 已有消息时不要把整页打成错误，只在顶部显示原因。
            if messages.isEmpty {
                loadError = LANRemoteController.connectionMessage(for: error)
            }
        }
    }

    private func retryOptimistic() {
        guard let value = optimistic, let requestID = optimisticRequestID else { return }
        sendError = nil
        deliver(value, requestID: requestID)
    }

    private func deliver(_ value: String, requestID: String? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        let stableID = requestID ?? UUID().uuidString
        optimisticRequestID = stableID
        optimistic = trimmed
        optimisticFailed = false
        sendError = nil
        sending = true
        Task {
            let ok = await controller.sendAgent(
                agentID: agent.id,
                sessionID: session.id,
                text: trimmed,
                requestID: stableID
            )
            sending = false
            if ok {
                loadError = nil
                sendError = nil
                await refreshMessages()
            } else {
                optimisticFailed = true
                if agent.id == "claude" {
                    sendError = L10n.text("Claude Code 发送失败。若测试机未登录，请在 Mac 终端运行 claude auth login。")
                } else {
                    sendError = controller.lastError ?? L10n.text("发送失败。")
                }
            }
        }
    }

    private static func containsUserMessage(_ text: String, in messages: [RemoteAgentMessage]) -> Bool {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return true }
        return messages.contains { message in
            guard message.role == "user" else { return false }
            let body = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return false }
            // 只认「完全相等」或「会话文本包含本次发送文本」。不能反过来用
            // target.contains(body)：会话里已有的 "ok" 会让任何含 ok 的新消息
            // 被误判成已同步，乐观气泡随即消失。
            return body == target || body.contains(target)
        }
    }
}

/// 项目图标选择器：emoji 网格 + 恢复默认。
private struct ProjectIconPicker: View {
    let project: String
    let current: String
    let onPick: (String) -> Void
    let onReset: () -> Void

    private let choices: [String] = [
        "📁", "💻", "🧩", "🎛", "🎨", "📦",
        "🗂", "⚙️", "🌐", "📱", "🧪", "💬",
        "🚀", "🛠", "📝", "🧠", "⛰", "🎧",
        "🏗", "🔧", "📊", "🎬", "🌱", "⭐️"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(project)
                        .flowCueFont(13, relativeTo: .subheadline, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textPrimary)
                    Text("仅影响这台 iPhone 的显示，不会改动 Mac 上的文件。")
                        .flowCueFont(11, relativeTo: .caption2)
                        .foregroundStyle(FlowCueTheme.textSecondary)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(choices, id: \.self) { emoji in
                            Button {
                                onPick(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 20))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(emoji == current
                                                  ? FlowCueTheme.accent.opacity(0.18)
                                                  : FlowCueTheme.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(emoji == current
                                                          ? FlowCueTheme.accent
                                                          : FlowCueTheme.hairline)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("恢复默认 📁") { onReset() }
                        .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.textSecondary)
                        .padding(.top, 4)
                }
                .padding(16)
            }
            .background { FlowCueScreenBackground() }
            .navigationTitle("项目图标")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 本机 skill（Mac 端扫描目录得出）。
struct RemoteSkillInfo: Codable, Identifiable, Hashable {
    let name: String
    let summary: String
    var id: String { name }
}

/// 输入 `/` 时弹出的 skill 列表。点一条就把 `/name ` 填进输入框。
private struct SlashSkillMenu: View {
    let skills: [RemoteSkillInfo]
    let query: String
    let onPick: (String) -> Void

    private var matches: [RemoteSkillInfo] {
        guard !query.isEmpty else { return Array(skills.prefix(30)) }
        let q = query.lowercased()
        return skills.filter {
            $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }.prefix(30).map { $0 }
    }

    var body: some View {
        if matches.isEmpty {
            // 空的时候也要有反馈：否则用户以为斜杠没反应。
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(skills.isEmpty ? "正在读取 skill 列表…" : "没有匹配的 skill")
                    .flowCueFont(11.5, relativeTo: .caption)
                    .foregroundStyle(FlowCueTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(FlowCueTheme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
            }
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { skill in
                        Button {
                            onPick(skill.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/" + skill.name)
                                    .flowCueFont(12.5, relativeTo: .caption, weight: .semibold)
                                    .foregroundStyle(FlowCueTheme.textPrimary)
                                if !skill.summary.isEmpty {
                                    Text(skill.summary)
                                        .flowCueFont(10, relativeTo: .caption2)
                                        .foregroundStyle(FlowCueTheme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(FlowCueTheme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(FlowCueTheme.hairline).frame(height: 1)
            }
        }
    }
}

/// 跟踪聊天是否已经滚到底部（用于显示/隐藏「回到底部」按钮）。
private struct ScrollBottomTracking: ViewModifier {
    @Binding var isAtBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height
                    - geometry.contentOffset.y
                    - geometry.containerSize.height
                return distance < 40
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
        } else {
            content
        }
    }
}

// MARK: - 远程隧道

/// 中继上的加密通道。配对完成后由它接管所有 `/v1` 请求。
///
/// 它自己维护唯一的状态：只有「WebSocket 已确认（收到帧/心跳回显）」且
/// 「中继报告 Mac 在线」时才算 `.online`。断线、Mac 离线、请求发送失败
/// 都会立刻把状态改为 `.offline` 并让等待中的请求立即失败，而不是让
/// 页面等 20 秒超时。
@MainActor
final class RemoteTunnel {
    private static var instance: RemoteTunnel?

    /// 已安装的隧道（无论在线与否）。请求路径用它，离线时能立刻报错，
    /// 而不是悄悄回退到无效的 LAN 地址。
    static func current() -> RemoteTunnel? { instance }

    static func install(_ tunnel: RemoteTunnel) {
        if let existing = instance, existing !== tunnel {
            existing.disconnect()
        }
        instance = tunnel
    }

    static func teardown() {
        instance?.disconnect()
        instance = nil
    }

    private(set) var state: RemoteLinkState = .disconnected {
        didSet {
            guard state != oldValue else { return }
            log("state → \(state)")
            onStateChange?(state)
        }
    }
    /// 控制器用它把链路状态同步到 UI。回调总在 MainActor 上。
    var onStateChange: (@MainActor (RemoteLinkState) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: RemoteCryptoSession?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private struct ChunkBuffer {
        var parts: [Int: Data]
        var total: Int
        var at: Date
    }
    private var chunkBuffers: [String: ChunkBuffer] = [:]
    private var relayURL: URL?
    private var pairID = ""
    private var pairToken = ""
    private var macID = ""

    /// WebSocket 本身是否已确认（resume 成功并收到 ping 回复）。
    private var transportReady = false
    /// 中继最近一次报告的 Mac 在线状态。旧版中继不报，默认在线。
    private var macReachable = true
    private var stopped = false
    private var generation = 0
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    /// 串行发送链：保证 ios→mac 的 seq 按请求顺序落到 WebSocket。
    /// 每个 request 单独起 Task 发送会被调度器乱序，Mac 的单调 seq 检查
    /// 会把后到的低 seq 当 replay 丢掉。
    private var sendChain: Task<Void, Never>?
    private var offlineSince: Date?
    private var connectingSince: Date?

    /// 连上中继并开始收帧。
    func connect(relayURL: URL, pairID: String, pairToken: String, macID: String, session: RemoteCryptoSession) {
        self.relayURL = relayURL
        self.pairID = pairID
        self.pairToken = pairToken
        self.macID = macID
        self.session = session
        stopped = false
        reconnectAttempt = 0
        openSocket()
        startWatchdog()
    }

    /// 用户点 Reconnect：不等退避，立刻重开一次。
    func reconnectNow() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        log("reconnect requested")
        openSocket()
        startWatchdog()
    }

    /// App 回到前台时调用：在线就 ping 一下，离线就重连。
    func checkLiveness() {
        guard !stopped else { return }
        if state.isOnline {
            ping()
        } else if state.isConnecting {
            // App 切后台时定时器会停；回前台若还卡在 connecting，直接重开，
            // 不要等 socket 自己超时（实测能挂几分钟）。
            if let since = connectingSince, Date().timeIntervalSince(since) > 10 {
                reconnectNow()
            }
        } else {
            reconnectNow()
        }
    }

    func disconnect() {
        stopped = true
        generation += 1
        reconnectTask?.cancel(); reconnectTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        pingTask?.cancel(); pingTask = nil
        transportReady = false
        connectingSince = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(RemoteLinkError.offline(L10n.text("连接已断开。")))
        state = .disconnected
    }

    // MARK: 建立连接

    private func openSocket() {
        reconnectTask?.cancel(); reconnectTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        pingTask?.cancel(); pingTask = nil
        failPending(RemoteLinkError.offline(L10n.text("连接已断开。")))

        guard !stopped, let relayURL else { return }
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = relayURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/remote/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "ios"),
            URLQueryItem(name: "mac", value: macID),
            URLQueryItem(name: "pair", value: pairID),
            URLQueryItem(name: "token", value: pairToken),
        ]
        guard let url = components.url else { return }

        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        transportReady = false
        macReachable = true
        offlineSince = nil
        connectingSince = Date()
        state = .connecting

        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        log("opening ws (attempt \(reconnectAttempt))")
        receiveLoop(gen, socket: socket)

        // URLSession 没有「已连接」回调。不要 resume 后立刻 sendPing：
        // 那时 TLS 握手还没完成，ping 会以 TLS 错误失败，反而把好连接掐掉。
        // 新中继连上后会立刻发一帧 mac/online|mac/offline，收到帧就算就绪；
        // 旧中继不发问候帧，所以 12 秒后仍未就绪再 ping 一次确认。
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !Task.isCancelled, gen == self.generation,
                  !self.transportReady, !self.stopped else { return }
            self.ping()
        }
    }

    /// 收到任何一帧都证明 WebSocket 真的通了（不只是 resume 成功）。
    private func markTransportReady() {
        guard !transportReady else { return }
        transportReady = true
        connectingSince = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        // 不要只收到 greeting 就把退避清零：否则服务器一连接就关时，
        // 会以 1 秒间隔无限重连。等真正收到一次加密响应再清零。
    }

    private func receiveLoop(_ gen: Int, socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, !self.stopped else { return }
                switch result {
                case .failure(let error):
                    self.handleTransportFailure(Self.describe(error))
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .data(let value): data = value
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: data = nil
                    }
                    if let data { self.handle(data) }
                    self.receiveLoop(gen, socket: socket)
                }
            }
        }
    }

    private func evaluateState() {
        guard !stopped else { state = .disconnected; return }
        guard transportReady else { return }
        if macReachable {
            state = .online
            offlineSince = nil
        } else {
            state = .offline(reason: L10n.text("Mac 不在线。FlowCue 可能已退出、睡眠或断网。"))
            if offlineSince == nil { offlineSince = Date() }
        }
    }

    private func handleTransportFailure(_ reason: String) {
        guard !stopped else { return }
        log("transport failure: \(reason)")
        generation += 1
        transportReady = false
        connectingSince = nil
        handshakeTask?.cancel(); handshakeTask = nil
        pingTask?.cancel(); pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failPending(RemoteLinkError.offline(reason))
        state = .offline(reason: reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectTask == nil else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(pow(2.0, Double(reconnectAttempt)) * 0.5, 30)
        log("reconnect in \(Int(delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }

    // MARK: 心跳

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled, !self.stopped else { return }
                if self.state.isOnline {
                    self.ping()
                } else if !self.state.isConnecting {
                    // 已经在退避重连就交给它，别在这里抢跑。
                    if self.reconnectTask != nil { continue }
                    // 中继说 Mac 离线时 WebSocket 本身还活着，不必每 15 秒重开；
                    // 但超过一分钟仍离线就重开一次，刷新中继侧状态。
                    if let since = self.offlineSince, Date().timeIntervalSince(since) < 60 {
                        continue
                    }
                    self.reconnectNow()
                }
            }
        }
    }

    private func ping() {
        guard let socket = task, !stopped else { return }
        pingTask?.cancel()
        pingTask = nil
        let gen = generation
        // Workers 对 WebSocket ping 控制帧的回复在 URLSession 上并不可靠，
        // 用中继回显的 app/pong 做应用层心跳。
        socket.send(.string(#"{"type":"app/ping"}"#)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation, !self.stopped else { return }
                if let error {
                    self.handleTransportFailure(Self.describe(error))
                }
            }
        }
        pingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, gen == self.generation, !self.stopped else { return }
            self.handleTransportFailure(L10n.text("心跳超时。"))
        }
    }

    // MARK: 帧

    private func handle(_ data: Data) {
        markTransportReady()
        // 任何一帧都证明链路活着，取消这一轮心跳超时。
        pingTask?.cancel()
        pingTask = nil

        // 明文控制帧：中继报告 Mac 上/下线。
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String {
            switch type {
            case "app/pong":
                // 心跳回显；transport 已由 markTransportReady 标记。
                evaluateState()
            case "mac/offline":
                log("relay says mac offline")
                macReachable = false
                failPending(RemoteLinkError.macOffline)
                evaluateState()
            case "mac/online":
                log("relay says mac online")
                macReachable = true
                evaluateState()
            case "pair/revoked", "revoked":
                log("pair revoked by relay")
                macReachable = false
                failPending(RemoteLinkError.offline(L10n.text("配对已被撤销，请重新配对。")))
                state = .offline(reason: L10n.text("配对已被撤销，请重新配对。"))
                stopped = true
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                return
            case "error":
                let code = object["error"] as? String ?? ""
                log("relay error frame: \(code)")
                if code == "mac_offline" {
                    macReachable = false
                    failPending(RemoteLinkError.macOffline)
                    evaluateState()
                }
            default:
                break
            }
            evaluateState()
            return
        }

        // 加密信封
        guard let envelope = try? JSONDecoder().decode(RemoteEnvelope.self, from: data) else {
            log("envelope decode failed (\(data.count) bytes)")
            return
        }
        guard var session else {
            log("no crypto session for frame seq=\(envelope.seq)")
            return
        }
        let plaintext: Data
        do {
            plaintext = try session.open(envelope)
        } catch {
            log("decrypt failed seq=\(envelope.seq): \(error)")
            return
        }
        self.session = session
        // 大响应被 Mac 拆成多个 chunk；先按 id 重组，再当普通 response 处理。
        if let chunk = try? JSONDecoder().decode(RemoteChunk.self, from: plaintext),
           chunk.kind == "chunk" {
            handleChunk(chunk)
            return
        }
        guard let response = try? JSONDecoder().decode(RemoteResponse.self, from: plaintext) else {
            log("response decode failed seq=\(envelope.seq)")
            return
        }
        resolve(response)
    }

    private func handleChunk(_ chunk: RemoteChunk) {
        guard chunk.total > 0, chunk.total <= 128,
              chunk.index >= 0, chunk.index < chunk.total else {
            log("bad chunk id=\(chunk.id) index=\(chunk.index)/\(chunk.total)")
            return
        }
        var buffer = chunkBuffers[chunk.id] ?? ChunkBuffer(parts: [:], total: chunk.total, at: Date())
        buffer.parts[chunk.index] = chunk.data
        buffer.total = chunk.total
        buffer.at = Date()
        // 清理超过 60 秒的残片。
        let now = Date()
        chunkBuffers = chunkBuffers.filter { now.timeIntervalSince($0.value.at) < 60 }
        if buffer.parts.count == chunk.total {
            var data = Data()
            for index in 0..<chunk.total {
                guard let part = buffer.parts[index] else { return }
                data.append(part)
            }
            chunkBuffers.removeValue(forKey: chunk.id)
            guard let response = try? JSONDecoder().decode(RemoteResponse.self, from: data) else {
                log("chunk response decode failed id=\(chunk.id)")
                return
            }
            resolve(response)
        } else {
            chunkBuffers[chunk.id] = buffer
        }
    }

    private func resolve(_ response: RemoteResponse) {
        let body: Data
        if response.encoding == "zlib" {
            guard let raw = response.body,
                  let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else {
                log("response decompress failed id=\(response.id)")
                return
            }
            body = inflated
        } else {
            body = response.body ?? Data()
        }
        pending.removeValue(forKey: response.id)?.resume(returning: body)
        reconnectAttempt = 0
        evaluateState()
    }

    func request(method: String, path: String, headers: [String: String], body: Data?, requestID: String? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        guard state.isOnline else {
            throw RemoteLinkError.offline(state.reason ?? L10n.text("Mac 不在线。"))
        }
        guard let socket = task, var session else {
            throw RemoteLinkError.notReady
        }
        let request = RemoteRequest(id: requestID ?? UUID().uuidString, method: method, path: path, headers: headers, body: body)
        let encoded = try JSONEncoder().encode(request)
        let envelope = try session.seal(encoded)
        self.session = session
        let frame = try JSONEncoder().encode(envelope)

        // 先登记 pending 再发：否则 Mac 的响应可能比登记还快，回调找不到
        // continuation，请求只能干等到超时（表现为「消息没发出去」）。
        // POST 要等 Mac 的 agent 桥接返回；GET 允许调用方给大响应更长的 deadline。
        let deadline: TimeInterval = timeout ?? (method == "POST" ? 90 : 20)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            let gen = self.generation
            let previous = sendChain
            sendChain = Task { @MainActor [weak self] in
                _ = await previous?.value
                guard let self, !self.stopped, gen == self.generation else { return }
                do {
                    try await socket.send(.data(frame))
                } catch {
                    self.handleTransportFailure(String(format: L10n.text("发送失败：%@"), Self.describe(error)))
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                guard let self, let waiting = self.pending.removeValue(forKey: request.id) else { return }
                waiting.resume(throwing: RemoteLinkError.timeout)
            }
        }
    }

    private func failPending(_ error: Error) {
        guard !pending.isEmpty else { return }
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: 工具

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return L10n.text("连接超时。")
            case .networkConnectionLost, .notConnectedToInternet: return L10n.text("网络已断开。")
            case .cancelled: return L10n.text("连接已取消。")
            case .badServerResponse, .userAuthenticationRequired: return L10n.text("中继拒绝了连接，配对可能已失效。")
            default: return L10n.text("中继连接已断开。")
            }
        }
        // 例如 POSIX "Socket is not connected"；不要把系统英文直接丢给用户。
        return L10n.text("连接已断开。")
    }

    private func log(_ message: String) {
        NSLog("[FlowCue Remote][iOS] %@", message)
    }
}


// MARK: - 远程加密（iOS 侧副本，App 不链接 CodexIdeaDockCore）

struct RemoteEnvelope: Codable {
    let v: Int
    let pair: String
    let seq: UInt64
    let nonce: Data
    let ciphertext: Data
    /// 会话标识：用来区分对端重启后的 seq 重新开始与真正的重放。
    let epoch: String?
}

struct RemoteRequest: Codable {
    let id: String
    let kind: String
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    init(id: String = UUID().uuidString, method: String, path: String,
         headers: [String: String] = [:], body: Data? = nil) {
        self.id = id
        self.kind = "request"
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

struct RemoteResponse: Codable {
    let id: String
    let status: Int
    let body: Data?
    let encoding: String?
}

struct RemoteChunk: Codable {
    let kind: String
    let id: String
    let index: Int
    let total: Int
    let data: Data
}

struct RemoteCryptoSession {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    let pairID: String
    private var sendSeq: UInt64 = 0
    private var lastReceivedSeq: UInt64 = 0
    private let sendEpoch = UUID().uuidString
    private var receiveEpoch: String?

    init(localPrivate: Curve25519.KeyAgreement.PrivateKey,
         macPublic: Curve25519.KeyAgreement.PublicKey,
         pairID: String) throws {
        let shared = try localPrivate.sharedSecretFromKeyAgreement(with: macPublic)
        let master = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(pairID.utf8),
            sharedInfo: Data("flowcue-remote-v1".utf8),
            outputByteCount: 32
        )
        self.pairID = pairID
        self.sendKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("ios2mac".utf8), outputByteCount: 32)
        self.receiveKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("mac2ios".utf8), outputByteCount: 32)
    }

    mutating func seal(_ plaintext: Data) throws -> RemoteEnvelope {
        sendSeq += 1
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = try ChaChaPoly.Nonce(data: Data(bytes))
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        return RemoteEnvelope(
            v: 1, pair: pairID, seq: sendSeq,
            nonce: Data(box.nonce),
            ciphertext: box.ciphertext + box.tag,
            epoch: sendEpoch
        )
    }

    mutating func open(_ envelope: RemoteEnvelope) throws -> Data {
        // Mac 重启后 sendSeq 从 1 重新开始；用 epoch 变化区分新会话与重放。
        if let epoch = envelope.epoch, epoch != receiveEpoch {
            receiveEpoch = epoch
            lastReceivedSeq = 0
        } else if envelope.epoch == nil, envelope.seq == 1, lastReceivedSeq > 1 {
            lastReceivedSeq = 0
        }
        guard envelope.seq > lastReceivedSeq,
              envelope.ciphertext.count > 16 else {
            throw URLError(.badServerResponse)
        }
        let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: envelope.ciphertext.dropLast(16),
            tag: envelope.ciphertext.suffix(16)
        )
        let plaintext = try ChaChaPoly.open(box, using: receiveKey)
        lastReceivedSeq = envelope.seq
        return plaintext
    }
}

// MARK: - 远程配对凭据

/// 远程配对后要长期保存的东西：pair 标识、私钥、Mac 公钥。
/// 私钥进钥匙串；其余（非机密）进 UserDefaults。
enum RemoteCredentials {
    private static let keychainAccount = "flowcue.remote.phonePrivateKey"

    static var macID: String? {
        get { UserDefaults.standard.string(forKey: "FlowCue.remoteMacID") }
        set { UserDefaults.standard.set(newValue, forKey: "FlowCue.remoteMacID") }
    }
    static var pairID: String? {
        get { UserDefaults.standard.string(forKey: "FlowCue.remotePairID") }
        set { UserDefaults.standard.set(newValue, forKey: "FlowCue.remotePairID") }
    }
    static var pairToken: String? {
        get { UserDefaults.standard.string(forKey: "FlowCue.remotePairToken") }
        set { UserDefaults.standard.set(newValue, forKey: "FlowCue.remotePairToken") }
    }
    static var macPublicKey: Data? {
        get { UserDefaults.standard.data(forKey: "FlowCue.remoteMacPublicKey") }
        set { UserDefaults.standard.set(newValue, forKey: "FlowCue.remoteMacPublicKey") }
    }
    static var deviceName: String? {
        get { UserDefaults.standard.string(forKey: "FlowCue.remoteDeviceName") }
        set { UserDefaults.standard.set(newValue, forKey: "FlowCue.remoteDeviceName") }
    }

    /// 跨重装尽量的稳定安装标识：优先 vendor ID；Mac 端用它自动替换旧配对。
    static var installID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "FlowCue.remoteInstallID"), !existing.isEmpty {
            return existing
        }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(id, forKey: "FlowCue.remoteInstallID")
        return id
    }

    static var phoneName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
    }

    static var phonePrivateKey: Curve25519.KeyAgreement.PrivateKey? {
        get {
            guard let data = keychainData() else { return nil }
            return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        set {
            guard let newValue else {
                deleteKeychainItem()
                return
            }
            saveKeychain(newValue.rawRepresentation)
        }
    }

    static func clear() {
        macID = nil; pairID = nil; pairToken = nil
        macPublicKey = nil; deviceName = nil
        phonePrivateKey = nil
    }

    // MARK: 钥匙串

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FlowCue",
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func saveKeychain(_ data: Data) {
        deleteKeychainItem()
        var attributes = query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func keychainData() -> Data? {
        var attributes = query()
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteKeychainItem() {
        SecItemDelete(query() as CFDictionary)
    }
}

extension LANRemoteController {
    /// 远程配对：用 6 位码在中继上建立隧道。
    /// 前提是本机之前通过 LAN 配对过（有 remoteMacID 和最后的设备地址）。
    func pairRemote(code: String) async -> String? {
        guard let relay = URL(string: "https://flowcue-relay.pages.dev") else { return nil }

        let previousPairID = RemoteCredentials.pairID
        let previousMacID = RemoteCredentials.macID
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

        // 1. 先试直连 Mac 的 /pair/create：它会在 Mac 本地校验 activeCode，
        //    不依赖 Worker 是否成功登记 code。这样即使 announce 被网络/VPN
        //    吞掉，已知 macID 的旧配对仍能重新审批。失败再回退 claim。
        let payload = try? JSONEncoder().encode([
            "code": code,
            "codeProof": code,
            "phonePublicKey": publicKeyBase64,
            "phoneID": RemoteCredentials.installID,
            "phoneName": RemoteCredentials.phoneName
        ])
        func postPair(_ url: URL) async -> (object: [String: Any]?, networkError: Bool) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = payload
            guard let (data, _) = try? await URLSession.shared.data(for: request) else {
                return (nil, true)
            }
            return ((try? JSONSerialization.jsonObject(with: data) as? [String: Any]), false)
        }

        var object: [String: Any]?
        var resolvedMacID = RemoteCredentials.macID
        var lastFailure = L10n.text("无法连接配对中继，请检查网络后重试。")

        if let existingMacID = RemoteCredentials.macID {
            var components = URLComponents(
                url: relay.appendingPathComponent("v1/remote/pair/create"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "mac", value: existingMacID)]
            if let directURL = components?.url {
                let result = await postPair(directURL)
                if let value = result.object {
                    if let error = value["error"] as? String {
                        lastFailure = error == "invalidCode"
                            ? L10n.text("这个远程码不正确或已过期，请用 Mac 的“远程配对码”重新生成。")
                            : String(format: L10n.text("Mac 拒绝配对：%@"), error)
                    } else {
                        object = value
                        resolvedMacID = existingMacID
                    }
                } else if result.networkError {
                    lastFailure = L10n.text("无法连接配对中继，请检查网络后重试。")
                }
            }
        }

        if object == nil {
            guard let claimURL = URL(string: "https://flowcue-relay.pages.dev/v1/remote/pair/claim") else { return nil }
            let result = await postPair(claimURL)
            if let value = result.object {
                if let error = value["error"] as? String {
                    switch error {
                    case "unknown_code":
                        lastFailure = L10n.text("这个远程码没有被 Mac 登记。请确认点的是 Mac 设置里的“远程配对码”生成，并稍等两秒再输入。")
                    case "expired":
                        lastFailure = L10n.text("远程码已过期，请在 Mac 上重新生成。")
                    case "locked":
                        lastFailure = L10n.text("这个远程码尝试次数过多，请重新生成。")
                    default:
                        lastFailure = String(format: L10n.text("配对失败：%@"), error)
                    }
                } else {
                    object = value
                }
            } else if result.networkError {
                lastFailure = L10n.text("无法连接配对中继，请检查网络后重试。")
            }
        }

        guard let object else { return lastFailure }
        guard let pairID = object["pairID"] as? String,
              let pairToken = object["pairToken"] as? String,
              let macPublicBase64 = object["macPublicKey"] as? String, !macPublicBase64.isEmpty,
              let macPublicData = Data(base64Encoded: macPublicBase64) else {
            return L10n.text("Mac 没有登记公钥。请重启 Mac 上的 FlowCue 后重新生成远程码。")
        }
        let macID = (object["macID"] as? String) ?? resolvedMacID ?? ""

        // 2. 等 Mac 批准
        var approved = false
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(1))
            var statusComponents = URLComponents(url: relay.appendingPathComponent("v1/remote/pair/status"), resolvingAgainstBaseURL: false)
            statusComponents?.queryItems = [
                URLQueryItem(name: "mac", value: macID),
                URLQueryItem(name: "pair", value: pairID)
            ]
            guard let statusURL = statusComponents?.url,
                  let (statusData, _) = try? await URLSession.shared.data(from: statusURL),
                  let statusObject = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                  let status = statusObject["status"] as? String else { continue }
            if status == "approved" { approved = true; break }
            if status == "revoked" { return L10n.text("这台 Mac 拒绝了配对。") }
            if status == "rejected" { return L10n.text("配对码已过期或已被使用，请在 Mac 上重新生成。") }
        }
        guard approved else { return L10n.text("没有等到 Mac 批准，请确认 Mac 的 Remote 已打开后重试。") }

        // 3. 派生密钥、建立隧道
        guard let macPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicData),
              let session = try? RemoteCryptoSession(
                localPrivate: privateKey, macPublic: macPublic, pairID: pairID
              ) else {
            return L10n.text("密钥协商失败。")
        }
        RemoteCredentials.macID = macID
        RemoteCredentials.pairID = pairID
        RemoteCredentials.pairToken = pairToken
        RemoteCredentials.macPublicKey = macPublicData
        RemoteCredentials.phonePrivateKey = privateKey

        let tunnel = RemoteTunnel()
        RemoteTunnel.install(tunnel)
        attachRemoteTunnel(tunnel)
        isRemote = true
        tunnel.connect(relayURL: relay, pairID: pairID, pairToken: pairToken, macID: macID, session: session)
        // 等握手完成再回 UI，避免配对页刚关就闪一条「连接失败」。
        for _ in 0..<30 where !tunnel.state.isOnline {
            try? await Task.sleep(for: .milliseconds(200))
        }

        // 重新配对后主动撤掉手机记着的旧 pair；Mac 端也会按 phoneID 自动替换。
        if let previousPairID, previousPairID != pairID {
            var components = URLComponents(
                url: relay.appendingPathComponent("v1/remote/pair/revoke"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "mac", value: previousMacID ?? macID)]
            if let url = components?.url {
                var revoke = URLRequest(url: url)
                revoke.httpMethod = "POST"
                revoke.setValue("application/json", forHTTPHeaderField: "content-type")
                revoke.httpBody = try? JSONEncoder().encode(["pairID": previousPairID])
                _ = try? await URLSession.shared.data(for: revoke)
            }
        }
        return nil
    }

    /// 远程配对成功后，让 UI 进入「连接中」状态；是否在线由隧道回调决定。
    /// 隧道会接管所有 /v1 请求，endpoint 只作为占位。
    func adoptRemoteDevice() {
        let name = RemoteCredentials.deviceName ?? "FlowCue Mac"
        let previous = selected
        selected = DiscoveredMac(
            id: RemoteCredentials.macID ?? name,
            name: name,
            endpoint: .hostPort(host: "remote.invalid", port: 47824)
        )
        isRemote = true
        if let tunnel = RemoteTunnel.current(), tunnel.state.isOnline {
            linkState = .online
            statusMessage = "Connected over Remote."
        } else {
            linkState = .connecting
            statusMessage = "Connecting over Remote…"
        }
        lastError = nil
        lastRefreshAt = previous == nil ? Date() : lastRefreshAt
        lastLatencyMs = nil
    }

    /// 启动时若有凭据，直接恢复隧道（不需要在同一 Wi-Fi）。
    /// 返回是否安装了隧道，调用方据此决定要不要进入「设备」界面。
    @discardableResult
    func restoreRemoteIfPossible() -> Bool {
        guard let pairID = RemoteCredentials.pairID,
              let pairToken = RemoteCredentials.pairToken,
              let macID = RemoteCredentials.macID,
              let macPublicData = RemoteCredentials.macPublicKey,
              let privateKey = RemoteCredentials.phonePrivateKey,
              let relay = URL(string: "https://flowcue-relay.pages.dev"),
              let macPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicData),
              let session = try? RemoteCryptoSession(localPrivate: privateKey, macPublic: macPublic, pairID: pairID) else {
            return false
        }
        // 已装过同一对凭据的隧道就不要重装，否则每次 onAppear 都断线重连。
        if let existing = RemoteTunnel.current() {
            attachRemoteTunnel(existing)
            isRemote = true
            return true
        }
        let tunnel = RemoteTunnel()
        RemoteTunnel.install(tunnel)
        attachRemoteTunnel(tunnel)
        isRemote = true
        tunnel.connect(relayURL: relay, pairID: pairID, pairToken: pairToken, macID: macID, session: session)
        return true
    }
}
