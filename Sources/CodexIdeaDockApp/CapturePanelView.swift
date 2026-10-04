#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif
import Observation
import SwiftUI

struct CapturePanelView: View {
    @Bindable var store: IdeaDockStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onSave: () -> Void
    let onQueue: () -> Void
    let onNewCapture: () -> Void
    let onOpenInbox: () -> Void
    let onClose: () -> Void

    private var isDraftEmpty: Bool {
        store.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            if AppDistribution.supportsDirectQueue {
                CaptureHeader(
                    contexts: store.contexts,
                    source: store.sourceContext,
                    target: store.targetContext,
                    isRefreshing: store.isLoadingContexts,
                    isQueueing: store.isQueueing,
                    onSelectSource: { store.setSource($0) },
                    onSelectTarget: { store.setTarget($0) },
                    onTogglePinned: { context in
                        store.setPinned(!context.isPinned, for: context.id)
                    },
                    onRefresh: {
                        Task { @MainActor in
                            await store.refreshThreads()
                        }
                    },
                    onOpenInbox: onOpenInbox,
                    onClose: onClose
                )
            } else {
                AppStoreCaptureHeader(
                    onOpenInbox: onOpenInbox,
                    onClose: onClose
                )
            }

            CaptureEditor(
                text: $store.draftText,
                isEnabled: !store.isQueueing,
                onSave: onSave,
                onQueue: onQueue,
                onNewCapture: onNewCapture,
                onCancel: onClose
            )

            CaptureFooter(
                isDraftEmpty: isDraftEmpty,
                isQueueing: store.isQueueing,
                isTargetAvailable: store.targetContext?.isAvailable == true,
                notificationMessage: store.notification?.message,
                onCopyAndOpenCodex: {
                    let text = store.draftText
                    Task { @MainActor in
                        store.notification = await CodexFallback.copyAndActivate(text: text).notification
                    }
                },
                onSave: onSave,
                onQueue: onQueue
            )
        }
        .padding(12)
        .frame(width: 520, height: 260)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 16))
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.14), value: store.notification?.id)
    }
}

private struct AppStoreCaptureHeader: View {
    let onOpenInbox: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("记录想法", systemImage: "lightbulb")
                .font(.headline)

            Text("内容只保存在本机")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(action: onOpenInbox) {
                Image(systemName: "tray.full")
            }
            .buttonStyle(.plain)
            .help("打开收件箱")
            .accessibilityLabel("打开收件箱")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("隐藏悬浮窗，保留草稿")
            .accessibilityLabel("隐藏悬浮窗并保留草稿")
        }
    }
}

private struct CaptureHeader: View {
    let contexts: [WorkContextItem]
    let source: WorkContextItem?
    let target: WorkContextItem?
    let isRefreshing: Bool
    let isQueueing: Bool
    let onSelectSource: (String) -> Void
    let onSelectTarget: (String) -> Void
    let onTogglePinned: (WorkContextItem) -> Void
    let onRefresh: () -> Void
    let onOpenInbox: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ThreadContextPicker(
                label: "来源",
                selectedContext: source,
                contexts: contexts,
                isDisabled: isQueueing,
                onSelect: onSelectSource,
                onTogglePinned: onTogglePinned
            )

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            ThreadContextPicker(
                label: "目标",
                selectedContext: target,
                contexts: contexts,
                isDisabled: isQueueing,
                onSelect: onSelectTarget,
                onTogglePinned: onTogglePinned
            )

            Spacer(minLength: 0)

            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在刷新 Codex 任务")
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("刷新 Codex 任务")
                    .accessibilityLabel("刷新 Codex 任务")
                }
            }
            .disabled(isQueueing)

            Button(action: onOpenInbox) {
                Image(systemName: "tray.full")
            }
            .buttonStyle(.plain)
            .help("打开收件箱")
            .accessibilityLabel("打开收件箱")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("隐藏悬浮窗，保留草稿")
            .accessibilityLabel("隐藏悬浮窗并保留草稿")
        }
    }
}

