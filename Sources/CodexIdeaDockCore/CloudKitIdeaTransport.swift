import CloudKit
import Foundation

/// Explicit private database; constructing this transport never opts a user into sync.
@MainActor
public final class CloudKitIdeaTransport: IdeaRevisionTransport {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let recordType = "RerouteIdeaRevision"
    private var boundAccountID: String?
    private let zone = CKRecordZone(zoneName: "RerouteIdeas")

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw IdeaSyncError.unavailableAccount }
        let id = try await container.userRecordID().recordName
        guard boundAccountID == nil || boundAccountID == id else { throw IdeaSyncError.accountChanged }
        boundAccountID = id
        return id
    }

    public func fetchRevisions() async throws -> [IdeaRevision] {
        _ = try await accountIdentifier()
        var revisions: [IdeaRevision] = []
        // Zone changes can read an empty new zone before its record type exists.
        // A query would fail before the first local revision could be uploaded.
        _ = try await database.save(zone)
        var token: CKServerChangeToken?
        repeat {
            _ = try await accountIdentifier()
            let page = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
            for result in page.modificationResultsByID.values {
                let record = try result.get().record
                guard record.recordType == recordType else { continue }
                guard let data = record.encryptedValues["payload"] as? Data else { throw IdeaSyncError.invalidRevision }
                let revision = try JSONDecoder().decode(IdeaRevision.self, from: data)
                guard record.recordID.recordName == revision.id.uuidString else { throw IdeaSyncError.invalidRevision }
                revisions.append(revision)
            }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        return revisions
    }

    public func upload(_ revisions: [IdeaRevision]) async throws {
        // Publish ancestors first so an interrupted upload cannot leave a child
        // on the server whose parent was still only in the local outbox.
        _ = try await accountIdentifier()
        _ = try await database.save(zone)
        let pending = Dictionary(revisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [IdeaRevision] = []
        var visited = Set<UUID>()
        var visiting = Set<UUID>()
        func visit(_ revision: IdeaRevision) throws {
            guard !visited.contains(revision.id) else { return }
            guard visiting.insert(revision.id).inserted else { throw IdeaSyncError.invalidRevision }
            for parent in revision.parents {
                if let ancestor = pending[parent] { try visit(ancestor) }
            }
            visiting.remove(revision.id)
            visited.insert(revision.id)
            ordered.append(revision)
        }
        for revision in revisions { try visit(revision) }
        for revision in ordered {
            _ = try await accountIdentifier()
            let data = try JSONEncoder().encode(revision)
            guard data.count < 800_000 else { throw IdeaSyncError.oversizedNote }
            let recordID = CKRecord.ID(recordName: revision.id.uuidString, zoneID: zone.zoneID)
            do {
                let existing = try await database.record(for: recordID)
                guard let payload = existing.encryptedValues["payload"] as? Data,
                      try JSONDecoder().decode(IdeaRevision.self, from: payload) == revision else {
                    throw IdeaSyncError.inconsistentRevision
                }
                continue
            } catch let error as CKError where error.code == .unknownItem {
                // Immutable record IDs make interrupted upload retries idempotent.
            }
            let record = CKRecord(recordType: recordType, recordID: recordID)
            record.encryptedValues["payload"] = data as CKRecordValue
            let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
            guard let saved = result.saveResults[recordID] else { throw IdeaSyncError.invalidRevision }
            _ = try saved.get()
        }
    }
}

/// Private-database transport for the explicit phone -> Mac continuation workflow.
/// The iCloud account is the pairing boundary: no public records are used.
@MainActor
public final class CloudKitRemoteTransport: RemoteContinuationTransport {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zone = CKRecordZone(zoneName: "FlowCueRemote")
    private let threadType = "FlowCueRemoteThread"
    private let commandType = "FlowCueRemoteCommand"
    private let resultType = "FlowCueRemoteResult"

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func fetchThreads() async throws -> [RemoteThreadSnapshot] {
        try await records(ofType: threadType).compactMap(decode).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func publishThreads(_ threads: [RemoteThreadSnapshot]) async throws {
        for thread in threads {
            try await save(thread, recordName: "thread-\(thread.id)", type: threadType)
        }
    }

    public func sendCommand(_ command: RemoteCommand) async throws {
        try await save(command, recordName: "command-\(command.id.uuidString)", type: commandType)
    }

    public func fetchCommands(executorID: UUID) async throws -> [RemoteCommand] {
        try await records(ofType: commandType)
            .compactMap(decode)
            .filter { $0.executorID == executorID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func publishResult(_ result: RemoteCommandResult) async throws {
        try await save(result, recordName: "result-\(result.id.uuidString)", type: resultType)
    }

    public func fetchResults(ids: [UUID]) async throws -> [RemoteCommandResult] {
        var results: [RemoteCommandResult] = []
        for id in ids {
            let recordID = CKRecord.ID(recordName: "result-\(id.uuidString)", zoneID: zone.zoneID)
            guard let record = try? await database.record(for: recordID),
                  let payload = record.encryptedValues["payload"] as? Data,
                  let result = try? JSONDecoder().decode(RemoteCommandResult.self, from: payload) else { continue }
            results.append(result)
        }
        return results
    }

    private func save<T: Encodable>(_ value: T, recordName: String, type: String) async throws {
        _ = try await accountIdentifier()
        _ = try await database.save(zone)
        let data = try JSONEncoder().encode(value)
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
        if let existing = try? await database.record(for: recordID) {
            existing.encryptedValues["payload"] = data as CKRecordValue
            _ = try await database.modifyRecords(saving: [existing], deleting: [], savePolicy: .changedKeys)
        } else {
            let record = CKRecord(recordType: type, recordID: recordID)
            record.encryptedValues["payload"] = data as CKRecordValue
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        }
    }

    private func records(ofType type: String) async throws -> [CKRecord] {
        _ = try await accountIdentifier()
        _ = try await database.save(zone)
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        repeat {
            _ = try await accountIdentifier()
            let page = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
            for result in page.modificationResultsByID.values {
                if let record = try? result.get().record, record.recordType == type { records.append(record) }
            }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        return records
    }

    private func decode<T: Decodable>(_ record: CKRecord) -> T? {
        guard let payload = record.encryptedValues["payload"] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: payload)
    }

    private func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw IdeaSyncError.unavailableAccount }
        return try await container.userRecordID().recordName
    }
}
