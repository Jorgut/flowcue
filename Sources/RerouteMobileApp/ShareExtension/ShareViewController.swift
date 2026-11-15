import SwiftUI
import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hasPresented = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        loadInput()
    }

    private func loadInput() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            present(text: "")
            return
        }

        for item in items {
            if let text = item.attributedContentText?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                present(text: text)
                return
            }

            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    load(provider, typeIdentifier: UTType.plainText.identifier)
                    return
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    load(provider, typeIdentifier: UTType.url.identifier)
                    return
                }
            }
        }

        present(text: "")
    }

    private func load(_ provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            var text = ""
            if let string = item as? String {
                text = string
            } else if let url = item as? URL {
                text = url.absoluteString
            } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                text = string
            }
            Task { @MainActor in
                self?.present(text: text)
            }
        }
    }

    @MainActor
    private func present(text: String) {
        guard !hasPresented else { return }
        hasPresented = true

        let root = ShareExtensionView(
            initialText: text,
            onSave: { [weak self] text, target in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    FlowCueSharedCaptureStore.append(
                        FlowCueSharedCapture(text: trimmed, target: target, createdAt: .now)
                    )
                }
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            }
        )

        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: 0, height: 380)
    }
}
