import Darwin
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
