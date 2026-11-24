import AppKit
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: IdeaDockStore?
    private var syncController: IdeaSyncController?
    private var syncTask: Task<Void, Never>?
    #if !FLOWCUE_APP_STORE
    private var remoteService: LANRemoteServer?
    private var remoteRelay: RemoteRelayClient?
    private static let remotePreferenceKey = "FlowCue.remoteContinuationEnabled"
    private static let remoteExecutorKey = "FlowCue.remoteExecutorID"
    private static let remoteCodeKey = "FlowCue.remotePairingCode"
    #endif
    private var statusItem: NSStatusItem?
    private var capturePanelController: CapturePanelController?
    private var inboxWindowController: InboxWindowController?
    private var agentWindowController: AgentWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var firstRunWindowController: FirstRunWindowController?
    private var globalHotKey: GlobalHotKey?
    private let hookEventMonitor = HookEventMonitor()
    private let probeMonitor = ProbeMonitor()
    private let unreadReplies = ReplyUnreadStore()
    private var pendingApprovals = 0
    private var hotKeyRegistrationFailed = false
    private var captureHostState = CaptureHostState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        rememberFrontmostExternalApplication()
    }

    /// ⌘Q 本地监听的句柄；需要保留以便移除。
    private var quitShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if FLOWCUE_APP_STORE
        NSApp.setActivationPolicy(.regular)
        #else
        NSApp.setActivationPolicy(.accessory)
        configureDockIconPolicy()
        NotificationService.shared.start()
        installQuitShortcutMonitor()
        // 仅用于本地验证：带这个参数启动时自动打开收件箱窗口。
        if ProcessInfo.processInfo.arguments.contains("--flowcue-open-inbox") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showInbox()
            }
        }
        // 本地截图/QA：`-settings -settingsPage pro`
        if ProcessInfo.processInfo.arguments.contains("-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showSettings()
            }
        }
        NotificationService.shared.onOpenSession = { [weak self] agentID, sessionID in
            self?.unreadReplies.markRead(agentID: agentID, sessionID: sessionID)
            self?.showAgents()
            NSApp.activate(ignoringOtherApps: true)
        }
        NotificationService.shared.unreadStore = unreadReplies
        NotificationService.shared.suppressUnread = { [weak self] in
            self?.agentWindowIsKey == true
        }
        unreadReplies.onChange = { [weak self] in self?.updateStatusItem() }
        NotificationService.shared.onOpenApprovals = { [weak self] in
            // 直接落到收件箱的审批面板，而不是只把窗口提到前台
            guard let self else { return }
            if let inbox = self.inboxWindowController {
                inbox.presentApprovals()
            } else {
                self.showInbox()
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        probeMonitor.onApprovalsCount = { [weak self] count in
            self?.pendingApprovals = count
            self?.updateStatusItem()
        }
        if NotificationService.shared.isEnabled { probeMonitor.start() }
        if ProcessInfo.processInfo.arguments.contains("-testnotify") {
            Task { @MainActor in
                NotificationService.shared.postTurnFinished(
                    agent: "Claude Code",
                    sessionTitle: "FlowCue · inbox",
                    snippet: "更新了收件箱布局切换，改成带文字的菜单",
                    agentID: "claude",
                    sessionID: "debug"
                )
                try? await Task.sleep(for: .seconds(1))
                NotificationService.shared.postApprovals(count: 2)
            }
        }
        if CodexHooks.isInstalled() { hookEventMonitor.start() }
        NotificationCenter.default.addObserver(
            forName: .flowCueNotificationsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if NotificationService.shared.isEnabled { self.probeMonitor.start() } else { self.probeMonitor.stop() }
        }
        NotificationCenter.default.addObserver(
            forName: .flowCueHooksChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if CodexHooks.isInstalled() { self.hookEventMonitor.start() } else { self.hookEventMonitor.stop() }
        }
        #endif
        do {
            #if FLOWCUE_APP_STORE
            store = try IdeaDockStore(
                modelContainer: IdeaDockPersistence.makeDefaultContainer(),
                bridge: AppStoreCodexBridge(),
                userDefaults: .standard
            )
            #else
            store = try IdeaDockStore()
            #endif
        } catch {
            presentStartupFailure(error)
            return
        }

        if let store {
            syncController = IdeaSyncController(
                store: store, defaults: .standard,
                containerIdentifier: Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String
            )
        }
        #if !FLOWCUE_APP_STORE
        configureRemoteContinuation()
        #endif
        configureWindows()
        configureFrontmostApplicationObservation()
        configureStatusItem()
        #if FLOWCUE_APP_STORE
        configureApplicationMenu()
        #endif
        configureGlobalHotKey()
        if ProcessInfo.processInfo.arguments.contains("-agents") {
            DispatchQueue.main.async { [weak self] in self?.showAgents() }
        }
        let args = ProcessInfo.processInfo.arguments
        let needsFirstRun = !UserDefaults.standard.bool(forKey: "FlowCue.firstRunCompleted")
        if args.contains("-firstrun") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showFirstRun()
                let firstRunWindow = self.firstRunWindowController?.window
                for window in NSApp.windows where window !== firstRunWindow { window.orderOut(nil) }
                firstRunWindow?.makeKeyAndOrderFront(nil)
            }
        } else if needsFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showFirstRun()
            }
        }
        if args.contains("-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.showSettings()
                let settingsWindow = self.settingsWindowController?.window
                for window in NSApp.windows where window !== settingsWindow { window.orderOut(nil) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.showCapturePanel()
                // 截图用：等面板创建完成，再关掉其他窗口
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self else { return }
                    let panelWindow = self.capturePanelController?.window
                    for window in NSApp.windows where window !== panelWindow {
                        window.orderOut(nil)
                    }
                    panelWindow?.level = .floating
                    panelWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-cleardraft") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.store?.discardActiveDraft()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-inbox") {
            DispatchQueue.main.async { [weak self] in self?.showInbox() }
        }
        observePendingCount()
        showCapturePanel()

        Task { @MainActor [weak self] in
            guard let self, let store else { return }
            await store.bootstrap()
            updateStatusItem()
            syncTask = Task { @MainActor [weak self] in
                await self?.syncController?.runWhileActive()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // 点 Dock 图标：先还原最小化的窗口，没有窗口就打开收件箱
        if let minimized = NSApp.windows.first(where: {
            $0.isMiniaturized && $0.styleMask.contains(.titled)
        }) {
            minimized.deminiaturize(nil)
            minimized.makeKeyAndOrderFront(nil)
            return true
        }
        if !flag { showInbox() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTask?.cancel()
        store?.flushDraft()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        #if !FLOWCUE_APP_STORE
        remoteService?.stop()
        FoundationProcessRunner.terminateAllProcesses()
        #endif
    }

    /// 只在有主窗口时出现 Dock 图标：平时不占 Dock，开着窗口时可用 ⌘Tab 找回。
    private func configureDockIconPolicy() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowStackChanged(_:)), name: name, object: nil)
        }
    }

    @objc
    private func windowStackChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateDockIconVisibility()
        }
    }

    private func updateDockIconVisibility() {
        let hasMainWindow = NSApp.windows.contains { window in
            guard window.styleMask.contains(.titled), !(window is NSPanel) else { return false }
            return window.isVisible || window.isMiniaturized
        }
        let target: NSApplication.ActivationPolicy = hasMainWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }

    private func configureWindows() {
        guard let store else { return }
        inboxWindowController = InboxWindowController(store: store)
        capturePanelController = CapturePanelController(store: store) { [weak self] in
            self?.showInbox()
        }
    }

    private func configureFrontmostApplicationObservation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateCapturePanelFloatingState()
    }

    @objc
    private func frontmostApplicationDidChange(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else { return }

        captureHostState.applicationDidActivate(
            bundleIdentifier: application.bundleIdentifier,
            isCurrentApplication: application.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        )
        applyCapturePanelFloatingState()
    }

    private func rememberFrontmostExternalApplication() {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            captureHostState.applicationDidActivate(
                bundleIdentifier: nil,
                isCurrentApplication: false
            )
            return
        }

        captureHostState.applicationDidActivate(
            bundleIdentifier: application.bundleIdentifier,
            isCurrentApplication: application.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        )
    }

    private func updateCapturePanelFloatingState() {
        rememberFrontmostExternalApplication()
        applyCapturePanelFloatingState()
    }

    private func applyCapturePanelFloatingState() {
        capturePanelController?.setFloating(captureHostState.shouldFloat)
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.isVisible = true
        self.statusItem = statusItem
        updateStatusItem()
    }

    private func configureGlobalHotKey() {
        do {
            globalHotKey = try GlobalHotKey { [weak self] in
                self?.toggleCapturePanel()
            }
        } catch {
            hotKeyRegistrationFailed = true
            updateStatusItem()
        }
    }

    private func observePendingCount() {
        guard let store else { return }
        withObservationTracking {
            _ = store.pendingCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateStatusItem()
                observePendingCount()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let image = NSImage(named: NSImage.Name("FlowCueMenuTemplate"))
            ?? NSImage(
                systemSymbolName: "lightbulb",
                accessibilityDescription: "FlowCue"
            )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageLeading
        let pendingCount = store?.pendingCount ?? 0
        let unreadRepliesCount = unreadReplies.count
        let badgeCount = pendingApprovals + unreadRepliesCount
        if badgeCount > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(badgeCount)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
            )
        } else {
            button.title = ""
        }
        button.imageScaling = .scaleProportionallyDown
        let breakdown = [
            pendingApprovals > 0 ? "\(pendingApprovals) " + L10n.text("待审批") : nil,
            unreadRepliesCount > 0 ? "\(unreadRepliesCount) " + L10n.text("未读回复") : nil,
            pendingCount > 0 ? "\(pendingCount) " + L10n.text("待处理") : nil
        ].compactMap { $0 }
        let summary = breakdown.isEmpty ? "" : " · " + breakdown.joined(separator: " · ")
        button.toolTip = hotKeyRegistrationFailed
            ? L10n.text("FlowCue（全局快捷键注册失败）")
            : "FlowCue\(summary) · ⌃⌥Space"
        button.setAccessibilityLabel("FlowCue")
        button.setAccessibilityValue(
            breakdown.isEmpty
                ? (L10n.language == .mandarin ? "没有待处理内容" : "nothing pending")
                : breakdown.joined(separator: L10n.language == .mandarin ? "，" : ", ")
        )
    }

    private var agentWindowIsKey: Bool {
        guard let window = agentWindowController?.window else { return false }
        return window.isVisible && window.isKeyWindow
    }

    @objc
    private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleCapturePanel()
            return
        }

        if event.type == .rightMouseUp {
            showStatusMenu(relativeTo: sender)
        } else {
            toggleCapturePanel()
        }
    }

    /// 记录面板是 .nonactivatingPanel，不会激活 App，菜单栏还停在上一个 App 上，
    /// ⌘Q 就发不到这里。加一个本地监听兜底，保证窗口里按 ⌘Q 一定退出。
    private func installQuitShortcutMonitor() {
        guard quitShortcutMonitor == nil else { return }
        quitShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "q" else {
                return event
            }
            NSApp.terminate(nil)
            return nil
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(title: "FlowCue", action: nil, keyEquivalent: "")
        let applicationMenu = makeStatusMenu()
        applicationMenu.delegate = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let updated = makeStatusMenu()
        for item in updated.items {
            updated.removeItem(item)
            menu.addItem(item)
        }
    }

    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        let menu = makeStatusMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: L10n.text("记录想法…"), action: #selector(showCapturePanel), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("收件箱…"), action: #selector(showInbox), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("本机 Agent…"), action: #selector(showAgents), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())

        #if !FLOWCUE_APP_STORE
        let refreshItem = menu.addItem(
            withTitle: L10n.text("刷新 Codex 任务"),
            action: #selector(refreshThreads),
            keyEquivalent: ""
        )
        refreshItem.isEnabled = store?.isLoadingContexts == false
        menu.addItem(.separator())
        #endif
        let languageItem = NSMenuItem(title: "Language / 语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.displayName, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.representedObject = language.rawValue
            item.target = self
            item.state = L10n.language == language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        if let syncController {
            let syncItem = NSMenuItem(title: "iCloud Sync", action: #selector(toggleCloudSync), keyEquivalent: "")
            syncItem.state = syncController.isEnabled ? .on : .off
            syncItem.isEnabled = syncController.isAvailable
            menu.addItem(syncItem)
            let status = NSMenuItem(title: L10n.text(syncController.statusMessage), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let syncNow = menu.addItem(withTitle: L10n.language == .mandarin ? "立即同步" : "Sync Now", action: #selector(synchronizeCloudNow), keyEquivalent: "")
            syncNow.isEnabled = syncController.isEnabled
        }
        #if !FLOWCUE_APP_STORE
        let remoteItem = NSMenuItem(
            title: L10n.language == .mandarin ? "允许 iPhone 在同一网络继续会话" : "Allow iPhone on this network",
            action: #selector(toggleRemoteContinuation),
            keyEquivalent: ""
        )
        remoteItem.state = UserDefaults.standard.bool(forKey: Self.remotePreferenceKey) ? .on : .off
        remoteItem.isEnabled = true
        menu.addItem(remoteItem)
        if let remoteService, remoteService.isRunning {
            let codeItem = NSMenuItem(
                title: (L10n.language == .mandarin ? "配对码：" : "Pairing code: ") + remoteService.pairingCode,
                action: nil,
                keyEquivalent: ""
            )
            codeItem.isEnabled = false
            menu.addItem(codeItem)
        }
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("退出 FlowCue"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc
    private func synchronizeCloudNow() {
        Task { await syncController?.synchronizeNow() }
    }

    @objc
    private func toggleCloudSync() {
        guard let syncController else { return }
        syncController.setEnabled(!syncController.isEnabled)
        Task { await syncController.synchronizeNow() }
    }

    @objc
    private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue),
              language != L10n.language else { return }
        store?.flushDraft()
        UserDefaults.standard.set(language.rawValue, forKey: L10n.preferenceKey)
        store?.notification = nil
        capturePanelController?.hide()
        inboxWindowController?.close()
        configureWindows()
        updateStatusItem()
        showCapturePanel()
    }

    private func toggleCapturePanel() {
        showCapturePanel()
    }

    @objc
    private func showCapturePanel() {
        if let panel = capturePanelController {
            panel.show()
        } else {
            inboxWindowController?.showComposer()
        }
    }

    @objc
    private func showInbox() {
        capturePanelController?.hide()
        inboxWindowController?.show()
    }

    @objc
    private func showFirstRun() {
        if firstRunWindowController == nil {
            firstRunWindowController = FirstRunWindowController { [weak self] in
                self?.firstRunWindowController = nil
            }
        }
        firstRunWindowController?.show()
    }

    @objc
    private func showSettings() {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController() }
        settingsWindowController?.show()
    }

    @objc
    private func showAgents() {
        // 调试入口：`open -a FlowCue --args -agents`
        if ProcessInfo.processInfo.arguments.contains("-agents"), agentWindowController == nil {
            agentWindowController = AgentWindowController()
        }
        if agentWindowController == nil {
            agentWindowController = AgentWindowController()
        }
        agentWindowController?.show()
        // 打开 Agent 列表即视为看过：未读回复清零，避免角标一直挂着
        unreadReplies.clearAll()
    }

    #if !FLOWCUE_APP_STORE
    @objc private func refreshThreads() {
        Task { @MainActor [weak self] in
            await self?.store?.refreshThreads()
        }
    }

    private func configureRemoteContinuation() {
        guard UserDefaults.standard.bool(forKey: Self.remotePreferenceKey) else { return }
        startRemoteContinuation()
    }

    @objc
    private func toggleRemoteContinuation() {
        let defaults = UserDefaults.standard
        let enabled = !defaults.bool(forKey: Self.remotePreferenceKey)
        defaults.set(enabled, forKey: Self.remotePreferenceKey)
        if enabled {
            startRemoteContinuation()
        } else {
            remoteService?.stop()
            remoteService = nil
        }
    }

    private func startRemoteContinuation() {
        guard remoteService == nil else { return }
        let defaults = UserDefaults.standard
        let executorID: UUID
        if let raw = defaults.string(forKey: Self.remoteExecutorKey), let id = UUID(uuidString: raw) {
            executorID = id
        } else {
            executorID = UUID()
            defaults.set(executorID.uuidString, forKey: Self.remoteExecutorKey)
        }
        let pairingCode: String
        if let existing = defaults.string(forKey: Self.remoteCodeKey), existing.count == 6 {
            pairingCode = existing
        } else {
            pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
            defaults.set(pairingCode, forKey: Self.remoteCodeKey)
        }
        let ledgerURL = URL.applicationSupportDirectory.appendingPathComponent("FlowCueRemote/executor-ledger.json")
        do {
            let server = try LANRemoteServer(
                executorID: executorID,
                pairingCode: pairingCode,
                bridge: CodexBridge(),
                ledgerURL: ledgerURL,
                store: store
            )
            try server.start()
            remoteService = server
            LANRemoteServer.current = server
            // 中继：注册并保持 WebSocket，收到加密请求后交给同一套路由。
            let relay = RemoteRelayClient(
                relayURL: URL(string: "https://flowcue-remote.honaler.workers.dev")!,
                macID: executorID.uuidString,
                server: server
            )
            // 手机通过中继请求配对时弹窗批准。
            relay.onPairRequest = { [weak relay] pairID, code in
                guard let relay else { return }
                // 把应用提到最前，否则弹窗可能被压在别的窗口后面。
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "允许这台 iPhone 连接吗？"
                alert.informativeText = "它请求通过 Remote 连接这台 Mac。\n配对码 \(code)"
                alert.addButton(withTitle: "允许，并记住")
                alert.addButton(withTitle: "拒绝")
                alert.alertStyle = .informational
                // 菜单栏应用默认没有主窗口，普通窗口级弹窗会被压在后台看不见。
                alert.window.level = .floating
                alert.window.makeKeyAndOrderFront(nil)
                if alert.runModal() == .alertFirstButtonReturn {
                    relay.approvePair(pairID: pairID)
                } else {
                    Task { await relay.denyPair(pairID: pairID) }
                }
            }
            relay.onPairRejected = { pairID, reason in
                NSLog("[FlowCue Remote] pair rejected: %@", reason)
                Task { await relay.reportPairRejected(pairID: pairID) }
            }
            relay.start()
            remoteRelay = relay
            RemoteRelayClient.shared = relay
        } catch {
            remoteService = nil
        }
    }
    #endif

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("FlowCue 无法启动")
        alert.informativeText = (L10n.language == .mandarin ? "无法打开本地数据存储。为避免丢失想法，应用没有切换到临时存储。" : "Could not open local storage. The app did not switch to temporary storage, to protect your ideas.") + "\n\n" + error.localizedDescription
        alert.addButton(withTitle: L10n.text("退出"))
        alert.runModal()
        NSApp.terminate(nil)
    }
}
