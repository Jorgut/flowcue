import SwiftUI
import WidgetKit
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
    nonisolated(unsafe) static var current: FlowCueThemeSpec = FlowCueThemeCatalog.spec(for: "airy")

    static var accent: Color { Color(hex: current.accent) }
    static var accentSoft: Color { accent.opacity(0.14) }
    static var mint: Color { Color(hex: "#5CD9B8") }
    static var surface: Color { Color(hex: current.card) }
    static var canvas: Color { Color(hex: current.background) }
    static var hairline: Color { current.hasBorder ? Color(hex: current.border) : .clear }
    static var textPrimary: Color { Color(hex: current.foreground) }
    static var textSecondary: Color { Color(hex: current.secondary) }
    static var textTertiary: Color { Color(hex: current.secondary).opacity(0.9) }
    static var warning: Color { Color(hex: "#F0B429") }
    static var failure: Color { Color(hex: "#FF6B6B") }
    static var onAccent: Color { Color(hex: "#0A0A12") }

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
                        .init(color: FlowCueTheme.accent.opacity(0.20), location: 0),
                        .init(color: FlowCueTheme.accent.opacity(0.06), location: 0.46),
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
        isLoading = true
        await loadProducts()
        var entitled = false
        var latestExpiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  FlowCueProduct.all.contains(transaction.productID) else { continue }
            if transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantFuture) > .now {
                entitled = true
                if let expiry = transaction.expirationDate {
                    latestExpiry = max(latestExpiry ?? expiry, expiry)
                }
            }
        }
        #if DEBUG
        isPro = entitled || previewPro || isTestFlightBuild
        #else
        isPro = entitled || isTestFlightBuild
        #endif
        // 只同步真实订阅：TestFlight 的临时解锁不写出去，否则 Mac 会被永久解锁。
        ProEntitlement.publish(expiry: entitled ? latestExpiry : nil)
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

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, toolName, callId, reason, displayReason, createdAt
    }

    init(
        id: String,
        sessionId: String? = nil,
        toolName: String? = nil,
        callId: String? = nil,
        reason: String? = nil,
        displayReason: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.callId = callId
        self.reason = reason
        self.displayReason = displayReason
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try? container.decode(String.self, forKey: .sessionId)
        toolName = try? container.decode(String.self, forKey: .toolName)
        callId = try? container.decode(String.self, forKey: .callId)
        createdAt = try? container.decode(String.self, forKey: .createdAt)
        reason = Self.text(from: container, forKey: .reason)
        displayReason = Self.text(from: container, forKey: .displayReason)
    }

    /// Auto review 会把原因写成多语言对象；旧版是字符串。两种都要能解。
    private static func text(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let localized = try? container.decode([String: String].self, forKey: key) {
            return localized["zh"] ?? localized["en"] ?? localized.values.first
        }
        return nil
    }

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

/// 一次提问（可能包含多个问题），对应 DSH 的 user-questions/request。
struct DSHRemoteQuestionBatch: Codable, Identifiable, Hashable {
    struct Question: Codable, Hashable, Identifiable {
        struct Option: Codable, Hashable {
            let label: String
            let detail: String?
        }

        let id: String
        let title: String
        let detail: String?
        let multiSelect: Bool
        let options: [Option]
    }

    let id: String
    let createdAt: String?
    let sessionId: String?
    let questions: [Question]
}

struct DSHQuestionAnswer: Codable {
    struct Item: Codable {
        let id: String
        let selected: [String]
        let custom: String?
    }

