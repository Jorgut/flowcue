#if !FLOWCUE_APP_STORE
import Darwin
import Foundation

public struct ProcessExecutionResult: Sendable, Equatable {
    public enum TerminationReason: Sendable, Equatable {
        case exit
        case uncaughtSignal
        case cancelled
    }

    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int
    public let timedOut: Bool
    public let terminationReason: TerminationReason

    public init(
        stdout: Data,
        stderr: Data,
        exitCode: Int,
        timedOut: Bool,
        terminationReason: TerminationReason = .exit
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.terminationReason = terminationReason
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessExecutionResult
}

public struct FoundationProcessRunner: ProcessRunning, Sendable {
    private let processLauncherURLOverride: URL?
    private let processRegistry: ActiveProcessRegistry
    private let processGroupHandshakeTimeout: TimeInterval
    private let baseEnvironment: [String: String]

    public init(processLauncherURL: URL? = nil) {
        self.processLauncherURLOverride = processLauncherURL
        self.processRegistry = .shared
        self.processGroupHandshakeTimeout = 2
        self.baseEnvironment = ProcessInfo.processInfo.environment
    }

    init(
        processLauncherURL: URL?,
        processRegistry: ActiveProcessRegistry,
        processGroupHandshakeTimeout: TimeInterval = 2,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.processLauncherURLOverride = processLauncherURL
        self.processRegistry = processRegistry
        self.processGroupHandshakeTimeout = processGroupHandshakeTimeout
        self.baseEnvironment = baseEnvironment
    }

