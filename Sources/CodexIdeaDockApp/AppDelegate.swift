import AppKit
import CodexIdeaDockCore
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: IdeaDockStore?
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
        NSApp.setActivationPolicy(.accessory)
        do {
            store = try IdeaDockStore()
        } catch {
            presentStartupFailure(error)
            return
        }

        configureWindows()
        configureFrontmostApplicationObservation()
        configureStatusItem()
        configureGlobalHotKey()
        observePendingCount()
        showCapturePanel()

        Task { @MainActor [weak self] in
            guard let self, let store else { return }
            await store.bootstrap()
            updateStatusItem()
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
        store?.flushDraft()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        FoundationProcessRunner.terminateAllProcesses()
    }

    private func configureWindows() {
        guard let store else { return }
        capturePanelController = CapturePanelController(
            store: store,
            onOpenInbox: { [weak self] in self?.showInbox() }
        )
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

        let image = NSImage(named: NSImage.Name("RerouteMenuTemplate"))
            ?? NSImage(
                systemSymbolName: "lightbulb",
                accessibilityDescription: "Reroute"
            )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageLeading
        let pendingCount = store?.pendingCount ?? 0
        button.title = pendingCount > 0 ? " \(pendingCount)" : ""
        button.toolTip = hotKeyRegistrationFailed
            ? "Reroute（全局快捷键注册失败）"
            : "Reroute · ⌃⌥Space"
        button.setAccessibilityLabel("Reroute")
        button.setAccessibilityValue("\(pendingCount) 条待处理想法")
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

    private func showStatusMenu(relativeTo button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "记录想法…", action: #selector(showCapturePanel), keyEquivalent: "")
        menu.addItem(withTitle: "收件箱…", action: #selector(showInbox), keyEquivalent: "")
        menu.addItem(.separator())

        let refreshItem = menu.addItem(
            withTitle: "刷新 Codex 任务",
            action: #selector(refreshThreads),
            keyEquivalent: ""
        )
        refreshItem.isEnabled = store?.isLoadingContexts == false
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Reroute", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func toggleCapturePanel() {
        guard let capturePanelController else { return }
        if capturePanelController.isVisible {
            capturePanelController.hide()
        } else {
            updateCapturePanelFloatingState()
            capturePanelController.show()
        }
    }

    @objc
    private func showCapturePanel() {
        updateCapturePanelFloatingState()
        capturePanelController?.show()
    }

    @objc
    private func showInbox() {
        capturePanelController?.hide()
        inboxWindowController?.show()
    }

    @objc
    private func refreshThreads() {
        Task { @MainActor [weak self] in
            await self?.store?.refreshThreads()
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }

    private func presentStartupFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reroute 无法启动"
        alert.informativeText = "无法打开本地数据存储。为避免丢失想法，应用没有切换到临时存储。\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