    let id: String
    let answers: [Item]
}

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
    static let minimumProtocol = 1
    static let supportedProtocol = 1

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
                    return
                }
                if macProtocol > Self.supportedProtocol {
                    needsPhoneUpdate = true
                    lastError = "This Mac expects a newer iPhone app. Update FlowCue on your iPhone."
                    return
                }
            }
        } catch {
            // 旧版 Mac 没有 /v1/ping 的握手字段；继续用原有方式连接。
        }

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
            await syncProToMac(force: true)
            await uploadPushToken(endpoint: endpoint, code: code)
            statusMessage = threads.isEmpty ? "Connected. No sessions are available yet." : "Connected."
            lastError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stopDiscovery()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            lastError = "Could not connect. Check the code and that both devices are on the same Wi-Fi."
        }
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

    /// 从 Mac 拉取全部想法（包含 Mac 上原有的历史想法），用于反向同步。
    func pullIdeas() async -> [RemoteIdea]? {
        guard let selected else { return nil }
        guard let data = try? await LANHTTP.request(
            endpoint: selected.endpoint, method: "GET", path: "/v1/ideas",
            token: pairingCode, body: nil, timeout: 20
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([RemoteIdea].self, from: data)
    }

    /// 手机删掉一条想法后，让 Mac 也删掉同一条（同步是单向推送，不删会留副本）。
    func deleteIdeaOnMac(_ id: UUID) async {
        guard let selected else { return }
        struct Body: Encodable { let id: String }
        guard let body = try? JSONEncoder().encode(Body(id: id.uuidString)) else { return }
        _ = try? await LANHTTP.request(
            endpoint: selected.endpoint, method: "POST",
            path: "/v1/ideas/delete", token: pairingCode, body: body, timeout: 15
        )
    }

    func refreshDSHQuestions() async {
        guard let selected else { return }
        guard let data = try? await LANHTTP.request(
            endpoint: selected.endpoint, method: "GET", path: "/v1/dsh/questions", token: pairingCode, body: nil
        ), let list = try? JSONDecoder().decode([DSHRemoteQuestionBatch].self, from: data) else { return }
        if list != dshQuestions { dshQuestions = list }
    }

    @discardableResult
    func answerDSH(batchID: String, questionID: String, chosen: [String]) async -> Bool {
        guard let selected else { return false }
        let answer = DSHQuestionAnswer(id: batchID, answers: [.init(id: questionID, selected: chosen, custom: nil)])
        guard let body = try? JSONEncoder().encode(answer) else { return false }
        do {
            _ = try await LANHTTP.request(
                endpoint: selected.endpoint, method: "POST", path: "/v1/dsh/answer",
                token: pairingCode, body: body, timeout: 20
            )
            await refreshDSHQuestions()
            return true
        } catch {
            lastError = "问题已回答或已失效。"
            await refreshDSHQuestions()
            return false
        }
    }

    /// Mac 当前在跑什么（最近一次工具调用还没结束）。没有就返回 nil。
    func dshActivity(for session: DSHSessionSnapshot) async -> (label: String, since: Date)? {
        guard let selected else { return nil }
        struct Activity: Decodable {
            let label: String
            let since: Double?
        }
        let encoded = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
        guard let data = try? await LANHTTP.request(
            endpoint: selected.endpoint, method: "GET",
            path: "/v1/dsh/activity/\(encoded)", token: pairingCode, body: nil
        ), let activity = try? JSONDecoder().decode(Activity.self, from: data) else { return nil }
        let since = activity.since.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return (activity.label, since)
    }

    func disconnect() {
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
        didPushPro = false
        lastPushedProExpiry = nil
        macAppVersion = nil
        macProtocolVersion = nil
        needsMacUpdate = false
        needsPhoneUpdate = false
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
            await syncProToMac()
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
            let encodedImages = images.compactMap(Self.compressedImage).map { $0.base64EncodedString() }
            let body = try JSONEncoder().encode(DSHRemoteMessage(
                sessionId: session.id,
                text: trimmed.isEmpty ? "Image attachment" : trimmed,
                images: encodedImages.isEmpty ? nil : encodedImages
            ))
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/dsh/send", token: pairingCode, body: body, timeout: 30)
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
        guard let selected else { return false }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = try encoder.encode(idea)
            _ = try await LANHTTP.request(endpoint: selected.endpoint, method: "POST", path: "/v1/ideas", token: code, body: body)
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
    /// 发送类请求要更长的超时：桥接转发消息前要先唤醒 DSH 的 agent，
    /// 10 秒经常不够，会让手机把「已送达」误判成失败，用户于是反复重发。
    static func request(
        endpoint: NWEndpoint,
        method: String,
        path: String,
        token: String?,
        body: Data?,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
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
        .task(id: remoteController.isConnected) {
            guard remoteController.isConnected else { return }
            // 先把 Mac 上的想法拉下来合并（Mac → iPhone），再把本地推上去
            // （iPhone → Mac）。两边按 id 对齐，updatedAt 新的赢。
            if let pulled = await remoteController.pullIdeas() {
                _ = store.mergePulledIdeas(pulled)
            }
            await remoteController.pushAllIdeas(store.syncSnapshot())
            while !Task.isCancelled {
                await remoteController.refreshApprovals()
                await remoteController.refreshDSHQuestions()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: remoteController.dshApprovals.isEmpty) { _, isEmpty in
            if !isEmpty { activeSheet = .approvals }
        }
        .onChange(of: remoteController.dshQuestions.isEmpty) { _, isEmpty in
        }
        .onAppear {
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
        if remoteController.isConnected, let latency = remoteController.lastLatencyMs {
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
    }

    private let items: [Item] = [
        Item(tab: .inbox, title: "Ideas", glyph: .spark),
        Item(tab: .agents, title: "Agents", glyph: .plane),
        Item(tab: .me, title: "Me", glyph: .face)
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
                HomeCaptureBar(store: store, controller: remoteController, focused: $captureFocused)
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
                Text("手机上删掉，Mac 上的同一条也会删掉。这个操作不能撤销。")
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
                        .fill(isSelected ? FlowCueTheme.accentSoft : Color.clear)
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
                    IdeaSwipeRow(
                        onArchive: {
                            store.archive(idea.id)
                            if let updated = store.captures.first(where: { $0.id == idea.id }) {
                                Task { await remoteController.pushIdea(updated) }
                            }
                        },
                        onDelete: { pendingDelete = idea },
                        onTap: { openIdea = idea }
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
                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
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
private struct IdeaSwipeRow<Content: View>: View {
    let onArchive: () -> Void
    let onDelete: () -> Void
    /// 单击时才执行的导航；拖拽不会触发它。
    let onTap: () -> Void
    @ViewBuilder var content: Content

    @State private var openOffset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0
    /// 拖拽结束后同一帧里点击手势也会触发，用它把那次点击挡掉。
    @State private var didDrag = false
    /// 滑开的时刻。刚滑开时到达的点击一律忽略，否则会再播一次收起动画。
    @State private var openedAt: Date?

    private let actionWidth: CGFloat = 78
    private var actionsWidth: CGFloat { actionWidth * 2 }
    private var offset: CGFloat {
        min(0, max(-actionsWidth, openOffset + dragTranslation))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                action("Archive", color: FlowCueTheme.warning, action: onArchive)
                action("Delete", color: FlowCueTheme.failure, action: onDelete)
            }
            Button {
                // 拖拽刚结束时系统仍会送来一次点击，用 didDrag 挡掉。
                guard !didDrag else { return }
                if openOffset != 0 {
                    // 刚滑开 0.35 秒内到达的点击属于拖拽尾流，忽略，
                    // 否则会紧接着播放一次收起动画，看起来像闪了两次。
                    if let openedAt, Date().timeIntervalSince(openedAt) < 0.35 { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        openOffset = 0
                        self.openedAt = nil
                    }
                } else {
                    onTap()
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .background(FlowCueTheme.canvas)
            .offset(x: offset)
                // 用 simultaneousGesture：ScrollView 的滚动手势会抢走普通 gesture，
                // 同时识别才能拿到横向拖拽；再用「横向为主才跟手」避免影响上下滚动。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .updating($dragTranslation) { value, state, _ in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            state = abs(dx) > abs(dy) ? dx : 0
                        }
                        .onChanged { _ in
                            didDrag = true
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) > abs(dy) else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { didDrag = false }
                                return
                            }
                            let projected = openOffset + dx
                            let shouldOpen = projected < -actionsWidth / 2
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                openOffset = shouldOpen ? -actionsWidth : 0
                            }
                            openedAt = shouldOpen ? Date() : nil
                            // 留一点时间挡住这次抬指产生的点击。
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { didDrag = false }
                        }
                )

        }
        .clipped()
    }

    private func action(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { openOffset = 0 }
            action()
        } label: {
            Text(title)
                .flowCueFont(12, relativeTo: .caption, weight: .semibold)
                .foregroundStyle(Color.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(color)
        }
        .buttonStyle(.plain)
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
            Text("手机上删掉，Mac 上的同一条也会删掉。这个操作不能撤销。")
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
                if !controller.isConnected {
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
            if !controller.threads.isEmpty {
                Section("Codex") {
                    ForEach(controller.threads) { thread in
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
                }
            }

            let sessions = controller.dshSessions.filter { !$0.isSubagent }
            if !sessions.isEmpty {
                Section("DSH") {
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
            .fullScreenCover(isPresented: $showingPaywall) { PaywallView() }
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

    private var isPairing: Bool { controller.isLoading }
    private var hasFailed: Bool { !controller.isLoading && controller.lastError != nil }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                codeSection
                nearbySection
                manualSection
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

    private var name: String {
        FlowCueLinkFormat.deviceName(controller.selected?.name ?? controller.lastAttempted?.name)
    }

    private var isOnline: Bool {
        controller.isConnected && controller.lastError == nil
    }

    private var statusText: String {
        if isOnline { return "Online · Wi-Fi" }
        return controller.isConnected ? "Offline" : "Disconnected"
    }

    private var statusTint: Color {
        isOnline ? FlowCueTheme.mint : (controller.isConnected ? FlowCueTheme.failure : FlowCueTheme.textSecondary)
    }

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
                        if isOnline || controller.isConnected {
                            Circle()
                                .fill(statusTint)
                                .frame(width: 5, height: 5)
                        } else {
                            Circle()
                                .strokeBorder(statusTint, lineWidth: 1)
                                .frame(width: 6, height: 6)
                        }
                        Text(statusText)
                    }
                    .flowCueFont(12, relativeTo: .caption)
                    .foregroundStyle(statusTint)
                    .padding(.top, 6)

                    VStack(spacing: 0) {
                        infoRow("Latency", FlowCueLinkFormat.latency(controller.lastLatencyMs) ?? "—")
                        infoRow("Last sync", FlowCueLinkFormat.relative(controller.lastRefreshAt))
                        infoRow("Version", controller.versionHandshakeText, monospaced: true)
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
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
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
                            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.surface))
                            .overlay(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).strokeBorder(FlowCueTheme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Disconnect from this Mac")
                } else {
                    Button {
                        Task { await controller.retryLastAttempt() }
                    } label: {
                        Text("Reconnect")
                            .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                            .foregroundStyle(FlowCueTheme.onAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reconnect")
                }
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
            ChatScreen(controller: controller, tab: $tab, initialTarget: .codex(thread))
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
        .edgeSwipeBack()
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
                        ForEach(sessions) { session in
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
    @State private var subagents: [DSHSessionSnapshot] = []
    @State private var text = ""
    @State private var pending: PendingChatMessage?
    @State private var sending = false
    @State private var loading = false
    @State private var network = FlowCueNetworkMonitor()
    @State private var showingSwitcher = false
    @State private var showingDevice = false
    @State private var showingDisconnect = false
    @State private var showingApprovals = false
    @State private var isAtBottom = true
    @State private var live = FlowCueLiveActivityController.shared

    private var target: ChatTarget { switchedTarget ?? initialTarget }

    private var isOnline: Bool {
        controller.isConnected && network.isOnline
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
        messages = await fetchMessages(for: target)
        loading = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { break }
            await refreshApprovalsIfNeeded()
            await refreshSubagentsIfNeeded()
            let updated = await fetchMessages(for: target)
            if updated != messages { messages = updated }
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
        await refreshApprovalsIfNeeded()
        let updated = await fetchMessages(for: target)
        messages = updated
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

    private func fetchMessages(for target: ChatTarget) async -> [RemoteConversationMessage] {
        switch target {
        case .codex(let thread):
            return await controller.messages(for: thread)
        case .dsh(let session):
            return await controller.dshMessages(for: session)
        }
    }

    private func select(_ newTarget: ChatTarget) {
        guard newTarget != target else {
            showingSwitcher = false
            return
        }
        switchedTarget = newTarget
        messages = []
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
            ok = await controller.sendDSH(to: session, text: item.text, images: item.images)
        }
        if ok {
            if sessionTarget == target {
                pending = nil
                messages = await fetchMessages(for: sessionTarget)
            }
        } else if sessionTarget == target {
            // 超时 ≠ 没送到：桥接转发前要先唤醒 DSH 的 agent，消息可能已经进队列。
            // 核对最近几条，命中就当已送达，避免用户反复重发。
            let refreshed = await fetchMessages(for: sessionTarget)
            let delivered = !item.text.isEmpty
                && refreshed.suffix(3).contains { $0.text.contains(item.text) }
            if delivered {
                pending = nil
                messages = refreshed
            } else {
                pending?.state = .failed
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
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(FlowCueTheme.accent)
            )
        }
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
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .fill(FlowCueTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowCueTheme.radiusPanel, style: .continuous)
                    .strokeBorder(FlowCueTheme.hairline.opacity(0.6))
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

            HStack(spacing: 6) {
                if failed {
                    Text("Not delivered")
                        .foregroundStyle(FlowCueTheme.failure)
                    Button("Retry", action: onRetry)
                        .flowCueFont(9.5, relativeTo: .caption2, weight: .semibold)
                        .foregroundStyle(FlowCueTheme.failure)
                        .buttonStyle(.plain)
                } else {
                    Text("SENDING.")
                }
            }
            .flowCueFont(9.5, relativeTo: .caption2)
            .tracking(1.2)
            .foregroundStyle(failed ? FlowCueTheme.failure : FlowCueTheme.textSecondary)
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
    case numbered([String])
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
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1).").flowCueFont(13, relativeTo: .subheadline).monospacedDigit().foregroundStyle(.secondary)
                        InlineMarkdownText(text: item)
                            .flowCueFont(13, relativeTo: .subheadline)
                            .lineSpacing(2)
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

    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID

    @State private var network = FlowCueNetworkMonitor()
    @State private var showingPaywall = MePreview.state == "paywall"
    @State private var showingPairing = MePreview.state == "pairing"
    @State private var showingDevice = false
    @State private var showingAppearance = MePreview.state == "appearance"
    @State private var showingLanguage = MePreview.state == "language"
    @State private var showingPro = MePreview.state == "pro"
    @State private var showingArchive = MePreview.state == "archive"
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
                        if !subscription.isPro {
                            proButton
                                .padding(.top, 18)
                        }
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
            .fullScreenCover(isPresented: $showingPaywall) {
                PaywallView()
            }
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
            .sheet(isPresented: $showingPro) {
                ProStatusSheet()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(isPresented: $showingDevice) {
                RemoteDeviceView(controller: remoteController, tab: $tab)
            }
            .navigationDestination(isPresented: $showingAppearance) {
                AppearanceView(showsDone: false)
            }
            .navigationDestination(isPresented: $showingArchive) {
                ArchiveView(store: store, remoteController: remoteController)
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
                if remoteController.isConnected {
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
                openPro()
            } label: {
                MeRowLabel(title: "FlowCue Pro", value: proValue, valueColor: proValueColor)
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
                AboutView(showOnboarding: showOnboarding)
            } label: {
                MeRowLabel(title: "About", value: versionString)
            }
            .buttonStyle(.plain)
        }
    }

    private var proButton: some View {
        Button {
            showingPaywall = true
        } label: {
            Text("Get FlowCue Pro")
                .flowCueFont(14, relativeTo: .subheadline, weight: .semibold)
                .foregroundStyle(FlowCueTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Get FlowCue Pro")
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
        guard remoteController.isConnected else { return 0 }
        return remoteController.dshBridgeAvailable ? 2 : 1
    }

    private var deviceCount: Int {
        remoteController.selected == nil ? 0 : 1
    }

    private var deviceValue: String {
        guard let selected = remoteController.selected else { return "Not paired" }
        let name = FlowCueLinkFormat.deviceName(selected.name)
        return network.isOnline ? "\(name) · online" : "\(name) · offline"
    }

    private var deviceValueColor: Color {
        remoteController.selected == nil ? FlowCueTheme.textSecondary : (network.isOnline ? FlowCueTheme.textPrimary : FlowCueTheme.warning)
    }

    private var proValue: String {
        if subscription.isLoading { return "Checking…" }
        return subscription.isPro ? "Active" : "Upgrade"
    }

    private var proValueColor: Color {
        subscription.isPro ? FlowCueTheme.textSecondary : FlowCueTheme.accent
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
                if enabled && !subscription.isPro {
                    showingPaywall = true
                } else {
                    syncController.setEnabled(enabled)
                    if enabled {
                        Task { await syncController.synchronizeNow() }
                    }
                }
            }
        )
    }

    private func openPro() {
        if subscription.isPro {
            showingPro = true
        } else {
            showingPaywall = true
        }
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
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @Bindable var syncController: IdeaSyncController
    @Bindable var remoteController: LANRemoteController
    let showOnboarding: () -> Void

    @Environment(SubscriptionManager.self) private var subscription
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.english.rawValue

    @State private var showingPaywall = false
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
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(FlowCueTheme.textSecondary.opacity(0.7))
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
        .fullScreenCover(isPresented: $showingPaywall) {
            PaywallView()
        }
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
        .disabled(!subscription.isPro || !syncController.isEnabled || syncController.isSyncing)
        .opacity(subscription.isPro && syncController.isEnabled ? 1 : 0.45)
    }

    private var syncBinding: Binding<Bool> {
        Binding(
            get: { syncController.isEnabled },
            set: { enabled in
                if enabled && !subscription.isPro {
                    showingPaywall = true
                } else {
                    syncController.setEnabled(enabled)
                    if enabled {
                        Task { await syncController.synchronizeNow() }
                    }
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
        Pro: \(subscription.isPro ? "yes" : "no")
        Mac: \(remoteController.isConnected ? "connected" : "not connected")
        iCloud sync: \(syncController.isEnabled ? "on" : "off") · \(L10n.text(syncController.statusMessage))
        """
        UIPasteboard.general.string = diagnostics
        diagnosticsCopied = true
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .flowCueFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlowCueTheme.textPrimary)
            Spacer(minLength: 8)
            Text(value)
                .flowCueFont(10, relativeTo: .caption2)
                .foregroundStyle(FlowCueTheme.textSecondary)
                .lineLimit(1)
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

    @Environment(SubscriptionManager.self) private var subscription
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FlowCueThemeSelection.key) private var themeID = FlowCueThemeSelection.defaultID
    @AppStorage("FlowCue.textScale") private var textScale = 1.0
    @State private var group: FlowCueThemeGroup?
    @State private var showingPaywall = false

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

                Text("\(themes.count) THEMES · \(themes.filter { !$0.isPro }.count) FREE")
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

                if !subscription.isPro {
                    unlockButton
                        .padding(.top, 22)
                }
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
        .fullScreenCover(isPresented: $showingPaywall) {
            PaywallView()
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
                    if spec.isPro {
                        Text("PRO")
                            .font(.system(size: 9.5, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(FlowCueTheme.hairline)
                            )
                    } else {
                        Text("FREE")
                            .font(.system(size: 9.5, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(FlowCueTheme.textSecondary)
                    }
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

    private var unlockButton: some View {
        Button {
            showingPaywall = true
        } label: {
            Text("Unlock all themes")
                .flowCueFont(13, relativeTo: .footnote, weight: .semibold)
                .foregroundStyle(FlowCueTheme.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: FlowCueTheme.radiusCapsule, style: .continuous).fill(FlowCueTheme.accent))
        }
        .buttonStyle(.plain)
    }

    private func select(_ spec: FlowCueThemeSpec) {
        if spec.isPro && !subscription.isPro {
            showingPaywall = true
            return
        }
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