    public static func terminateAllProcesses() {
        ActiveProcessRegistry.shared.terminateAll()
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> ProcessExecutionResult {
        let controller = ProcessTerminationController()
        let processLauncherURL = processLauncherURLOverride ?? Self.processLauncherURL()
        guard processRegistry.insert(controller) else {
            throw ProcessRunnerError.shuttingDown
        }
        let processRegistry = processRegistry
        let processGroupHandshakeTimeout = processGroupHandshakeTimeout
        let baseEnvironment = baseEnvironment

        let worker = Task.detached(priority: .userInitiated) {
            defer {
                controller.markFinished()
                processRegistry.remove(controller)
            }
            return try Self.runSynchronously(
                    executableURL: executableURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    timeout: timeout,
                    controller: controller,
                    processLauncherURL: processLauncherURL,
                    processGroupHandshakeTimeout: processGroupHandshakeTimeout,
                    baseEnvironment: baseEnvironment
                )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            controller.requestCancellation()
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval,
        controller: ProcessTerminationController,
        processLauncherURL: URL?,
        processGroupHandshakeTimeout: TimeInterval,
        baseEnvironment: [String: String]
    ) throws -> ProcessExecutionResult {
        guard timeout > 0 else {
            throw ProcessRunnerError.invalidTimeout
        }
        guard processGroupHandshakeTimeout > 0 else {
            throw ProcessRunnerError.invalidProcessGroupHandshakeTimeout
        }
        if controller.isCancellationRequested {
            return ProcessExecutionResult(
                stdout: Data(),
                stderr: Data(),
                exitCode: -1,
                timedOut: false,
                terminationReason: .cancelled
            )
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let terminationSemaphore = DispatchSemaphore(value: 0)

        let launchCommand = try resolveLaunchCommand(
            executableURL: executableURL,
            arguments: arguments,
            processLauncherURL: processLauncherURL
        )
        defer { launchCommand.handshake.cleanup() }
        process.executableURL = launchCommand.executableURL
        process.arguments = launchCommand.arguments
        process.environment = launchEnvironment(
            for: executableURL,
            baseEnvironment: baseEnvironment
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        try process.run()
        controller.attach(process: process)
        defer { controller.detach() }

        let outputReader = DataReader(
            fileHandle: outputPipe.fileHandleForReading,
            maximumByteCount: 4 * 1_024 * 1_024
        )
        let errorReader = DataReader(
            fileHandle: errorPipe.fileHandleForReading,
            maximumByteCount: 256 * 1_024
        )
        outputReader.start()
        errorReader.start()

        let processGroupID: pid_t
        do {
            processGroupID = try waitForProcessGroupHandshake(
                launchCommand.handshake,
                process: process,
                controller: controller,
                timeout: processGroupHandshakeTimeout
            )
            controller.attachProcessGroup(processGroupID)
            let didAcknowledge = try controller.performIfLaunchAllowed {
                try launchCommand.handshake.acknowledge(processID: process.processIdentifier)
            }
            if !didAcknowledge {
                terminate(
                    process,
                    processGroupID: processGroupID,
                    terminationSemaphore: terminationSemaphore
                )
            }
        } catch {
            let wasCancelled = controller.isCancellationRequested || error is CancellationError
            controller.forceTermination()
            if process.isRunning {
                _ = terminationSemaphore.wait(timeout: .now() + 0.5)
            }
            _ = outputReader.finish(waitingUpTo: 0.1)
            _ = errorReader.finish(waitingUpTo: 0.1)
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            if wasCancelled {
                return ProcessExecutionResult(
                    stdout: Data(),
                    stderr: Data(),
                    exitCode: process.isRunning ? -1 : Int(process.terminationStatus),
                    timedOut: false,
                    terminationReason: .cancelled
                )
            }
            throw error
        }

        var cancelled = controller.isCancellationRequested

        do {
            guard !cancelled else { throw CancellationError() }
            if let standardInput {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            }
            if arguments.first != "app-server" {
                try inputPipe.fileHandleForWriting.close()
            }
        } catch {
            if process.isRunning {
                terminate(
                    process,
                    processGroupID: processGroupID,
                    terminationSemaphore: terminationSemaphore
                )
            }
            terminateRemainingGroup(processGroupID)
            if cancelled || error is CancellationError {
                cancelled = true
            } else {
                throw error
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var responseReceived = false

        if arguments.first == "app-server" {
            while process.isRunning, Date() < deadline, !controller.isCancellationRequested {
                if outputReader.containsJSONResponse(id: 2) {
                    responseReceived = true
                    try? inputPipe.fileHandleForWriting.close()
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }

            cancelled = controller.isCancellationRequested
            if !responseReceived, !cancelled, process.isRunning {
                timedOut = true
            }

            if responseReceived, process.isRunning {
                _ = terminationSemaphore.wait(timeout: .now() + 1)
            }

            if process.isRunning, timedOut || cancelled || responseReceived {
                terminate(
                    process,
                    processGroupID: processGroupID,
                    terminationSemaphore: terminationSemaphore
                )
            }
        } else {
            while process.isRunning, Date() < deadline, !controller.isCancellationRequested {
                if terminationSemaphore.wait(timeout: .now() + 0.02) == .success {
                    break
                }
            }
            cancelled = controller.isCancellationRequested
            timedOut = !cancelled && process.isRunning && Date() >= deadline
        }

        if process.isRunning, timedOut || cancelled {
            terminate(
                process,
                processGroupID: processGroupID,
                terminationSemaphore: terminationSemaphore
            )
        }

        terminateRemainingGroup(processGroupID)

        let stdout = outputReader.finish(waitingUpTo: 0.1)
        let stderr = errorReader.finish(waitingUpTo: 0.1)
        try? inputPipe.fileHandleForWriting.close()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForReading.close()
        let exitCode = process.isRunning ? -1 : Int(process.terminationStatus)
        let terminationReason: ProcessExecutionResult.TerminationReason
        if cancelled {
            terminationReason = .cancelled
        } else if !process.isRunning, process.terminationReason == .uncaughtSignal {
            terminationReason = .uncaughtSignal
        } else {
            terminationReason = .exit
        }

        return ProcessExecutionResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            timedOut: timedOut,
            terminationReason: terminationReason
        )
    }

    private static func launchEnvironment(
        for executableURL: URL,
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment
        var pathEntries = [executableURL.deletingLastPathComponent().path]
        pathEntries.append(
            contentsOf: baseEnvironment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
                .split(separator: ":")
                .map(String.init)
                .filter { !$0.isEmpty }
        )

        var seenEntries = Set<String>()
        environment["PATH"] = pathEntries
            .filter { seenEntries.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private static func resolveLaunchCommand(
        executableURL: URL,
        arguments: [String],
        processLauncherURL: URL?
    ) throws -> LaunchCommand {
        guard let launcherURL = processLauncherURL else {
            throw ProcessRunnerError.processLauncherUnavailable
        }
        let handshake = try ProcessLaunchHandshake.make()
        return LaunchCommand(
            executableURL: launcherURL,
            arguments: [
                "--handshake-directory",
                handshake.directoryURL.path,
                "--parent-process",
                String(getpid()),
                executableURL.path
            ] + arguments,
            handshake: handshake
        )
    }

    static func processLauncherURL() -> URL? {
        let fileManager = FileManager.default
        let launcherName = "CodexIdeaDockProcessLauncher"
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(launcherName),
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(launcherName),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(launcherName)
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func waitForProcessGroupHandshake(
        _ handshake: ProcessLaunchHandshake,
        process: Process,
        controller: ProcessTerminationController,
        timeout: TimeInterval
    ) throws -> pid_t {
        let processID = process.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning, Date() < deadline {
            if handshake.readyProcessID() == processID,
               getpgid(processID) == processID {
                return processID
            }
            if controller.isCancellationRequested {
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if controller.isCancellationRequested {
            throw CancellationError()
        }
        throw ProcessRunnerError.processGroupHandshakeFailed
    }

    private static func terminate(
        _ process: Process,
        processGroupID: pid_t?,
        terminationSemaphore: DispatchSemaphore
    ) {
        send(SIGTERM, to: process, processGroupID: processGroupID)
        if terminationSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
            send(SIGKILL, to: process, processGroupID: processGroupID)
            _ = terminationSemaphore.wait(timeout: .now() + 0.5)
        }
        if let processGroupID {
            Darwin.kill(-processGroupID, SIGKILL)
        }
    }

    private static func terminateRemainingGroup(_ processGroupID: pid_t?) {
        guard let processGroupID, Darwin.kill(-processGroupID, 0) == 0 else { return }
        Darwin.kill(-processGroupID, SIGTERM)
        Thread.sleep(forTimeInterval: 0.05)
        Darwin.kill(-processGroupID, SIGKILL)
    }

    fileprivate static func send(
        _ signal: Int32,
        to process: Process,
        processGroupID: pid_t?
    ) {
        if let processGroupID {
            Darwin.kill(-processGroupID, signal)
        } else if process.isRunning {
            Darwin.kill(process.processIdentifier, signal)
        }
    }
}

private struct LaunchCommand {
    let executableURL: URL
    let arguments: [String]
    let handshake: ProcessLaunchHandshake
}

private struct ProcessLaunchHandshake: Sendable {
    let directoryURL: URL
    let readyURL: URL
    let acknowledgementURL: URL

    static func make() throws -> ProcessLaunchHandshake {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexIdeaDock-Launch-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProcessRunnerError.processGroupHandshakeFailed
        }
        return ProcessLaunchHandshake(
            directoryURL: directoryURL,
            readyURL: directoryURL.appendingPathComponent("ready"),
            acknowledgementURL: directoryURL.appendingPathComponent("ack")
        )
    }

    func readyProcessID() -> pid_t? {
        guard let data = try? Data(contentsOf: readyURL), data.count <= 64 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(text)
    }

    func acknowledge(processID: pid_t) throws {
        let descriptor = acknowledgementURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw ProcessRunnerError.processGroupHandshakeFailed
        }
        defer { Darwin.close(descriptor) }

        let bytes = Array("\(processID)\n".utf8)
        let writtenByteCount = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard writtenByteCount == bytes.count else {
            throw ProcessRunnerError.processGroupHandshakeFailed
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

enum ProcessTerminationRequest: Int, Sendable {
    case none
    case terminate
    case kill
}

final class ProcessTerminationController: @unchecked Sendable {
    private let lock = NSLock()
    private let finishedGroup = DispatchGroup()
    private var process: Process?
    private var processGroupID: pid_t?
    private var cancellationRequested = false
    private var terminationRequest = ProcessTerminationRequest.none
    private var didFinish = false

    init() {
        finishedGroup.enter()
    }

    var isCancellationRequested: Bool {
        lock.withLock { cancellationRequested }
    }

    func attach(process: Process) {
        let request = lock.withLock {
            self.process = process
            return terminationRequest
        }
        send(request, to: process, processGroupID: nil)
    }

    func attachProcessGroup(_ processGroupID: pid_t) {
        let state = lock.withLock { () -> (Process?, ProcessTerminationRequest) in
            self.processGroupID = processGroupID
            return (process, terminationRequest)
        }
        if let process = state.0 {
            send(state.1, to: process, processGroupID: processGroupID)
        }
    }

    func performIfLaunchAllowed(_ action: () throws -> Void) throws -> Bool {
        try lock.withLock {
            guard terminationRequest == .none else { return false }
            try action()
            return true
        }
    }

    func requestCancellation() {
        let managedProcess = lock.withLock { () -> (Process, pid_t?)? in
            cancellationRequested = true
            if terminationRequest == .none {
                terminationRequest = .terminate
            }
            guard let process else { return nil }
            return (process, processGroupID)
        }
        if let (process, processGroupID) = managedProcess {
            FoundationProcessRunner.send(SIGTERM, to: process, processGroupID: processGroupID)
        }
    }

    func forceTermination() {
        let managedProcess = lock.withLock { () -> (Process, pid_t?)? in
            cancellationRequested = true
            terminationRequest = .kill
            guard let process else { return nil }
            return (process, processGroupID)
        }
        if let (process, processGroupID) = managedProcess {
            FoundationProcessRunner.send(SIGKILL, to: process, processGroupID: processGroupID)
        }
    }

    func detach() {
        lock.withLock {
            process = nil
            processGroupID = nil
        }
    }

    func markFinished() {
        let shouldLeave = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldLeave {
            finishedGroup.leave()
        }
    }

    func waitUntilFinished(until deadline: DispatchTime) -> Bool {
        finishedGroup.wait(timeout: deadline) == .success
    }

    private func send(
        _ request: ProcessTerminationRequest,
        to process: Process,
        processGroupID: pid_t?
    ) {
        switch request {
        case .none:
            break
        case .terminate:
            FoundationProcessRunner.send(SIGTERM, to: process, processGroupID: processGroupID)
        case .kill:
            FoundationProcessRunner.send(SIGKILL, to: process, processGroupID: processGroupID)
        }
    }
}

final class ActiveProcessRegistry: @unchecked Sendable {
    static let shared = ActiveProcessRegistry()

    private let lock = NSLock()
    private var controllers: [ObjectIdentifier: ProcessTerminationController] = [:]
    private var isShuttingDown = false

    @discardableResult
    func insert(_ controller: ProcessTerminationController) -> Bool {
        lock.withLock {
            guard !isShuttingDown else { return false }
            controllers[ObjectIdentifier(controller)] = controller
            return true
        }
    }

    func remove(_ controller: ProcessTerminationController) {
        _ = lock.withLock {
            controllers.removeValue(forKey: ObjectIdentifier(controller))
        }
    }

    func terminateAll() {
        let activeControllers = lock.withLock {
            isShuttingDown = true
            return Array(controllers.values)
        }
        activeControllers.forEach { $0.requestCancellation() }
        let gracefulDeadline = DispatchTime.now() + .milliseconds(1_250)
        let unfinishedControllers = activeControllers.filter {
            !$0.waitUntilFinished(until: gracefulDeadline)
        }
        unfinishedControllers.forEach { $0.forceTermination() }
        let forcedDeadline = DispatchTime.now() + .seconds(1)
        unfinishedControllers.forEach { _ = $0.waitUntilFinished(until: forcedDeadline) }
    }
}

public enum ProcessRunnerError: LocalizedError, Sendable, Equatable {
    case invalidTimeout
    case invalidProcessGroupHandshakeTimeout
    case processLauncherUnavailable
    case processGroupHandshakeFailed
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "The process timeout must be greater than zero."
        case .invalidProcessGroupHandshakeTimeout:
            return "The process-group handshake timeout must be greater than zero."
        case .processLauncherUnavailable:
            return "The process-group launcher is unavailable."
        case .processGroupHandshakeFailed:
            return "The process-group launcher did not complete its safety handshake."
        case .shuttingDown:
            return "The process runner is shutting down."
        }
    }
}

public enum CodexBridgeError: LocalizedError, Sendable, Equatable {
    case executableNotFound
    case processFailed(exitCode: Int?, message: String)
    case timedOut(operation: String)
    case invalidResponse
    case rpc(code: Int, message: String)
    case repeatedCursor
    case tooManyPages

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "The Codex command-line tool could not be found."
        case let .processFailed(exitCode, message):
            if let exitCode {
                return "Codex exited with code \(exitCode): \(message)"
            }
            return message
        case let .timedOut(operation):
            return "\(operation) timed out."
        case .invalidResponse:
            return "Codex returned an invalid app-server response."
        case let .rpc(code, message):
            return "Codex app-server error \(code): \(message)"
        case .repeatedCursor:
            return "Codex returned a repeated pagination cursor."
        case .tooManyPages:
            return "Codex returned more task pages than the client can safely process."
        }
    }
}

public struct CodexBridge: CodexBridging, Sendable {
    public typealias ExecutableResolver = @Sendable () throws -> URL

    private static let appServerArguments = ["app-server", "--stdio"]
    fileprivate static let pageLimit = 100
    private static let maximumPageCount = 1_000
    fileprivate static let sourceKinds = ["cli", "vscode", "appServer"]

    private let processRunner: any ProcessRunning
    private let executableResolver: ExecutableResolver
    private let appServerTimeout: TimeInterval
    private let queueTimeout: TimeInterval

    public init() {
        self.init(
            processRunner: FoundationProcessRunner(),
            executableResolver: { try Self.resolveCodexExecutable() }
        )
    }

    public init(
        processRunner: any ProcessRunning,
        executableResolver: @escaping ExecutableResolver,
        appServerTimeout: TimeInterval = 10,
        queueTimeout: TimeInterval = 20
    ) {
        self.processRunner = processRunner
        self.executableResolver = executableResolver
        self.appServerTimeout = appServerTimeout
        self.queueTimeout = queueTimeout
    }

    public func readUsage() async throws -> CodexUsageSnapshot {
        let initialize = ["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "codex_idea_dock", "title": "Reroute", "version": "0.1.0"]]] as [String: Any]
        let messages: [[String: Any]] = [initialize, ["method": "initialized"], ["method": "account/rateLimits/read", "id": 2]]
        var input = Data()
        for message in messages {
            input.append(try JSONSerialization.data(withJSONObject: message))
            input.append(0x0A)
        }
        let result = try await processRunner.run(executableURL: executableResolver(), arguments: Self.appServerArguments, standardInput: input, timeout: appServerTimeout)
        guard !result.timedOut, result.exitCode == 0 else { throw CodexBridgeError.invalidResponse }
        return try CodexUsageSnapshot.parse(result.stdout)
    }

    public func listThreads() async throws -> [WorkContextItem] {
        let executableURL = try executableResolver()
        var cursor: String?
        var seenCursors = Set<String>()
        var contextsByID: [String: WorkContextItem] = [:]

        for pageIndex in 0..<Self.maximumPageCount {
            let page = try await listPage(executableURL: executableURL, cursor: cursor)

            for thread in page.data where contextsByID[thread.id] == nil {
                contextsByID[thread.id] = thread.workContext
            }

            guard let nextCursor = page.nextCursor?.nonEmpty else {
                return contextsByID.values.sorted(by: Self.sortContexts)
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw CodexBridgeError.repeatedCursor
            }
            guard pageIndex + 1 < Self.maximumPageCount else {
                throw CodexBridgeError.tooManyPages
            }

            cursor = nextCursor
        }

        throw CodexBridgeError.tooManyPages
    }

    public func queue(message: String, to threadID: String) async -> QueueDeliveryOutcome {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(exitCode: nil, message: QueueDeliveryDiagnostic.emptyMessage.rawValue)
        }
        guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(exitCode: nil, message: QueueDeliveryDiagnostic.emptyTarget.rawValue)
        }
        guard UUID(uuidString: threadID) != nil else {
            return .failed(exitCode: nil, message: QueueDeliveryDiagnostic.invalidTarget.rawValue)
        }

        let executableURL: URL
        do {
            executableURL = try executableResolver()
        } catch {
            let diagnostic: QueueDeliveryDiagnostic = if case CodexBridgeError.executableNotFound = error {
                .cliUnavailable
            } else {
                .launchFailed
            }
            return .failed(
                exitCode: nil,
                message: diagnostic.rawValue
            )
        }

        do {
            let result = try await processRunner.run(
                executableURL: executableURL,
                arguments: ["queue", "--thread", threadID, "--message", message],
                standardInput: nil,
                timeout: queueTimeout
            )

            if result.timedOut {
                return .unknown(message: QueueDeliveryDiagnostic.confirmationTimedOut.rawValue)
            }
            if result.terminationReason != .exit {
                return .unknown(message: QueueDeliveryDiagnostic.resultUnclear.rawValue)
            }
            if result.exitCode == 0 {
                return .queued(exitCode: result.exitCode)
            }

            if let diagnostic = Self.classifyQueueFailure(result.stderr) {
                return .failed(exitCode: result.exitCode, message: diagnostic.rawValue)
            }
            return .unknown(message: QueueDeliveryDiagnostic.resultUnclear.rawValue)
        } catch {
            return .failed(
                exitCode: nil,
                message: QueueDeliveryDiagnostic.launchFailed.rawValue
            )
        }
    }

    public static func resolveCodexExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]

        if let path = environment["PATH"] {
            candidates.append(
                contentsOf: path
                    .split(separator: ":")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
            )
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        throw CodexBridgeError.executableNotFound
    }

    private func listPage(executableURL: URL, cursor: String?) async throws -> ThreadListResult {
        let input = try AppServerRequest.listThreads(cursor: cursor)
        let result = try await processRunner.run(
            executableURL: executableURL,
            arguments: Self.appServerArguments,
            standardInput: input,
            timeout: appServerTimeout
        )

        if result.timedOut {
            throw CodexBridgeError.timedOut(operation: "Loading Codex tasks")
        }
        guard result.exitCode == 0 else {
            throw CodexBridgeError.processFailed(
                exitCode: result.exitCode,
                message: Self.compactDiagnostic(
                    result.stderr,
                    fallback: "Codex app-server failed."
                )
            )
        }

        return try AppServerResponseParser.parseThreadList(result.stdout)
    }

    private static func sortContexts(_ left: WorkContextItem, _ right: WorkContextItem) -> Bool {
        if left.recency == right.recency {
            return left.id < right.id
        }
        return left.recency > right.recency
    }

    private static func compactDiagnostic(
        _ data: Data,
        fallback: String
    ) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return compactText(text, fallback: fallback)
    }

    private static func compactText(
        _ text: String,
        fallback: String
    ) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.contains("could not create PATH aliases") }

        guard !lines.isEmpty else {
            return fallback
        }

        let compacted = lines.suffix(2).joined(separator: " ")
        if compacted.count <= 240 {
            return compacted
        }
        return String(compacted.prefix(237)) + "..."
    }

    private static func classifyQueueFailure(_ data: Data) -> QueueDeliveryDiagnostic? {
        let diagnostic = String(decoding: data, as: UTF8.self).lowercased()

        if diagnostic.contains("unknown command")
            || diagnostic.contains("unknown subcommand")
            || diagnostic.contains("unrecognized subcommand")
            || diagnostic.contains("unexpected argument 'queue'")
            || diagnostic.contains("unexpected argument '--thread'")
            || diagnostic.contains("unexpected argument '--message'") {
            return .queueUnsupported
        }
        if diagnostic.contains("permission denied")
            || diagnostic.contains("operation not permitted")
            || diagnostic.contains("not authorized") {
            return .permissionDenied
        }
        if diagnostic.contains("thread")
            && (diagnostic.contains("not found")
                || diagnostic.contains("does not exist")
                || diagnostic.contains("unknown")
                || diagnostic.contains("no rollout")) {
            return .targetUnavailable
        }
        return nil
    }
}

private final class DataReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let maximumByteCount: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    private var didFinish = false
    private var responseScanOffset = 0
    private var responseIDs = Set<Int>()

    init(fileHandle: FileHandle, maximumByteCount: Int) {
        self.fileHandle = fileHandle
        self.maximumByteCount = maximumByteCount
    }

    func start() {
        group.enter()
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                finishReading()
            } else {
                lock.withLock {
                    let remainingByteCount = maximumByteCount - data.count
                    guard remainingByteCount > 0 else { return }
                    data.append(chunk.prefix(remainingByteCount))
                }
            }
        }
    }

