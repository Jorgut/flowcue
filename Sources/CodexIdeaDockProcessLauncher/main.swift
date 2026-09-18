import Darwin
import Foundation

private func exitWithSystemError(_ operation: String, code: Int32) -> Never {
    let message = String(cString: strerror(errno))
    FileHandle.standardError.write(Data("\(operation): \(message)\n".utf8))
    exit(code)
}

private func writeAtomically(_ text: String, to path: String) -> Bool {
    let temporaryPath = "\(path).\(getpid()).tmp"
    let descriptor = temporaryPath.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { return false }

    let bytes = Array(text.utf8)
    let writtenByteCount = bytes.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress, buffer.count)
    }
    let syncResult = fsync(descriptor)
    Darwin.close(descriptor)
    guard writtenByteCount == bytes.count, syncResult == 0 else {
        unlink(temporaryPath)
        return false
    }
    guard rename(temporaryPath, path) == 0 else {
        unlink(temporaryPath)
        return false
    }
    return true
}

private func acknowledged(
    at path: String,
    processID: pid_t
) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 64 else {
        return false
    }
    let text = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return pid_t(text) == processID
}

guard CommandLine.arguments.count >= 6,
      CommandLine.arguments[1] == "--handshake-directory",
      CommandLine.arguments[3] == "--parent-process",
      let parentProcessID = pid_t(CommandLine.arguments[4]),
      parentProcessID > 1 else {
    FileHandle.standardError.write(Data("Invalid process-launcher arguments.\n".utf8))
    exit(64)
}

guard setpgid(0, 0) == 0 else {
    exitWithSystemError("setpgid", code: 71)
}

let handshakeDirectory = CommandLine.arguments[2]
let readyPath = URL(fileURLWithPath: handshakeDirectory).appendingPathComponent("ready").path
let acknowledgementPath = URL(fileURLWithPath: handshakeDirectory).appendingPathComponent("ack").path
let processID = getpid()
guard writeAtomically("\(processID)\n", to: readyPath) else {
    exitWithSystemError("ready handshake", code: 71)
}

let handshakeDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
while !acknowledged(at: acknowledgementPath, processID: processID) {
    if Darwin.kill(parentProcessID, 0) != 0, errno == ESRCH {
        exit(72)
    }
    if DispatchTime.now().uptimeNanoseconds >= handshakeDeadline {
        exit(72)
    }
    usleep(5_000)
}

unlink(readyPath)
unlink(acknowledgementPath)
rmdir(handshakeDirectory)

let executablePath = CommandLine.arguments[5]
let forwardedArguments = Array(CommandLine.arguments.dropFirst(5))
var argumentStorage: [UnsafeMutablePointer<CChar>] = []
for argument in forwardedArguments {
    guard let duplicate = strdup(argument) else {
        FileHandle.standardError.write(Data("Unable to allocate process arguments.\n".utf8))
        exit(71)
    }
    argumentStorage.append(duplicate)
}
defer {
    argumentStorage.forEach { free($0) }
}
var argumentPointers: [UnsafeMutablePointer<CChar>?] = argumentStorage.map { $0 }
argumentPointers.append(nil)

_ = executablePath.withCString { executablePointer in
    execv(executablePointer, &argumentPointers)
}
exitWithSystemError("execv", code: 69)
