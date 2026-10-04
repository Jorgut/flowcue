#if SWIFT_PACKAGE
import CodexIdeaDockCore
#endif
import Foundation
import Observation
import SwiftUI

private enum RouteFilter: Hashable {
    case all
    case unassigned
    case thread(String)
    case title(String)

    func matches(id: String?, title: String?) -> Bool {
        switch self {
        case .all:
            true
        case .unassigned:
            (id == nil || id?.isEmpty == true)
                && (title == nil || title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
        case let .thread(threadID):
            id == threadID
        case let .title(routeTitle):
            (id == nil || id?.isEmpty == true)
                && title?.trimmingCharacters(in: .whitespacesAndNewlines) == routeTitle
        }
    }
}

private struct RouteFilterOption: Identifiable, Hashable {
    let filter: RouteFilter
    let title: String

    var id: RouteFilter { filter }
}

struct InboxView: View {
    @Bindable var store: IdeaDockStore
    @State private var selectedCaptureID: UUID?
    @State private var lastArchivedCaptureID: UUID?
    @State private var sourceFilter: RouteFilter = .all
    @State private var targetFilter: RouteFilter = .all

    private var visibleCaptures: [CaptureItem] {
        store.filteredCaptures.filter { capture in
            sourceFilter.matches(id: capture.sourceThreadID, title: capture.sourceTitle)
                && targetFilter.matches(id: capture.targetThreadID, title: capture.targetTitle)
        }
    }

    private var sourceFilterOptions: [RouteFilterOption] {
        routeFilterOptions(isSource: true)
    }

    private var targetFilterOptions: [RouteFilterOption] {
        routeFilterOptions(isSource: false)
    }

    private var selectedCapture: CaptureItem? {
        guard let selectedCaptureID else { return nil }
        return store.captures.first { $0.id == selectedCaptureID }
    }