    func containsJSONResponse(id: Int) -> Bool {
        lock.withLock {
            scanCompleteJSONLines()
            return responseIDs.contains(id)
        }
    }

    func finish(waitingUpTo timeout: TimeInterval) -> Data {
        if group.wait(timeout: .now() + timeout) == .timedOut {
            finishReading()
        }
        return lock.withLock { data }
    }

    private func scanCompleteJSONLines() {
        guard responseScanOffset < data.count else { return }
        let decoder = JSONDecoder()

        while responseScanOffset < data.count,
              let newlineIndex = data[responseScanOffset...].firstIndex(of: 0x0A) {
            let line = data[responseScanOffset..<newlineIndex]
            responseScanOffset = newlineIndex + 1
            guard let metadata = try? decoder.decode(
                RPCResponseMetadata.self,
                from: Data(line)
            ), let id = metadata.id else {
                continue
            }
            responseIDs.insert(id)
        }
    }

    private func finishReading() {
        fileHandle.readabilityHandler = nil
        let shouldLeave = lock.withLock {
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldLeave {
            group.leave()
        }
    }

    deinit {
        finishReading()
    }
}

private enum AppServerRequest {
    private static let initializeID = 1
    private static let listThreadsID = 2

    static func listThreads(cursor: String?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let initialize = RPCRequest(
            method: "initialize",
            id: initializeID,
            params: InitializeParameters(
                clientInfo: ClientInfo(
                    // Stable protocol identifier retained for compatibility across the rebrand.
                    name: "codex_idea_dock",
                    title: "FlowCue",
                    version: "0.1.0"
                )
            )
        )
        let initialized = RPCNotification(
            method: "initialized",
            params: EmptyParameters()
        )
        let list = RPCRequest(
            method: "thread/list",
            id: listThreadsID,
            params: ThreadListParameters(
                cursor: cursor,
                limit: CodexBridge.pageLimit,
                sortKey: "recency_at",
                sortDirection: "desc",
                archived: false,
                useStateDbOnly: true,
                sourceKinds: CodexBridge.sourceKinds
            )
        )

        var input = Data()
        for message in [try encoder.encode(initialize), try encoder.encode(initialized), try encoder.encode(list)] {
            input.append(message)
            input.append(0x0A)
        }
        return input
    }
}

private enum AppServerResponseParser {
    static func containsResponse(_ data: Data, id: Int) -> Bool {
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }

        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let metadata = try? decoder.decode(
                RPCResponseMetadata.self,
                from: Data(line.utf8)
            ) else {
                return false
            }
            return metadata.id == id
        }
    }

    static func parseThreadList(_ data: Data) throws -> ThreadListResult {
        guard let output = String(data: data, encoding: .utf8) else {
            throw CodexBridgeError.invalidResponse
        }

        let decoder = JSONDecoder()
        var didInitialize = false
        var listResult: ThreadListResult?

        for line in output.split(whereSeparator: \Character.isNewline) {
            let lineData = Data(line.utf8)
            guard let metadata = try? decoder.decode(RPCResponseMetadata.self, from: lineData),
                  let id = metadata.id else {
                continue
            }

            if let error = metadata.error {
                throw CodexBridgeError.rpc(
                    code: error.code,
                    message: compactRPCMessage(error.message)
                )
            }

            switch id {
            case 1:
                didInitialize = true
            case 2:
                let response = try decoder.decode(ThreadListResponse.self, from: lineData)
                listResult = response.result
            default:
                continue
            }
        }

        guard didInitialize, let listResult else {
            throw CodexBridgeError.invalidResponse
        }
        return listResult
    }

    private static func compactRPCMessage(_ message: String) -> String {
        let compacted = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compacted.isEmpty else {
            return "Unknown error"
        }
        if compacted.count <= 240 {
            return compacted
        }
        return String(compacted.prefix(237)) + "..."
    }
}

