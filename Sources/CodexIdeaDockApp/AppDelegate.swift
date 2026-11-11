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
    private var statusItem: NSStatusItem?
    private var capturePanelController: CapturePanelController?
    private var inboxWindowController: InboxWindowController?
    private var globalHotKey: GlobalHotKey?
    private var hotKeyRegistrationFailed = false
    private var captureHostState = CaptureHostState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        rememberFrontmostExternalApplication()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if FLOWCUE_APP_STORE
        NSApp.setActivationPolicy(.regular)
        #else
        NSApp.setActivationPolicy(.accessory)
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
        configureWindows()
        configureFrontmostApplicationObservation()
        configureStatusItem()
        #if FLOWCUE_APP_STORE
        configureApplicationMenu()
        #endif
        configureGlobalHotKey()
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
        showCapturePanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTask?.cancel()
        store?.flushDraft()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        #if !FLOWCUE_APP_STORE
        FoundationProcessRunner.terminateAllProcesses()
        #endif
    }

    private func configureWindows() {
        guard let store else { return }
        inboxWindowController = InboxWindowController(store: store)
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
        button.title = pendingCount > 0 ? " \(pendingCount)" : ""
        button.toolTip = hotKeyRegistrationFailed
            ? L10n.text("FlowCue（全局快捷键注册失败）")
            : "FlowCue · ⌃⌥Space"
        button.setAccessibilityLabel("FlowCue")
        button.setAccessibilityValue("\(pendingCount) " + (L10n.language == .mandarin ? "条待处理想法" : "pending ideas"))
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
        inboxWindowController?.showComposer()
    }

    @objc
    private func showInbox() {
        capturePanelController?.hide()
        inboxWindowController?.show()
    }

    #if !FLOWCUE_APP_STORE
    @objc private func refreshThreads() {
        Task { @MainActor [weak self] in
            await self?.store?.refreshThreads()
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
