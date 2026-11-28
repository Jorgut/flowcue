import Darwin
import AppKit
import Foundation
import XCTest
@testable import CodexIdeaDockCore

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Sendable {
        let executableURL: URL
        let arguments: [String]
        let standardInput: Data?
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var results: [ProcessExecutionResult]
    private var recordedCalls: [Call] = []
    private var attachmentRecorded: (@Sendable () -> Void)?

    init(results: [ProcessExecutionResult]) {
        self.results = results
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessExecutionResult {
        return lock.withLock {
            recordedCalls.append(
                Call(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    timeout: timeout
                )
            )
            return results.removeFirst()
        }
    }

    func runAttachmentTurn(executableURL: URL, resume: Data, start: Data, threadID: String, count: Int, timeout: TimeInterval, onRecorded: @escaping @Sendable () -> Void) async throws -> ProcessExecutionResult {
        lock.withLock { attachmentRecorded = onRecorded }
        return try await run(executableURL: executableURL, arguments: ["app-server"], standardInput: resume + start, timeout: timeout)
    }

    func recordLateAttachment() { lock.withLock { attachmentRecorded }?() }

    func calls() -> [Call] {
        lock.withLock { recordedCalls }
    }
}

final class CodexBridgeTests: XCTestCase {
    private let threadID = "11111111-2222-4333-8444-555555555555"

    func testRealAppServerReadIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_IDEA_DOCK_REAL_TEST"] == "1" else {
            throw XCTSkip("Set CODEX_IDEA_DOCK_REAL_TEST=1 to exercise the local Codex App Server.")
        }

        let bridge = CodexBridge(
            processRunner: FoundationProcessRunner(processLauncherURL: try processLauncherURL()),
            executableResolver: { try CodexBridge.resolveCodexExecutable() }
        )
        let contexts = try await bridge.listThreads()
        XCTAssertFalse(contexts.isEmpty)
    }

    @MainActor
    func testRealAttachmentTurnIsOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["FLOWCUE_CODEX_ATTACHMENT_QA"],
              let id = environment["FLOWCUE_CODEX_ATTACHMENT_QA_THREAD"],
              let thread = UUID(uuidString: id) else {
            throw XCTSkip("Requires a disposable Codex test session and synthetic attachments.")
        }
        let source = URL(fileURLWithPath: directory)
        let bridge = CodexBridge(
            processRunner: FoundationProcessRunner(processLauncherURL: try processLauncherURL()),
            executableResolver: { try CodexBridge.resolveCodexExecutable() }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let batch = CodexAgentAdapter.ImageBatch(sessionID: thread, batchID: UUID(), root: root)
        defer { FoundationProcessRunner.terminateAllProcesses() }
        for index in 0..<20 {
            let jpeg = try Data(contentsOf: source.appendingPathComponent(String(format: "image-%02d.jpg", index + 1)))
            XCTAssertEqual(try batch.stage(jpeg, at: index), 200)
        }
        let manifest = RemoteCodexImageBatch(
            text: "FlowCue bridge QA: Read the four-character code in each of the 20 attached images and reply in order. Do not use tools.",
            count: 20
        )
        let status = try await batch.submit(manifest, bridge: bridge)
        XCTAssertEqual(status, 200)
        guard status == 200 else { return }
        let repeated = try await batch.submit(manifest, bridge: bridge)
        XCTAssertEqual(repeated, 200)
        let session = AgentSession(id: id, agentID: "codex", title: "QA", updatedAt: .now,
                                   projectPath: nil, messageCount: nil, locator: id)
        let expected = "K7VQ B3NT H9RS X4CJ M8PD T2LF A6WZ F5GK U3BY D7MN P4XA W6RH V2SF N9TG Z5KU C8JV G4LD Y7EP R3HQ J6BC"
            .split(separator: " ").map(String.init)
        let adapter = CodexAgentAdapter(timeout: 5)
        let deadline = Date().addingTimeInterval(100)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            guard let messages = try? await adapter.messages(in: session, limit: 20),
                  let index = messages.lastIndex(where: { $0.role == .user && $0.text == manifest.text }) else { continue }
            XCTAssertEqual(messages.filter { $0.role == .user && $0.text == manifest.text }.count, 1)
            guard let reply = messages.dropFirst(index + 1).first(where: { $0.role == .assistant }) else { continue }
            let codes = reply.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard expected.allSatisfy(codes.contains) else { continue }
            XCTAssertEqual(codes.filter(expected.contains), expected)
            return
        }
        XCTFail("Codex did not return all 20 synthetic codes before the deadline")
    }

    func testListThreadsUsesProtocolAndPaginates() async throws {
        let firstPage = """
        {"id":1,"result":{"userAgent":"test","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}
        {"id":2,"result":{"data":[{"id":"thread-a","name":"节目任务","preview":"","cwd":"/tmp/show","projectId":"project-a","isPinned":true,"createdAt":100,"updatedAt":200,"recencyAt":300}],"nextCursor":"cursor-1","backwardsCursor":null}}
        """
        let secondPage = """
        {"id":1,"result":{"userAgent":"test","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}
        {"id":2,"result":{"data":[{"id":"thread-b","name":null,"preview":"备用任务","cwd":"/tmp/other","projectId":null,"isPinned":false,"createdAt":100,"updatedAt":250,"recencyAt":250}],"nextCursor":null,"backwardsCursor":null}}
        """
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(
                stdout: Data(firstPage.utf8),
                stderr: Data(),
                exitCode: 0,
                timedOut: false
            ),
            ProcessExecutionResult(
                stdout: Data(secondPage.utf8),
                stderr: Data(),
                exitCode: 0,
                timedOut: false
            )
        ])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        let contexts = try await bridge.listThreads()
        XCTAssertEqual(contexts.map(\.id), ["thread-a", "thread-b"])
        XCTAssertEqual(contexts.first?.title, "节目任务")
        XCTAssertEqual(contexts.last?.title, "备用任务")
        XCTAssertEqual(contexts.first?.projectDirectory, "/tmp/show")

        let calls = runner.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments, ["app-server", "--stdio"])
        let firstInput = try XCTUnwrap(calls[0].standardInput).asUTF8
        XCTAssertTrue(firstInput.contains("thread") && firstInput.contains("list"))
        XCTAssertTrue(firstInput.contains("useStateDbOnly"))
        XCTAssertTrue(firstInput.contains("appServer"))
        let secondInput = try XCTUnwrap(calls[1].standardInput).asUTF8
        XCTAssertTrue(secondInput.contains("cursor-1"))
    }

    func testQueueUsesExactThreadIDAndMessage() async throws {
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: 0,
                timedOut: false
            )
        ])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        let outcome = await bridge.queue(
            message: "Podcast Skill 应改进",
            to: threadID
        )

        XCTAssertEqual(outcome, .queued(exitCode: 0))
        let call = try XCTUnwrap(runner.calls().first)
        XCTAssertEqual(
            call.arguments,
            ["queue", "--thread", threadID, "--message", "Podcast Skill 应改进"]
        )
        XCTAssertNil(call.standardInput)
    }

    func testCodexImageDeliveryStagesJPEGAndPassesItToAppServer() async throws {
        let runner = RecordingProcessRunner(results: [
            try attachmentReceipt(count: 1)
        ])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let pixels = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 24, bitsPerPixel: 24
        ))
        for x in 0..<8 {
            for y in 0..<8 { pixels.setColor(.blue, atX: x, y: y) }
        }
        let jpeg = try XCTUnwrap(pixels.representation(using: .jpeg, properties: [:]))
        XCTAssertTrue(CodexAgentAdapter.isValidAttachment(jpeg))
        XCTAssertFalse(CodexAgentAdapter.isValidAttachment(Data("not an image".utf8)))
        let session = AgentSession(id: threadID, agentID: "codex", title: "test", updatedAt: .now,
                                   projectPath: nil, messageCount: nil, locator: threadID)
        let outcome = try await CodexAgentAdapter().sendImages(
            .init(text: "", images: [jpeg]), to: session, bridge: bridge, stagingRoot: staging
        )
        XCTAssertEqual(outcome, .queued(exitCode: 0))
        let call = try XCTUnwrap(runner.calls().first)
        XCTAssertEqual(call.arguments, ["app-server"])
        let input = try turnInput(call)
        XCTAssertEqual(input.first?["text"] as? String, "Image attachment")
        let path = try XCTUnwrap(input.last?["path"] as? String)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), jpeg)
    }

    @MainActor
    func testTwentyImageBatchResumesAndQueuesExactlyOnce() async throws {
        let runner = RecordingProcessRunner(results: [
            try attachmentReceipt(count: 20)
        ])
        let bridge = CodexBridge(processRunner: runner, executableResolver: { URL(fileURLWithPath: "/tmp/codex") })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try XCTUnwrap(UUID(uuidString: threadID))
        let id = UUID()
        let manifest = RemoteCodexImageBatch(text: "test", count: 20)
        let first = CodexAgentAdapter.ImageBatch(sessionID: session, batchID: id, root: root)
        let images = try (0..<20).map { index in
            let pixels = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 24, bitsPerPixel: 24
            ))
            let color = NSColor(deviceRed: CGFloat(index) / 20, green: 0, blue: 0, alpha: 1)
            for x in 0..<8 { for y in 0..<8 { pixels.setColor(color, atX: x, y: y) } }
            return try XCTUnwrap(pixels.representation(using: .jpeg, properties: [:]))
        }
        XCTAssertEqual(Set(images).count, 20)
        for index in 0..<10 { XCTAssertEqual(try first.stage(images[index], at: index), 200) }
        let incomplete = try await first.submit(manifest, bridge: bridge)
        XCTAssertEqual(incomplete, 424)
        XCTAssertTrue(runner.calls().isEmpty)

        let resumed = CodexAgentAdapter.ImageBatch(sessionID: session, batchID: id, root: root)
        XCTAssertEqual(resumed.uploaded(), Array(0..<10))
        XCTAssertEqual(try resumed.stage(images[0], at: 0), 200)
        XCTAssertEqual(try resumed.stage(images[1], at: 0), 409)
        for index in 10..<20 { XCTAssertEqual(try resumed.stage(images[index], at: index), 200) }
        let accepted = try await resumed.submit(manifest, bridge: bridge)
        let duplicate = try await first.submit(manifest, bridge: bridge)
        XCTAssertEqual(accepted, 200)
        XCTAssertEqual(duplicate, 200)
        XCTAssertEqual(runner.calls().count, 1)
        let input = try turnInput(XCTUnwrap(runner.calls().first))
        XCTAssertEqual(input.dropFirst().map { $0["type"] as? String }, Array(repeating: "localImage", count: 20))
        let paths = input.dropFirst().compactMap { $0["path"] as? String }
        XCTAssertEqual(try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, images)
    }

    @MainActor
    func testLateAttachmentReceiptUpdatesBatchWithoutResubmitting() async throws {
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(stdout: Data(), stderr: Data(), exitCode: -1, timedOut: true)
        ])
        let bridge = CodexBridge(processRunner: runner, executableResolver: { URL(fileURLWithPath: "/tmp/codex") })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = CodexAgentAdapter.ImageBatch(sessionID: try XCTUnwrap(UUID(uuidString: threadID)), batchID: UUID(), root: root)
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 24, bitsPerPixel: 24))
        for x in 0..<8 {
            for y in 0..<8 { image.setColor(.blue, atX: x, y: y) }
        }
        XCTAssertEqual(try batch.stage(XCTUnwrap(image.representation(using: .jpeg, properties: [:])), at: 0), 200)
        let manifest = RemoteCodexImageBatch(text: "late", count: 1)
        let pending = try await batch.submit(manifest, bridge: bridge)
        XCTAssertEqual(pending, 409)
        XCTAssertEqual(batch.deliveryStatus(), 409)
        runner.recordLateAttachment()
        XCTAssertEqual(batch.deliveryStatus(), 200)
        let repeated = try await batch.submit(manifest, bridge: bridge)
        XCTAssertEqual(repeated, 200)
        XCTAssertEqual(runner.calls().count, 1)
    }

    @MainActor
    func testImageUploadResumesAfterMultipleLostAcknowledgements() async throws {
        var staged = Set<Int>()
        var attempted: [Int] = []
        try await RemoteCodexImageBatch.uploadMissing(
            count: 5,
            status: { Array(staged) },
            put: { index in
                attempted.append(index)
                staged.insert(index)
                if index < 4 { throw URLError(.timedOut) }
            },
            retry: { _ in true },
            onProgress: { _ in }
        )
        XCTAssertEqual(attempted, Array(0..<5))
    }

    @MainActor
    func testImageUploadStopsWhenRetriesMakeNoProgress() async {
        var attempts = 0
        do {
            try await RemoteCodexImageBatch.uploadMissing(
                count: 1,
                status: { [] },
                put: { _ in attempts += 1; throw URLError(.timedOut) },
                retry: { _ in true },
                onProgress: { _ in }
            )
            XCTFail("Expected the upload to stop")
        } catch {
            XCTAssertEqual(attempts, 4)
        }
    }

    func testPendingCodexImagesPersistOriginalRequestAndSubmissionPhase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upload.json")
        XCTAssertNil(try PendingCodexImageBatch.load(from: url))
        var draft = PendingCodexImageBatch(batchID: "batch", requestID: "request", text: "check",
                                          images: [Data([1, 2, 3])], historyIDs: ["old"])
        try draft.save(to: url)
        let before = try XCTUnwrap(PendingCodexImageBatch.load(from: url))
        XCTAssertEqual(before.phase, .uploading)
        XCTAssertEqual(before.images, draft.images)
        XCTAssertEqual(before.historyIDs, draft.historyIDs)
        draft.phase = .submitted
        try draft.save(to: url)
        let after = try XCTUnwrap(PendingCodexImageBatch.load(from: url))
        XCTAssertEqual(after.phase, .submitted)
        XCTAssertEqual(after.requestID, "request")
        XCTAssertEqual(after.batchID, "batch")
    }

    func testAttachmentTurnAcknowledgementWithoutUserItemRemainsUnknown() async throws {
        let response = #"{"id":3,"result":{"turn":{"id":"turn"}}}"#
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(stdout: Data(response.utf8), stderr: Data(), exitCode: 0, timedOut: false)
        ])
        let bridge = CodexBridge(processRunner: runner, executableResolver: { URL(fileURLWithPath: "/tmp/codex") })
        let outcome = await bridge.queue(message: "image check", to: threadID, imagePaths: ["/tmp/test.jpg"])
        guard case .unknown = outcome else { return XCTFail("Expected an unknown outcome before a user item is recorded") }
    }

    func testManagedAttachmentTurnDoesNotSendIntoActiveSession() async throws {
        let executable = try temporaryExecutable(contents: """
        #!/bin/sh
        read -r init
        read -r initialized
        read -r resume
        printf '%s\\n' '{"id":2,"result":{"thread":{"status":{"type":"active"}}}}'
        if read -r start; then touch "$0.sent"; fi
        """)
        let sent = executable.appendingPathExtension("sent")
        defer {
            try? FileManager.default.removeItem(at: executable)
            try? FileManager.default.removeItem(at: sent)
        }
        let bridge = CodexBridge(
            processRunner: FoundationProcessRunner(processLauncherURL: try processLauncherURL()),
            executableResolver: { executable }
        )
        let outcome = await bridge.queue(message: "image check", to: threadID, imagePaths: ["/tmp/test.jpg"])
        XCTAssertEqual(outcome, .failed(exitCode: nil, message: QueueDeliveryDiagnostic.targetBusy.rawValue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.path))
    }

    private func turnInput(_ call: RecordingProcessRunner.Call) throws -> [[String: Any]] {
        let data = try XCTUnwrap(call.standardInput)
        let line = try XCTUnwrap(data.split(separator: 0x0A).last)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "turn/start")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, threadID)
        return try XCTUnwrap(params["input"] as? [[String: Any]])
    }

    private func attachmentReceipt(count: Int) throws -> ProcessExecutionResult {
        let response = #"{"id":3,"result":{"turn":{"id":"turn"}}}"#
        let item: [String: Any] = ["method": "item/completed", "params": [
            "turnId": "turn", "threadId": threadID,
            "item": ["type": "userMessage", "content": Array(repeating: ["type": "localImage"], count: count)]
        ]]
        var output = Data((response + "\n").utf8)
        output.append(try JSONSerialization.data(withJSONObject: item))
        return ProcessExecutionResult(stdout: output, stderr: Data(), exitCode: 0, timedOut: false)
    }

    func testQueueTimeoutBecomesUnknownAndFailureRedactsMessage() async throws {
        let timeoutRunner = RecordingProcessRunner(results: [
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: -1,
                timedOut: true
            )
        ])
        let timeoutBridge = CodexBridge(
            processRunner: timeoutRunner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )
        let timeoutOutcome = await timeoutBridge.queue(message: "secret idea", to: threadID)
        guard case .unknown(let timeoutMessage) = timeoutOutcome else {
            return XCTFail("Expected an unknown queue result")
        }
        XCTAssertEqual(
            timeoutMessage,
            "Codex did not confirm whether the message was queued before the timeout."
        )
        XCTAssertFalse(timeoutMessage.contains("secret idea"))

        let failureRunner = RecordingProcessRunner(results: [
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data("failed secret idea".utf8),
                exitCode: 2,
                timedOut: false
            )
        ])
        let failureBridge = CodexBridge(
            processRunner: failureRunner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )
        let failureOutcome = await failureBridge.queue(message: "secret idea", to: threadID)
        guard case .unknown(let failureMessage) = failureOutcome else {
            return XCTFail("Expected an unknown queue result")
        }
        XCTAssertEqual(failureMessage, "Codex exited without confirming whether the message was queued.")
        XCTAssertFalse(failureMessage.contains("secret idea"))
        XCTAssertFalse(failureMessage.contains("failed"))
    }

    func testQueueRejectsEmptyInputWithoutStartingProcess() async {
        let runner = RecordingProcessRunner(results: [])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        let emptyMessage = await bridge.queue(message: " \n\t", to: threadID)
        let emptyThread = await bridge.queue(message: "idea", to: " \n\t")
        let invalidThread = await bridge.queue(message: "idea", to: "thread-title")

        XCTAssertEqual(emptyMessage, .failed(exitCode: nil, message: "The message is empty."))
        XCTAssertEqual(emptyThread, .failed(exitCode: nil, message: "The target task identifier is empty."))
        XCTAssertEqual(
            invalidThread,
            .failed(exitCode: nil, message: "The target task identifier is not a UUID.")
        )
        XCTAssertTrue(runner.calls().isEmpty)
    }

    func testResolverFailureIsReportedWithoutStartingProcess() async {
        let runner = RecordingProcessRunner(results: [])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { throw BridgeTestError.resolverFailed }
        )

        let outcome = await bridge.queue(message: "idea", to: threadID)

        guard case .failed(let exitCode, let message) = outcome else {
            return XCTFail("Expected a resolver failure")
        }
        XCTAssertNil(exitCode)
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(runner.calls().isEmpty)

        do {
            _ = try await bridge.listThreads()
            XCTFail("Expected listThreads to throw when resolving Codex")
        } catch let error as BridgeTestError {
            XCTAssertEqual(error, .resolverFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(runner.calls().isEmpty)
    }

    func testRunnerFailureIsReportedForQueueAndList() async {
        let runner = ThrowingProcessRunner(error: BridgeTestError.runnerFailed)
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        let outcome = await bridge.queue(message: "idea", to: threadID)
        guard case .failed(let exitCode, let message) = outcome else {
            return XCTFail("Expected a process failure")
        }
        XCTAssertNil(exitCode)
        XCTAssertFalse(message.isEmpty)

        do {
            _ = try await bridge.listThreads()
            XCTFail("Expected listThreads to throw when the runner fails")
        } catch let error as BridgeTestError {
            XCTAssertEqual(error, .runnerFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.callCount, 2)
    }

    func testQueueMapsKnownCLIStderrToAllowlistedDiagnostics() async {
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data("error: unrecognized subcommand 'queue'\nsecret=/tmp/token".utf8),
                exitCode: 2,
                timedOut: false
            ),
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data("thread not found: private-title".utf8),
                exitCode: 1,
                timedOut: false
            ),
            ProcessExecutionResult(
                stdout: Data(),
                stderr: Data("operation not permitted: /private/path".utf8),
                exitCode: 1,
                timedOut: false
            )
        ])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        let unsupported = await bridge.queue(message: "idea", to: threadID)
        let missingTarget = await bridge.queue(message: "idea", to: threadID)
        let denied = await bridge.queue(message: "idea", to: threadID)

        XCTAssertEqual(
            unsupported,
            .failed(exitCode: 2, message: "This Codex CLI does not support queue.")
        )
        XCTAssertEqual(
            missingTarget,
            .failed(exitCode: 1, message: "The target Codex task is unavailable.")
        )
        XCTAssertEqual(
            denied,
            .failed(exitCode: 1, message: "Codex does not have permission to queue this message.")
        )
    }

    func testRepeatedCursorFailsClosed() async throws {
        let page = """
        {"id":1,"result":{"userAgent":"test","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}
        {"id":2,"result":{"data":[],"nextCursor":"same","backwardsCursor":null}}
        """
        let runner = RecordingProcessRunner(results: [
            ProcessExecutionResult(stdout: Data(page.utf8), stderr: Data(), exitCode: 0, timedOut: false),
            ProcessExecutionResult(stdout: Data(page.utf8), stderr: Data(), exitCode: 0, timedOut: false)
        ])
        let bridge = CodexBridge(
            processRunner: runner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        do {
            _ = try await bridge.listThreads()
            XCTFail("Expected repeated pagination cursor to fail")
        } catch let error as CodexBridgeError {
            XCTAssertEqual(error, .repeatedCursor)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(runner.calls().count, 2)
    }

    func testRPCErrorAndInvalidResponseFailClosed() async throws {
        let rpcError = """
        {"id":1,"error":{"code":-32000,"message":"not initialized"}}
        """
        let rpcRunner = RecordingProcessRunner(results: [
            ProcessExecutionResult(stdout: Data(rpcError.utf8), stderr: Data(), exitCode: 0, timedOut: false)
        ])
        let rpcBridge = CodexBridge(
            processRunner: rpcRunner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        do {
            _ = try await rpcBridge.listThreads()
            XCTFail("Expected RPC error")
        } catch let error as CodexBridgeError {
            XCTAssertEqual(error, .rpc(code: -32000, message: "not initialized"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let invalidRunner = RecordingProcessRunner(results: [
            ProcessExecutionResult(stdout: Data("not-json\n".utf8), stderr: Data(), exitCode: 0, timedOut: false)
        ])
        let invalidBridge = CodexBridge(
            processRunner: invalidRunner,
            executableResolver: { URL(fileURLWithPath: "/tmp/codex") }
        )

        do {
            _ = try await invalidBridge.listThreads()
            XCTFail("Expected invalid response")
        } catch let error as CodexBridgeError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFoundationProcessRunnerAddsResolvedExecutableDirectoryToPath() async throws {
        let processLauncherURL = try processLauncherURL()
        let siblingRuntimeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexIdeaDock-SiblingRuntime-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: siblingRuntimeURL,
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let executableURL = try temporaryExecutable(
            contents: "#!/usr/bin/env \(siblingRuntimeURL.lastPathComponent)\n"
        )
        defer {
            try? FileManager.default.removeItem(at: executableURL)
            try? FileManager.default.removeItem(at: siblingRuntimeURL)
        }
        let runner = FoundationProcessRunner(
            processLauncherURL: processLauncherURL,
            processRegistry: ActiveProcessRegistry(),
            processGroupHandshakeTimeout: 2,
            baseEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: [],
            standardInput: nil,
            timeout: 3
        )

        XCTAssertEqual(result.terminationReason, .exit)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testFoundationProcessRunnerDoesNotWaitForInheritedPipeAfterChildExit() async throws {
        let launcherURL = try processLauncherURL()
        let start = Date()
        let result = try await FoundationProcessRunner(processLauncherURL: launcherURL).run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10 & child=$!; echo $$ $child; exit 0"],
            standardInput: nil,
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(start)
        let processIDs = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        XCTAssertEqual(processIDs.count, 2)
        let processGroupID = try XCTUnwrap(processIDs.first)
        let childPID = try XCTUnwrap(processIDs.last)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(elapsed, 1.0, "The runner waited for an inherited output pipe to close")
        let reapDeadline = Date().addingTimeInterval(1)
        while Darwin.kill(childPID, 0) == 0, Date() < reapDeadline {
            usleep(10_000)
        }
        XCTAssertNotEqual(Darwin.kill(-processGroupID, 0), 0, "The runner left its process group alive")
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "The runner left a child process alive")
    }

    func testFoundationProcessRunnerTimeoutTerminatesProcessGroup() async throws {
        let launcherURL = try processLauncherURL()
        let start = Date()
        let result = try await FoundationProcessRunner(processLauncherURL: launcherURL).run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$; sleep 10"],
            standardInput: nil,
            timeout: 0.1
        )
        let processGroupID = try XCTUnwrap(
            pid_t(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertNotEqual(Darwin.kill(-processGroupID, 0), 0, "Timed-out process group is still alive")
    }

    func testFoundationProcessRunnerCancellationTerminatesProcessGroup() async throws {
        let launcherURL = try processLauncherURL()
        let runner = FoundationProcessRunner(processLauncherURL: launcherURL)
        let processIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-idea-dock-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDURL) }
        let start = Date()
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; sleep 10",
                    "codex-idea-dock-test",
                    processIDURL.path
                ],
                standardInput: nil,
                timeout: 10
            )
        }
        let startDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: processIDURL.path), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processGroupID = try XCTUnwrap(
            pid_t(
                String(decoding: try Data(contentsOf: processIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        task.cancel()
        let result = try await task.value

        XCTAssertEqual(result.terminationReason, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertNotEqual(Darwin.kill(-processGroupID, 0), 0, "Cancelled process group is still alive")
    }

    func testFoundationProcessRunnerFailsClosedWithoutLauncherHandshake() async throws {
        let processIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexIdeaDock-UnmanagedLauncher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDURL) }
        let launcherURL = try temporaryExecutable(
            contents: "#!/bin/sh\necho $$ > \"$6\"\nexec sleep 10\n"
        )
        defer { try? FileManager.default.removeItem(at: launcherURL) }
        let registry = ActiveProcessRegistry()
        let runner = FoundationProcessRunner(
            processLauncherURL: launcherURL,
            processRegistry: registry,
            processGroupHandshakeTimeout: 1
        )

        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [processIDURL.path],
                standardInput: nil,
                timeout: 2
            )
            XCTFail("Expected the missing handshake to fail closed")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .processGroupHandshakeFailed)
        }

        let launcherProcessID = try XCTUnwrap(
            pid_t(
                String(decoding: try Data(contentsOf: processIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        let reapDeadline = Date().addingTimeInterval(1)
        while Darwin.kill(launcherProcessID, 0) == 0, Date() < reapDeadline {
            usleep(10_000)
        }
        XCTAssertNotEqual(Darwin.kill(launcherProcessID, 0), 0)
    }

    func testTerminationControllerRemembersForceBeforeProcessAttachment() throws {
        let controller = ProcessTerminationController()
        controller.forceTermination()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        controller.attach(process: process)

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertFalse(process.isRunning)
        controller.detach()
        controller.markFinished()
    }

    func testProcessRegistryShutdownRejectsNewWork() {
        let registry = ActiveProcessRegistry()
        registry.terminateAll()
        let controller = ProcessTerminationController()
        defer { controller.markFinished() }

        XCTAssertFalse(registry.insert(controller))
    }

    func testProcessRegistryShutdownDrainsActiveProcessGroup() async throws {
        let launcherURL = try processLauncherURL()
        let registry = ActiveProcessRegistry()
        let runner = FoundationProcessRunner(
            processLauncherURL: launcherURL,
            processRegistry: registry
        )
        let processIDURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexIdeaDock-ShutdownGroup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDURL) }
        let task = Task {
            try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; sleep 10 & wait",
                    "codex-idea-dock-test",
                    processIDURL.path
                ],
                standardInput: nil,
                timeout: 10
            )
        }

        let startDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: processIDURL.path), Date() < startDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processGroupID = try XCTUnwrap(
            pid_t(
                String(decoding: try Data(contentsOf: processIDURL), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        registry.terminateAll()
        let result = try await task.value

        XCTAssertEqual(result.terminationReason, .cancelled)
        XCTAssertNotEqual(Darwin.kill(-processGroupID, 0), 0)
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                standardInput: nil,
                timeout: 1
            )
            XCTFail("Expected shutdown registry to reject new work")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .shuttingDown)
        }
    }

    private func processLauncherURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let launcherURL = Bundle(for: CodexBridgeTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("CodexIdeaDockProcessLauncher")
        guard FileManager.default.isExecutableFile(atPath: launcherURL.path) else {
            XCTFail("Process launcher was not built", file: file, line: line)
            throw BridgeTestError.launcherMissing
        }
        return launcherURL
    }

    private func temporaryExecutable(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexIdeaDock-TestLauncher-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        guard chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw POSIXError(.EPERM)
        }
        return url
    }
}

private enum BridgeTestError: Error, Equatable, Sendable {
    case resolverFailed
    case runnerFailed
    case launcherMissing
}

private final class ThrowingProcessRunner: ProcessRunning, @unchecked Sendable {
    let error: BridgeTestError
    private let lock = NSLock()
    private var recordedCallCount = 0

    init(error: BridgeTestError) {
        self.error = error
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessExecutionResult {
        lock.withLock {
            recordedCallCount += 1
        }
        throw error
    }
}

private extension Data {
    var asUTF8: String {
        String(decoding: self, as: UTF8.self)
    }
}