    var body: some View {
        VStack(spacing: 0) {
            InboxToolbar(
                store: store,
                displayedCount: visibleCaptures.count,
                sourceFilter: $sourceFilter,
                targetFilter: $targetFilter,
                sourceFilterOptions: sourceFilterOptions,
                targetFilterOptions: targetFilterOptions,
                canUndoArchive: lastArchivedCaptureID != nil
            ) {
                guard let lastArchivedCaptureID else { return }
                store.undoArchive(lastArchivedCaptureID)
                self.lastArchivedCaptureID = nil
            }

            Divider()

            NavigationSplitView {
                InboxCaptureList(
                    captures: visibleCaptures,
                    selection: $selectedCaptureID,
                    onQueue: queueCapture,
                    onArchive: archiveCapture,
                    onRestore: restoreCapture,
                    onCopyAndOpenCodex: copyAndOpenCodex
                )
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
            } detail: {
                if let selectedCapture {
                    CaptureDetailView(
                        capture: selectedCapture,
                        contexts: store.contexts,
                        isBusy: store.isQueueing,
                        onTextChange: { updatedText in
                            store.updateText(captureID: selectedCapture.id, text: updatedText)
                        },
                        onRouteChange: { sourceThreadID, targetThreadID in
                            store.updateRoute(
                                captureID: selectedCapture.id,
                                sourceThreadID: sourceThreadID,
                                targetThreadID: targetThreadID
                            )
                        },
                        onQueue: { queueCapture(selectedCapture.id) },
                        onArchive: { archiveCapture(selectedCapture.id) },
                        onRestore: { restoreCapture(selectedCapture.id) },
                        onCopyAndOpenCodex: copyAndOpenCodex
                    )
                    .id(selectedCapture.id)
                } else {
                    ContentUnavailableView(
                        "选择一条想法",
                        systemImage: "lightbulb",
                        description: Text(
                            AppDistribution.supportsDirectQueue
                                ? "可以编辑、排队到 Codex，或归档已处理内容。"
                                : "可以编辑、复制到 Codex，或归档已处理内容。"
                        )
                    )
                }
            }
            .navigationSplitViewStyle(.balanced)

            if let message = store.notification?.message {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onChange(of: visibleCaptures.map(\.id)) {
            guard let selectedCaptureID else { return }
            if !visibleCaptures.contains(where: { $0.id == selectedCaptureID }) {
                self.selectedCaptureID = nil
            }
        }
    }

    private func queueCapture(_ captureID: UUID) {
        Task { @MainActor in
            await store.queue(captureID: captureID)
        }
    }

    private func archiveCapture(_ captureID: UUID) {
        store.archive(captureID)
        lastArchivedCaptureID = captureID
        if selectedCaptureID == captureID {
            selectedCaptureID = nil
        }
    }

    private func restoreCapture(_ captureID: UUID) {
        store.undoArchive(captureID)
        lastArchivedCaptureID = nil
    }

    private func copyAndOpenCodex(_ captureID: UUID) {
        guard let capture = store.captures.first(where: { $0.id == captureID }) else { return }
        copyAndOpenCodex(capture.text)
    }

    private func copyAndOpenCodex(_ text: String) {
        Task { @MainActor in
            store.notification = await CodexFallback.copyAndActivate(text: text).notification
        }
    }

    private func routeFilterOptions(isSource: Bool) -> [RouteFilterOption] {
        let contextTitles = Dictionary(uniqueKeysWithValues: store.contexts.map { ($0.id, $0.title) })
        var options: [RouteFilterOption] = []
        var seen = Set<RouteFilter>()
        var hasUnassignedRoute = false

        func append(_ filter: RouteFilter, title: String) {
            guard seen.insert(filter).inserted else { return }
            options.append(RouteFilterOption(filter: filter, title: title))
        }

        for capture in store.captures where capture.status != .draft {
            let threadID = isSource ? capture.sourceThreadID : capture.targetThreadID
            let routeTitle = isSource ? capture.sourceTitle : capture.targetTitle

            if let threadID, !threadID.isEmpty {
                let captureTitle = routeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackTitle = captureTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? contextTitles[threadID]
                    ?? threadID
                let title = routeOptionTitle(
                    threadID: threadID,
                    fallbackTitle: fallbackTitle
                )
                append(.thread(threadID), title: title)
            } else if let routeTitle {
                let title = routeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty {
                    hasUnassignedRoute = true
                } else {
                    append(.title(title), title: title)
                }
            } else {
                hasUnassignedRoute = true
            }
        }

        if hasUnassignedRoute {
            append(.unassigned, title: "未关联")
        }
        return options
    }

    private func routeOptionTitle(threadID: String, fallbackTitle: String) -> String {
        guard let context = store.contexts.first(where: { $0.id == threadID }) else {
            return "\(fallbackTitle) · \(threadID.prefix(8))"
        }
        let projectLabel = context.projectDirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "无项目目录"
        let availability = context.isAvailable ? "" : " · 已失效"
        return "\(fallbackTitle) — \(projectLabel) · \(threadID.prefix(8))\(availability)"
    }
}

private struct InboxToolbar: View {
    @Bindable var store: IdeaDockStore
    let displayedCount: Int
    @Binding var sourceFilter: RouteFilter
    @Binding var targetFilter: RouteFilter
    let sourceFilterOptions: [RouteFilterOption]
    let targetFilterOptions: [RouteFilterOption]
    let canUndoArchive: Bool
    let onUndoArchive: () -> Void

    private var availableStatuses: [CaptureStatus] {
        if AppDistribution.supportsDirectQueue {
            return CaptureStatus.allCases.filter { $0 != .draft }
        }
        return [.saved, .archived]
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("想法收件箱")
                    .font(.headline)

                Text("\(displayedCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .accessibilityLabel("\(displayedCount) 条想法")

                Spacer()

                TextField(
                    AppDistribution.supportsDirectQueue ? "搜索内容、来源或目标" : "搜索内容",
                    text: $store.searchText
                )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .accessibilityLabel("搜索想法")

                Button(action: onUndoArchive) {
                    Label("撤销归档", systemImage: "arrow.uturn.backward")
                }
                .disabled(!canUndoArchive || store.isQueueing)
                .help("撤销最近一次归档")
                .accessibilityLabel("撤销最近一次归档")

                if AppDistribution.supportsDirectQueue {
                    Button {
                        Task { @MainActor in
                            await store.refreshThreads()
                        }
                    } label: {
                        if store.isLoadingContexts {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.isLoadingContexts || store.isQueueing)
                    .help("刷新 Codex 任务")
                    .accessibilityLabel(store.isLoadingContexts ? "正在刷新 Codex 任务" : "刷新 Codex 任务")
                }
            }

            HStack(spacing: 10) {
                Text("筛选")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if AppDistribution.supportsDirectQueue {
                    RouteFilterPicker(
                        label: "来源",
                        selection: $sourceFilter,
                        options: sourceFilterOptions
                    )

                    RouteFilterPicker(
                        label: "目标",
                        selection: $targetFilter,
                        options: targetFilterOptions
                    )
                }

                Picker("状态", selection: $store.statusFilter) {
                    Text("全部状态")
                        .tag(nil as CaptureStatus?)
                    ForEach(availableStatuses, id: \.self) { status in
                        Text(status.displayName)
                            .tag(Optional(status))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityLabel("按状态筛选")

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct RouteFilterPicker: View {
    let label: String
    @Binding var selection: RouteFilter
    let options: [RouteFilterOption]

    var body: some View {
        Picker(label, selection: $selection) {
            Text("全部\(label)")
                .tag(RouteFilter.all)

            ForEach(options) { option in
                Text(option.title)
                    .lineLimit(1)
                    .tag(option.filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 180)
        .help("按\(label)筛选")
        .accessibilityLabel("按\(label)筛选")
    }
}

private struct InboxCaptureList: View {
    let captures: [CaptureItem]
    @Binding var selection: UUID?
    let onQueue: (UUID) -> Void
    let onArchive: (UUID) -> Void
    let onRestore: (UUID) -> Void
    let onCopyAndOpenCodex: (UUID) -> Void

    var body: some View {
        if captures.isEmpty {
            ContentUnavailableView(
                "没有匹配的想法",
                systemImage: "tray",
                description: Text("调整搜索或筛选条件，或用 ⌃⌥Space 记录一条新想法。")
            )
        } else {
            List(captures, selection: $selection) { capture in
                CaptureRow(capture: capture)
                    .tag(capture.id)
                    .contextMenu {
                        captureActions(for: capture)
                    }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("想法列表")
        }
    }

    @ViewBuilder
    private func captureActions(for capture: CaptureItem) -> some View {
        if AppDistribution.supportsDirectQueue, capture.status.canQueue {
            Button(capture.status.queueActionTitle) {
                onQueue(capture.id)
            }
        }

        Button("复制并打开 Codex") {
            onCopyAndOpenCodex(capture.id)
        }

        if capture.status != .archived {
            Divider()
            Button("归档") {
                onArchive(capture.id)
            }
        } else {
            Divider()
            Button("恢复到原状态") {
                onRestore(capture.id)
            }
        }
    }
}

private struct CaptureRow: View {
    let capture: CaptureItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(capture.text.isEmpty ? "空想法" : capture.text)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                Spacer(minLength: 4)

                CaptureStatusBadge(status: capture.status)
            }

            HStack(spacing: 4) {
                if AppDistribution.supportsDirectQueue {
                    Image(systemName: "arrow.triangle.branch")
                        .accessibilityHidden(true)
                    Text(capture.routeDescription)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(capture.updatedAt, format: .dateTime.month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppDistribution.supportsDirectQueue
                ? "\(capture.status.displayName)，\(capture.routeDescription)，\(capture.text)"
                : "\(capture.status.displayName)，\(capture.text)"
        )
    }
}

private struct CaptureDetailView: View {
    let capture: CaptureItem
    let contexts: [WorkContextItem]
    let isBusy: Bool
    let onTextChange: @MainActor @Sendable (String) -> Bool
    let onRouteChange: @MainActor @Sendable (String?, String?) -> Bool
    let onQueue: () -> Void
    let onArchive: () -> Void
    let onRestore: () -> Void
    let onCopyAndOpenCodex: (String) -> Void

    @State private var editedText: String

    init(
        capture: CaptureItem,
        contexts: [WorkContextItem],
        isBusy: Bool,
        onTextChange: @escaping @MainActor @Sendable (String) -> Bool,
        onRouteChange: @escaping @MainActor @Sendable (String?, String?) -> Bool,
        onQueue: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onCopyAndOpenCodex: @escaping (String) -> Void
    ) {
        self.capture = capture
        self.contexts = contexts
        self.isBusy = isBusy
        self.onTextChange = onTextChange
        self.onRouteChange = onRouteChange
        self.onQueue = onQueue
        self.onArchive = onArchive
        self.onRestore = onRestore
        self.onCopyAndOpenCodex = onCopyAndOpenCodex
        _editedText = State(initialValue: capture.text)
    }

    private var canEdit: Bool {
        !isBusy && capture.status.canEditText
    }

    private var canEditRoute: Bool {
        !isBusy && capture.status.canEditRoute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CaptureDetailHeader(capture: capture)

            if AppDistribution.supportsDirectQueue {
                CaptureRouteEditor(
                    capture: capture,
                    contexts: contexts,
                    isEditable: canEditRoute,
                    onSelectSource: { sourceThreadID in
                        guard commitEditedText() else { return }
                        _ = onRouteChange(sourceThreadID, capture.targetThreadID)
                    },
                    onSelectTarget: { targetThreadID in
                        guard commitEditedText() else { return }
                        _ = onRouteChange(capture.sourceThreadID, targetThreadID)
                    }
                )
            }

            TextEditor(text: $editedText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                }
                .disabled(!canEdit)
                .accessibilityLabel("编辑想法内容")
                .accessibilityHint(canEdit ? "修改会自动保存" : "当前状态下原文为只读")

            if let lastError = capture.lastError, !lastError.isEmpty {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .combine)
            }

            HStack(spacing: 8) {
                Button("复制并打开 Codex") {
                    onCopyAndOpenCodex(editedText)
                }
                    .accessibilityLabel("复制想法并打开 Codex")

                Spacer()

                if capture.status != .archived {
                    Button("归档") {
                        guard commitEditedText() else { return }
                        onArchive()
                    }
                        .disabled(isBusy)
                        .accessibilityLabel("归档这条想法")
                } else {
                    Button("恢复到原状态") {
                        onRestore()
                    }
                    .disabled(isBusy)
                    .accessibilityLabel("恢复这条已归档想法")
                }

                if AppDistribution.supportsDirectQueue, capture.status.canQueue {
                    Button(capture.status.queueActionTitle) {
                        guard commitEditedText() else { return }
                        onQueue()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                        .accessibilityLabel(capture.status.queueActionTitle)
                } else if capture.status == .queueing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在排到 Codex")
                }
            }
        }
        .padding(18)
        .task(id: editedText) {
            guard canEdit, editedText != capture.text else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitEditedText()
        }
        .onChange(of: capture.text) { _, newValue in
            guard newValue != editedText else { return }
            editedText = newValue
        }
        .onDisappear {
            commitEditedText()
        }
    }

    @discardableResult
    private func commitEditedText() -> Bool {
        guard canEdit, editedText != capture.text else { return true }
        let didSave = onTextChange(editedText)
        if !didSave {
            editedText = capture.text
        }
        return didSave
    }
}

private struct CaptureDetailHeader: View {
    let capture: CaptureItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                CaptureStatusBadge(status: capture.status)
                Spacer()
                Text("更新于 ") + Text(capture.updatedAt, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

        }
    }
}

private struct CaptureRouteEditor: View {
    let capture: CaptureItem
    let contexts: [WorkContextItem]
    let isEditable: Bool
    let onSelectSource: (String?) -> Void
    let onSelectTarget: (String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            CaptureRoutePicker(
                label: "来源任务",
                selectedThreadID: capture.sourceThreadID,
                selectedTitle: capture.sourceTitle,
                contexts: contexts,
                isEditable: isEditable,
                onSelect: onSelectSource
            )

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            CaptureRoutePicker(
                label: "目标任务",
                selectedThreadID: capture.targetThreadID,
                selectedTitle: capture.targetTitle,
                contexts: contexts,
                isEditable: isEditable,
                onSelect: onSelectTarget
            )
        }
    }
}

private struct CaptureRoutePicker: View {
    let label: String
    let selectedThreadID: String?
    let selectedTitle: String?
    let contexts: [WorkContextItem]
    let isEditable: Bool
    let onSelect: (String?) -> Void

    private var selectedContext: WorkContextItem? {
        contexts.first { $0.id == selectedThreadID }
    }

    private var displayTitle: String {
        selectedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? selectedContext?.title
            ?? "未关联"
    }

    private var metadata: String {
        guard let selectedThreadID else { return "未选择任务" }
        let projectLabel = selectedContext?.projectDirectory
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "无项目目录"
        let availability = selectedContext?.isAvailable == false ? " · 已失效" : ""
        return "\(projectLabel) · \(selectedThreadID.prefix(8))\(availability)"
    }

    var body: some View {
        Menu {
            Button("未关联") {
                onSelect(nil)
            }
            Divider()
            ForEach(contexts.filter(\.isAvailable)) { context in
                Button {
                    onSelect(context.id)
                } label: {
                    HStack {
                        Text(context.menuDisplayTitle)
                        if context.id == selectedThreadID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .disabled(!isEditable)
        .accessibilityLabel(label)
        .accessibilityValue("\(displayTitle)，\(metadata)")
    }
}

private struct CaptureStatusBadge: View {
    let status: CaptureStatus

    var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.12), in: .capsule)
            .fixedSize()
    }
}

private extension CaptureItem {
    var routeDescription: String {
        switch (routeLabel(title: sourceTitle, id: sourceThreadID), routeLabel(title: targetTitle, id: targetThreadID)) {
        case let (source?, target?):
            return source == target ? source : "\(source) → \(target)"
        case let (source?, nil):
            return source
        case let (nil, target?):
            return "目标：\(target)"
        case (nil, nil):
            return "未关联 Codex 任务"
        }
    }

    private func routeLabel(title: String?, id: String?) -> String? {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard let id, !id.isEmpty else { return normalizedTitle }
        return "\(normalizedTitle ?? "未命名任务") · \(id.prefix(8))"
    }
}

private extension CaptureStatus {
    var canEditText: Bool {
        return switch self {
        case .saved, .failed:
            true
        case .draft, .queueing, .queued, .unknown, .archived:
            false
        }
    }

    var canEditRoute: Bool {
        self == .saved || self == .failed
    }

    var displayName: String {
        switch self {
        case .draft: "草稿"
        case .saved: "已保存"
        case .queueing: "排队中"
        case .queued: "已排队"
        case .failed: "失败"
        case .unknown: "待确认"
        case .archived: "已归档"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil"
        case .saved: "tray.and.arrow.down"
        case .queueing: "clock.arrow.circlepath"
        case .queued: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .archived: "archivebox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .draft, .saved: .secondary
        case .queueing: .blue
        case .queued: .green
        case .failed: .red
        case .unknown: .orange
        case .archived: .secondary
        }
    }

    var canQueue: Bool {
        switch self {
        case .draft, .saved, .failed:
            true
        case .queueing, .queued, .unknown, .archived:
            false
        }
    }

    var queueActionTitle: String {
        self == .failed ? "重试排队" : "排到 Codex"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
