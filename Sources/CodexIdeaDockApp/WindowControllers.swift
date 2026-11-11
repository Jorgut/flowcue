import AppKit
#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif
import QuartzCore
import SwiftUI

@MainActor
final class CapturePanelController: NSWindowController {
    private static let panelSize = NSSize(width: 520, height: 260)
    private let store: IdeaDockStore
    private var presentationGeneration = 0

    var isVisible: Bool {
        window?.isVisible == true
    }

    init(store: IdeaDockStore, onOpenInbox: @escaping @MainActor () -> Void) {
        self.store = store
        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.controller = self
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentViewController = NSHostingController(
            rootView: CapturePanelView(
                store: store,
                onSave: { [weak self] in
                    if store.saveCurrent() != nil {
                        self?.hide()
                    }
                },
                onQueue: {
                    #if FLOWCUE_APP_STORE
                    let text = store.draftText
                    guard store.saveCurrent() != nil else { return }
                    Task { @MainActor in
                        store.notification = await CodexFallback.copyAndActivate(text: text).notification
                    }
                    #else
                    Task { @MainActor in
                        await store.queueCurrent()
                    }
                    #endif
                },
                onNewCapture: {
                    store.newCapture()
                },
                onOpenInbox: onOpenInbox,
                onClose: { [weak self] in
                    self?.hide()
                }
            )
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        presentationGeneration &+= 1

        if window.isVisible {
            window.alphaValue = 1
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
            return
        }

        let targetFrame = preferredFrame(for: window)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startingFrame = reduceMotion ? targetFrame : targetFrame.insetBy(dx: 5, dy: 3)

        window.setFrame(startingFrame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.1 : 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            if !reduceMotion {
                window.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    func setFloating(_ shouldFloat: Bool) {
        guard let window else { return }
        let targetLevel: NSWindow.Level = shouldFloat ? .floating : .normal
        guard window.level != targetLevel else { return }

        window.level = targetLevel
        if shouldFloat, window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        store.flushDraft()
        guard let window, window.isVisible else { return }
        presentationGeneration &+= 1
        let hideGeneration = presentationGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.06 : 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window,
                      self.presentationGeneration == hideGeneration else { return }
                window.orderOut(nil)
                window.alphaValue = 1
            }
        }
    }

    private func preferredFrame(for window: NSWindow) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? window.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: Self.panelSize)
        }

        let origin = NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.maxY - Self.panelSize.height - 72
        )
        return NSRect(origin: origin, size: Self.panelSize)
    }
}

@MainActor
private final class CapturePanel: NSPanel {
    weak var controller: CapturePanelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        controller?.hide()
    }
}

@MainActor
final class InboxWindowController: NSWindowController, NSWindowDelegate {
    init(store: IdeaDockStore) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "FlowCue 收件箱"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        // Compatibility key: keep the existing window restoration state across the rebrand.
        window.setFrameAutosaveName("CodexIdeaDock.Inbox")
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: InboxView(store: store))
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