private struct ThreadContextPicker: View {
    let label: String
    let selectedContext: WorkContextItem?
    let contexts: [WorkContextItem]
    let isDisabled: Bool
    let onSelect: (String) -> Void
    let onTogglePinned: (WorkContextItem) -> Void

    var body: some View {
        Menu {
            if contexts.isEmpty {
                Button("暂无可用任务") { }
                    .disabled(true)
            } else {
                ForEach(contexts) { context in
                    Button {
                        onSelect(context.id)
                    } label: {
                        HStack {
                            Text(context.menuDisplayTitle)
                            if context.isPinned {
                                Image(systemName: "pin.fill")
                            }
                            if !context.isAvailable {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            if selectedContext?.id == context.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!context.isAvailable)
                }

                Divider()

                Menu("管理置顶") {
                    ForEach(contexts) { context in
                        Button {
                            onTogglePinned(context)
                        } label: {
                            Label(
                                context.isPinned ? "取消置顶 \(context.menuDisplayTitle)" : "置顶 \(context.menuDisplayTitle)",
                                systemImage: context.isPinned ? "pin.slash" : "pin"
                            )
                        }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(selectedContext?.selectionDisplayTitle ?? "选择 Codex 任务")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let selectedContext {
                    Text(selectedContext.selectionMetadata)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .help(selectedContext?.projectDirectory ?? "选择\(label)任务")
        .disabled(isDisabled)
        .accessibilityLabel("\(label)任务")
        .accessibilityValue(
            selectedContext.map { "\($0.selectionDisplayTitle)，\($0.selectionMetadata)" }
                ?? "未选择"
        )
    }
}

private struct CaptureEditor: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSave: () -> Void
    let onQueue: () -> Void
    let onNewCapture: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NativeTextEditor(
            text: $text,
            isEnabled: isEnabled,
            accessibilityLabel: "想法内容",
            onSave: onSave,
            onQueue: onQueue,
            onNewCapture: onNewCapture,
            onCancel: onCancel
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text("粘贴、输入或使用系统听写记录一闪而过的想法…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(.black.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 10))
    }
}

private struct CaptureFooter: View {
    let isDraftEmpty: Bool
    let isQueueing: Bool
    let isTargetAvailable: Bool
    let notificationMessage: String?
    let onCopyAndOpenCodex: () -> Void
    let onSave: () -> Void
    let onQueue: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let notificationMessage {
                Label(notificationMessage, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
            } else {
                Text(
                    AppDistribution.supportsDirectQueue
                        ? "⌘↩ 保存 · ⌥⌘↩ 排队 · ⌘N 新建"
                        : "⌘↩ 保存 · ⌥⌘↩ 复制并打开 Codex · ⌘N 新建"
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if AppDistribution.supportsDirectQueue {
                Button(action: onCopyAndOpenCodex) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .disabled(isDraftEmpty)
                .help("复制内容并打开 Codex")
                .accessibilityLabel("复制内容并打开 Codex")
            }

            Button("保存", action: onSave)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isDraftEmpty || isQueueing)
                .accessibilityLabel("保存想法并关闭")

            if AppDistribution.supportsDirectQueue {
                Button {
                    onQueue()
                } label: {
                    if isQueueing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44)
                    } else {
                        Text("排到 Codex")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .buttonStyle(.borderedProminent)
                .disabled(isDraftEmpty || isQueueing || !isTargetAvailable)
                .accessibilityLabel(isQueueing ? "正在排到 Codex" : "排到 Codex")
            } else {
                Button("复制并打开 Codex", action: onQueue)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .buttonStyle(.borderedProminent)
                    .disabled(isDraftEmpty)
                    .accessibilityLabel("保存想法、复制内容并打开 Codex")
            }
        }
        .frame(minHeight: 24)
    }
}

extension WorkContextItem {
    var menuDisplayTitle: String {
        let projectLabel = projectDirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "无项目目录"
        return "\(title) — \(projectLabel) · \(id.prefix(8))"
    }

    var selectionDisplayTitle: String {
        isAvailable ? title : "\(title)（已失效）"
    }

    var selectionMetadata: String {
        let projectLabel = projectDirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "无项目目录"
        return "\(projectLabel) · \(id.prefix(8))"
    }
}
