import Foundation

/// Only note content crosses devices. Task caches and CLI diagnostics stay local.
public struct SharedIdea: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool

    public init(id: UUID, text: String, createdAt: Date, updatedAt: Date, archived: Bool) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }
}

public struct IdeaRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let parents: [UUID]
    public let idea: SharedIdea

    public init(id: UUID = UUID(), deviceID: UUID, parents: [UUID], idea: SharedIdea) {
        self.id = id
        self.deviceID = deviceID
        self.parents = parents
        self.idea = idea
    }
}

public enum IdeaSyncError: Error {
    case invalidRevision
    case inconsistentRevision
    case unsupportedJournal
    case unavailableAccount
    case oversizedNote
    case synchronizationInProgress
    case protectedLocalNote
    case accountChanged
}

/// An append-only journal: retries are safe, and concurrent branches retain both texts.
public struct IdeaSyncJournal: Codable, Sendable {
    public private(set) var version = 1
    public let deviceID: UUID
    public private(set) var revisions: [IdeaRevision] = []
    public private(set) var lastApplied: [SharedIdea] = []
    public private(set) var accountID: String?

    public init(deviceID: UUID = UUID()) { self.deviceID = deviceID }

    public mutating func merge(_ incoming: [IdeaRevision]) throws {
        guard version == 1 else { throw IdeaSyncError.unsupportedJournal }
        var combined = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in incoming {
            guard !revision.idea.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  revision.idea.createdAt.timeIntervalSince1970.isFinite,
                  revision.idea.updatedAt.timeIntervalSince1970.isFinite,
                  !revision.parents.contains(revision.id) else { throw IdeaSyncError.invalidRevision }
            if let existing = combined[revision.id], existing != revision {
                throw IdeaSyncError.inconsistentRevision
            }
            combined[revision.id] = revision
        }
        // Reject cycles and cross-note parents before mutating the journal.
        var visited = Set<UUID>()
        var visiting = Set<UUID>()
        func visit(_ id: UUID) throws {
            guard !visited.contains(id) else { return }
            guard visiting.insert(id).inserted else { throw IdeaSyncError.invalidRevision }
            if let revision = combined[id] {
                for parent in revision.parents {
                    guard let ancestor = combined[parent], ancestor.idea.id == revision.idea.id else {
                        throw IdeaSyncError.invalidRevision
                    }
                    try visit(parent)
                }
            }
            visiting.remove(id)
            visited.insert(id)
        }
        for id in combined.keys { try visit(id) }
        revisions = combined.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public mutating func stageLocalChanges(_ notes: [SharedIdea]) throws {
        let baseline = Dictionary(uniqueKeysWithValues: lastApplied.map { ($0.id, $0) })
        for note in notes where baseline[note.id] != note {
            // An unchanged projection after a failed sync must not create another revision.
            if projection.first(where: { $0.id == note.id }) == note { continue }
            let parents = heads(for: note.id).map(\.id)
            try merge([IdeaRevision(deviceID: deviceID, parents: parents, idea: note)])
        }
    }

    public var projection: [SharedIdea] {
        let ids = Set(revisions.map { $0.idea.id })
        return ids.flatMap { id -> [SharedIdea] in
            let branches = heads(for: id).sorted { $0.id.uuidString < $1.id.uuidString }
            var seen: [SharedIdea] = []
            return branches.enumerated().compactMap { index, revision in
                var note = revision.idea
                // Equivalent concurrent saves need only one visible note.
                if seen.contains(where: { $0.text == note.text && $0.archived == note.archived }) { return nil }
                seen.append(note)
                if index > 0 { note.id = revision.id }
                return note
            }
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public mutating func acknowledgeApplied(_ notes: [SharedIdea]) { lastApplied = notes }

    public mutating func bindAccount(_ id: String) throws {
        guard !id.isEmpty, accountID == nil || accountID == id else { throw IdeaSyncError.accountChanged }
        accountID = id
    }

    private func heads(for id: UUID) -> [IdeaRevision] {
        let family = revisions.filter { $0.idea.id == id }
        let superseded = Set(family.flatMap(\.parents))
        return family.filter { !superseded.contains($0.id) }
    }
}

@MainActor
public protocol IdeaRevisionTransport {
    func accountIdentifier() async throws -> String
    func fetchRevisions() async throws -> [IdeaRevision]
    func upload(_ revisions: [IdeaRevision]) async throws
}

/// Disk writes happen before network calls. A failed fetch/upload leaves a durable outbox.
@MainActor
public final class IdeaSyncSession {
    public private(set) var journal: IdeaSyncJournal
    private let journalURL: URL
    private let transport: any IdeaRevisionTransport
    private var isSynchronizing = false

    public init(journalURL: URL, transport: any IdeaRevisionTransport) throws {
        self.journalURL = journalURL
        self.transport = transport
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(IdeaSyncJournal.self, from: Data(contentsOf: journalURL))
            guard journal.version == 1 else { throw IdeaSyncError.unsupportedJournal }
            var checked = IdeaSyncJournal(deviceID: journal.deviceID)
            try checked.merge(journal.revisions)
            guard Set(journal.lastApplied.map(\.id)).count == journal.lastApplied.count else {
                throw IdeaSyncError.invalidRevision
            }
            checked.acknowledgeApplied(journal.lastApplied)
            if let accountID = journal.accountID { try checked.bindAccount(accountID) }
            journal = checked
        } else {
            journal = IdeaSyncJournal()
        }
    }

    public func synchronize(readLocal: () -> [SharedIdea], apply: ([SharedIdea]) throws -> Void) async throws {
        guard !isSynchronizing else { throw IdeaSyncError.synchronizationInProgress }
        isSynchronizing = true
        defer { isSynchronizing = false }
        try journal.stageLocalChanges(readLocal())
        try persist()
        let accountID = try await transport.accountIdentifier()
        try journal.bindAccount(accountID)
        try persist()
        let remote = try await transport.fetchRevisions()
        guard try await transport.accountIdentifier() == accountID else { throw IdeaSyncError.accountChanged }
        // Include edits made while the fetch was suspended, before introducing remote branches.
        try journal.stageLocalChanges(readLocal())
        try journal.merge(remote)
        try persist()
        let projection = journal.projection
        try apply(projection)
        journal.acknowledgeApplied(projection)
        try persist()
        let known = Set(remote.map(\.id))
        guard try await transport.accountIdentifier() == accountID else { throw IdeaSyncError.accountChanged }
        try await transport.upload(journal.revisions.filter { !known.contains($0.id) })
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }
}

