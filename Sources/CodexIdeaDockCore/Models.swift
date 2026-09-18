import Foundation
import SwiftData

public enum CaptureStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case draft
    case saved
    case queueing
    case queued
    case failed
    case unknown
    case archived
}

public enum DockNotificationKind: String, Codable, Hashable, Sendable {
    case success
    case warning
    case error
}

public struct DockNotification: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: DockNotificationKind
    public let message: String

    public init(
        id: UUID = UUID(),
        kind: DockNotificationKind,
        message: String
    ) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

public struct WorkContextItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var projectDirectory: String?
    public var projectID: String?
    public var isPinned: Bool
    public var isAvailable: Bool
    public var recency: Date

    public init(
        id: String,
        title: String,
        projectDirectory: String?,
        projectID: String?,
        isPinned: Bool,
        isAvailable: Bool = true,
        recency: Date
    ) {
        self.id = id
        self.title = title
        self.projectDirectory = projectDirectory
        self.projectID = projectID
        self.isPinned = isPinned
        self.isAvailable = isAvailable
        self.recency = recency
    }
}

public struct CaptureItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var sourceThreadID: String?
    public var targetThreadID: String?
    public var sourceTitle: String?
    public var targetTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: CaptureStatus
    public var statusBeforeArchive: CaptureStatus?
    public var lastError: String?

    public init(
        id: UUID,
        text: String,
        sourceThreadID: String?,
        targetThreadID: String?,
        sourceTitle: String?,
        targetTitle: String?,
        createdAt: Date,
        updatedAt: Date,
        status: CaptureStatus,
        statusBeforeArchive: CaptureStatus?,
        lastError: String?
    ) {
        self.id = id
        self.text = text
        self.sourceThreadID = sourceThreadID
        self.targetThreadID = targetThreadID
        self.sourceTitle = sourceTitle
        self.targetTitle = targetTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.statusBeforeArchive = statusBeforeArchive
        self.lastError = lastError
    }
}

public enum QueueDeliveryOutcome: Sendable, Equatable {
    case queued(exitCode: Int)
    case failed(exitCode: Int?, message: String)
    case unknown(message: String)
}

enum QueueDeliveryDiagnostic: String, CaseIterable, Sendable {
    case emptyMessage = "The message is empty."
    case emptyTarget = "The target task identifier is empty."
    case invalidTarget = "The target task identifier is not a UUID."
    case cliUnavailable = "Codex CLI is unavailable."
    case queueUnsupported = "This Codex CLI does not support queue."
    case targetUnavailable = "The target Codex task is unavailable."
    case permissionDenied = "Codex does not have permission to queue this message."
    case launchFailed = "Codex could not be launched."
    case queueFailed = "Codex could not queue the message."
    case confirmationTimedOut = "Codex did not confirm whether the message was queued before the timeout."
    case resultUnclear = "Codex exited without confirming whether the message was queued."

    static func allowlistedSummary(
        _ message: String,
        fallback: QueueDeliveryDiagnostic
    ) -> String {
        let compacted = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return QueueDeliveryDiagnostic(rawValue: compacted)?.rawValue ?? fallback.rawValue
    }
}

@Model
public final class WorkContext {
    @Attribute(.unique) public var threadID: String
    public var title: String
    public var projectDirectory: String?
    public var projectID: String?
    public var isPinned: Bool
    public var isAvailable: Bool = true
    public var recency: Date
    public var lastSelectedAt: Date?

    public init(
        threadID: String,
        title: String,
        projectDirectory: String? = nil,
        projectID: String? = nil,
        isPinned: Bool = false,
        isAvailable: Bool = true,
        recency: Date = .distantPast,
        lastSelectedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.title = title
        self.projectDirectory = projectDirectory
        self.projectID = projectID
        self.isPinned = isPinned
        self.isAvailable = isAvailable
        self.recency = recency
        self.lastSelectedAt = lastSelectedAt
    }

    public var item: WorkContextItem {
        WorkContextItem(
            id: threadID,
            title: title,
            projectDirectory: projectDirectory,
            projectID: projectID,
            isPinned: isPinned,
            isAvailable: isAvailable,
            recency: recency
        )
    }
}

@Model
public final class Capture {
    @Attribute(.unique) public var id: UUID
    public var text: String
    public var sourceThreadID: String?
    public var targetThreadID: String?
    public var sourceTitle: String?
    public var targetTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var statusRawValue: String
    public var statusBeforeArchiveRawValue: String?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        text: String,
        sourceThreadID: String? = nil,
        targetThreadID: String? = nil,
        sourceTitle: String? = nil,
        targetTitle: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        status: CaptureStatus = .draft,
        statusBeforeArchive: CaptureStatus? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceThreadID = sourceThreadID
        self.targetThreadID = targetThreadID
        self.sourceTitle = sourceTitle
        self.targetTitle = targetTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.statusRawValue = status.rawValue
        self.statusBeforeArchiveRawValue = statusBeforeArchive?.rawValue
        self.lastError = lastError
    }

    public var status: CaptureStatus {
        get { CaptureStatus(rawValue: statusRawValue) ?? .unknown }
        set { statusRawValue = newValue.rawValue }
    }

    public var statusBeforeArchive: CaptureStatus? {
        get {
            guard let statusBeforeArchiveRawValue else { return nil }
            return CaptureStatus(rawValue: statusBeforeArchiveRawValue) ?? .unknown
        }
        set { statusBeforeArchiveRawValue = newValue?.rawValue }
    }

    public var item: CaptureItem {
        CaptureItem(
            id: id,
            text: text,
            sourceThreadID: sourceThreadID,
            targetThreadID: targetThreadID,
            sourceTitle: sourceTitle,
            targetTitle: targetTitle,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: status,
            statusBeforeArchive: statusBeforeArchive,
            lastError: lastError
        )
    }
}

@Model
public final class DeliveryAttempt {
    @Attribute(.unique) public var id: UUID
    public var captureID: UUID
    public var method: String
    public var attemptedAt: Date
    public var exitCode: Int?
    public var errorSummary: String?

    public init(
        id: UUID = UUID(),
        captureID: UUID,
        method: String,
        attemptedAt: Date = .now,
        exitCode: Int? = nil,
        errorSummary: String? = nil
    ) {
        self.id = id
        self.captureID = captureID
        self.method = method
        self.attemptedAt = attemptedAt
        self.exitCode = exitCode
        self.errorSummary = errorSummary
    }
}

public enum IdeaDockPersistence {
    public static var schema: Schema {
        Schema([
            WorkContext.self,
            Capture.self,
            DeliveryAttempt.self
        ])
    }

    public static func makeDefaultContainer() throws -> ModelContainer {
        let schema = schema
        // Compatibility identifier: changing this requires migrating the existing local store.
        let configuration = ModelConfiguration(
            "CodexIdeaDock",
            schema: schema,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    public static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = schema
        let configuration = ModelConfiguration(
            "CodexIdeaDockTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
