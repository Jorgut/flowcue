import CloudKit
import CryptoKit
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

/// CloudKit transport for the existing encrypted remote envelopes.
/// A claim is created before dispatch and is never overwritten or reissued.
@MainActor
public final class CloudKitChatMailbox {
    public enum Record: String {
        case request, claim, receipt
    }

    private let database: CKDatabase
    private let zone: CKRecordZone
    private var requestChangeToken: CKServerChangeToken?
    private var pending: [UUID: (payload: Data, date: Date)] = [:]

    #if DEBUG
    public convenience init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let rawID = environment["FLOWCUE_TEST_CLOUDKIT_CHAT_ZONE"],
              let id = UUID(uuidString: rawID) else { return nil }
        self.init(zoneName: "FlowCueChatTest-\(id.uuidString)")
    }
    #endif

    public static var enabledInBundle: Bool {
        let enabled = Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitChatEnabled")
        return enabled as? Bool == true || enabled as? String == "YES"
    }

    public static func configured(for macID: String) -> CloudKitChatMailbox? {
        guard enabledInBundle, let id = UUID(uuidString: macID) else { return nil }
        return CloudKitChatMailbox(zoneName: "FlowCueChat-\(id.uuidString)")
    }

    private init?(zoneName: String) {
        guard let container = Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String else { return nil }
        database = CKContainer(identifier: container).privateCloudDatabase
        zone = CKRecordZone(zoneName: zoneName)
    }

    public func prepare() async throws {
        _ = try await database.save(zone)
    }

    public func waitForZone() async throws {
        for _ in 0..<3 {
            do {
                _ = try await database.recordZone(for: zone.zoneID)
                return
            } catch let error as CKError where error.code == .zoneNotFound {
                try await Task.sleep(for: .seconds(1))
            }
        }
        _ = try await database.recordZone(for: zone.zoneID)
    }

    #if DEBUG
    public func deleteTestZone() async throws {
        _ = try await database.deleteRecordZone(withID: zone.zoneID)
    }
    #endif

    public func read(_ kind: Record, id: UUID) async throws -> Data? {
        do {
            let record = try await database.record(for: recordID(kind, id: id))
            return record.encryptedValues["payload"] as? Data
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func create(_ kind: Record, id: UUID, payload: Data) async throws {
        let record = CKRecord(recordType: "RerouteProbe", recordID: recordID(kind, id: id))
        record.encryptedValues["payload"] = payload as CKRecordValue
        let results = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged
        )
        guard let result = results.saveResults[record.recordID] else { throw CocoaError(.fileWriteUnknown) }
        _ = try result.get()
    }

    public func claim(_ id: UUID) async throws -> Bool {
        do {
            try await create(.claim, id: id, payload: Data([1]))
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false
        }
    }

    public func pendingRequests(excluding seen: Set<UUID>, newerThan cutoff: Date) async throws -> [(UUID, Data)] {
        pending = pending.filter { !seen.contains($0.key) && $0.value.date >= cutoff }
        do {
            while true {
                let page = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: requestChangeToken)
                for (recordID, result) in page.modificationResultsByID {
                    guard let id = requestID(for: recordID), !seen.contains(id) else { continue }
                    let record = try result.get().record
                    guard let date = record.creationDate, date >= cutoff,
                          let payload = record.encryptedValues["payload"] as? Data else { continue }
                    pending[id] = (payload, date)
                }
                for deletion in page.deletions {
                    if let id = requestID(for: deletion.recordID) { pending.removeValue(forKey: id) }
                }
                requestChangeToken = page.changeToken
                if !page.moreComing { break }
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            requestChangeToken = nil
            pending.removeAll()
            return []
        }
        return pending.sorted {
            if $0.value.date == $1.value.date { return $0.key.uuidString < $1.key.uuidString }
            return $0.value.date < $1.value.date
        }.map { ($0.key, $0.value.payload) }
    }

    private func requestID(for recordID: CKRecord.ID) -> UUID? {
        let prefix = "request-"
        let name = recordID.recordName
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    private func recordID(_ kind: Record, id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(kind.rawValue)-\(id.uuidString)", zoneID: zone.zoneID)
    }
}

#if DEBUG
@MainActor
enum FlowCueCloudKitProbe {
    static var runID: UUID? {
        let prefix = "--flowcue-cloudkit-probe="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
            .flatMap { UUID(uuidString: String($0.dropFirst(prefix.count))) }
    }

    static func run(_ id: UUID) async -> Bool {
        guard let containerID = Bundle.main.object(forInfoDictionaryKey: "FlowCueCloudKitContainer") as? String else {
            print("CloudKit probe missing container")
            return false
        }
        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "FlowCueRemoteProbe-\(id.uuidString)")
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started + .seconds(150)
        let arguments = ProcessInfo.processInfo.arguments
        let isDSH = arguments.contains("--flowcue-cloudkit-probe-dsh")
        let key = ProcessInfo.processInfo.environment["FLOWCUE_CK_DSH_KEY"]
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }

        func signal(_ message: String) {
            FileHandle.standardOutput.write(Data("\(message)\n".utf8))
        }

        func recordID(_ name: String) -> CKRecord.ID {
            CKRecord.ID(recordName: name, zoneID: zone.zoneID)
        }

        func write(_ name: String, payload: String) async throws {
            let record = CKRecord(recordType: "RerouteProbe", recordID: recordID(name))
            var bytes = Data(payload.utf8)
            if let key {
                let box = try AES.GCM.seal(bytes, using: key, authenticating: Data("\(id.uuidString)/\(name)".utf8))
                guard let combined = box.combined else { throw CocoaError(.fileWriteUnknown) }
                bytes = combined
            }
            record.encryptedValues["payload"] = bytes as CKRecordValue
            _ = try await database.save(record)
        }

        func waitForRecord(_ name: String) async throws -> String {
            while clock.now < deadline {
                do {
                    let record = try await database.record(for: recordID(name))
                    guard var payload = record.encryptedValues["payload"] as? Data else { throw CocoaError(.fileReadCorruptFile) }
                    if let key {
                        let box = try AES.GCM.SealedBox(combined: payload)
                        payload = try AES.GCM.open(box, using: key, authenticating: Data("\(id.uuidString)/\(name)".utf8))
                    }
                    guard let decoded = String(data: payload, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                    return decoded
                } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            throw URLError(.timedOut)
        }

        do {
            signal("CloudKit probe starting")
            let status = try await container.accountStatus()
            signal("CloudKit probe account status=\(status.rawValue)")
            guard status == .available else { return false }
            guard !isDSH || key != nil else {
                signal("CloudKit probe missing test encryption key")
                return false
            }
            if arguments.contains("--flowcue-cloudkit-probe-cleanup") {
                _ = try await database.deleteRecordZone(withID: zone.zoneID)
                print("CloudKit probe zone removed")
            } else if arguments.contains("--flowcue-cloudkit-probe-read-receipt") {
                guard try await waitForRecord("receipt") == "accepted:\(id.uuidString)" else { return false }
                if isDSH, try await waitForRecord("reply") != "CK-CHAT-OK" { return false }
                print("CloudKit probe receipt restored elapsed=\(started.duration(to: clock.now))")
            } else if isDSH, arguments.contains("--flowcue-cloudkit-probe-publish-reply") {
                #if os(macOS)
                guard try await waitForRecord("claim") == "claimed:\(id.uuidString)",
                      try await waitForRecord("receipt") == "accepted:\(id.uuidString)",
                      readLine() == "CK-CHAT-OK" else { return false }
                try await write("reply", payload: "CK-CHAT-OK")
                signal("CloudKit probe delayed DSH reply saved")
                #else
                return false
                #endif
            } else {
                #if os(macOS)
                _ = try await database.save(zone)
                let history = isDSH ? readLine() : "history:\(id.uuidString)"
                guard let history, !history.isEmpty else { return false }
                try await write("history", payload: history)
                signal("CloudKit probe Mac history saved elapsed=\(started.duration(to: clock.now))")
                guard try await waitForRecord("command") == "command:\(id.uuidString)" else { return false }
                if isDSH {
                    try await write("claim", payload: "claimed:\(id.uuidString)")
                    signal("CloudKit probe DSH command ready")
                    guard readLine() == "accepted" else { return false }
                }
                try await write("receipt", payload: "accepted:\(id.uuidString)")
                signal("CloudKit probe Mac command received and receipt saved elapsed=\(started.duration(to: clock.now))")
                if isDSH {
                    guard readLine() == "CK-CHAT-OK" else { return false }
                    try await write("reply", payload: "CK-CHAT-OK")
                }
                #else
                let history = try await waitForRecord("history")
                guard isDSH ? history.contains("HISTORY-OK") : history == "history:\(id.uuidString)" else { return false }
                signal("CloudKit probe iPhone history read elapsed=\(started.duration(to: clock.now))")
                try await write("command", payload: "command:\(id.uuidString)")
                guard try await waitForRecord("receipt") == "accepted:\(id.uuidString)" else { return false }
                signal("CloudKit probe iPhone receipt read elapsed=\(started.duration(to: clock.now))")
                if isDSH {
                    guard try await waitForRecord("reply") == "CK-CHAT-OK" else { return false }
                    signal("CloudKit probe iPhone DSH reply read elapsed=\(started.duration(to: clock.now))")
                }
                #endif
            }
            return true
        } catch {
            let diagnostic = error as NSError
            signal("CloudKit probe error domain=\(diagnostic.domain) code=\(diagnostic.code)")
            return false
        }
    }
}
#endif

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