private struct RPCRequest<Parameters: Encodable>: Encodable {
    let method: String
    let id: Int
    let params: Parameters
}

private struct RPCNotification<Parameters: Encodable>: Encodable {
    let method: String
    let params: Parameters
}

private struct EmptyParameters: Encodable {}

private struct InitializeParameters: Encodable {
    let clientInfo: ClientInfo
}

private struct ClientInfo: Encodable {
    let name: String
    let title: String
    let version: String
}

private struct ThreadListParameters: Encodable {
    let cursor: String?
    let limit: Int
    let sortKey: String
    let sortDirection: String
    let archived: Bool
    let useStateDbOnly: Bool
    let sourceKinds: [String]
}

private struct RPCResponseMetadata: Decodable {
    let id: Int?
    let error: RPCErrorPayload?
}

private struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

private struct ThreadListResponse: Decodable {
    let result: ThreadListResult?
}

private struct ThreadListResult: Decodable {
    let data: [AppServerThread]
    let nextCursor: String?
}

private struct AppServerThread: Decodable {
    let id: String
    let name: String?
    let preview: String?
    let cwd: String?
    let projectID: String?
    let isPinned: Bool?
    let recencyAt: TimeInterval?
    let updatedAt: TimeInterval?
    let createdAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case preview
        case cwd
        case projectID = "projectId"
        case isPinned
        case recencyAt
        case updatedAt
        case createdAt
    }

    var workContext: WorkContextItem {
        WorkContextItem(
            id: id,
            title: displayTitle,
            projectDirectory: cwd?.nonEmpty,
            projectID: projectID?.nonEmpty,
            isPinned: isPinned ?? false,
            recency: Date(timeIntervalSince1970: recencyTimestamp)
        )
    }

    private var displayTitle: String {
        name?.nonEmpty ?? preview?.nonEmpty ?? "Untitled task"
    }

    private var recencyTimestamp: TimeInterval {
        recencyAt ?? updatedAt ?? createdAt ?? 0
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
