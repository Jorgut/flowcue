import AppKit
import Carbon.HIToolbox
import SwiftUI

struct NativeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let onSave: () -> Void
    let onQueue: () -> Void
    let onNewCapture: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = CommandTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.usesFindPanel = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(accessibilityLabel)
        context.coordinator.configure(textView)
        textView.isEditable = isEnabled

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandTextView else { return }
        context.coordinator.parent = self
        context.coordinator.configure(textView)
        textView.isEditable = isEnabled
        textView.setAccessibilityLabel(accessibilityLabel)

        if textView.string != text, !textView.hasMarkedText() {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges.compactMap { value in
                let range = value.rangeValue
                let clampedLocation = min(range.location, textView.string.utf16.count)
                let clampedLength = min(range.length, textView.string.utf16.count - clampedLocation)
                return NSValue(range: NSRange(location: clampedLocation, length: clampedLength))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor

        init(parent: NativeTextEditor) {
            self.parent = parent
        }

        fileprivate func configure(_ textView: CommandTextView) {
            textView.onSave = parent.onSave
            textView.onQueue = parent.onQueue
            textView.onNewCapture = parent.onNewCapture
            textView.onCancel = parent.onCancel
            textView.onCommitPendingText = { [weak self] text in
                guard let self, parent.text != text else { return }
                parent.text = text
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

@MainActor
fileprivate final class CommandTextView: NSTextView {
    private final class ObserverBox: @unchecked Sendable {
        var value: NSObjectProtocol?
    }

    var onSave: (() -> Void)?
    var onQueue: (() -> Void)?
    var onNewCapture: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommitPendingText: ((String) -> Void)?

    private let observerBox = ObserverBox()

    deinit {
        if let observer = observerBox.value {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let observer = observerBox.value {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let window else { return }

        observerBox.value = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command), event.keyCode == UInt16(kVK_ANSI_N) {
            commitPendingText()
            onNewCapture?()
            return true
        }

        let isReturn = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        if modifiers.contains(.command), isReturn {
            commitPendingText()
            if modifiers.contains(.option) {
                onQueue?()
            } else {
                onSave?()
            }
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private func commitPendingText() {
        if hasMarkedText() {
            unmarkText()
        }
        onCommitPendingText?(string)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
