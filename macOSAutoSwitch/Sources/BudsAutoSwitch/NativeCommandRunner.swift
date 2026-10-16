import Foundation
import Darwin

struct CommandResult { let code: Int32; let output: String }
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// Commands never use a shell. A deadline terminates a stuck child process.
func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 15) async throws -> CommandResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let hardDeadline = DispatchWorkItem {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            let deadline = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: hardDeadline)
                }
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                // Drain while running; command output must not fill the pipe.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                hardDeadline.cancel()
                continuation.resume(returning: CommandResult(code: process.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)))
            } catch {
                deadline.cancel()
                hardDeadline.cancel()
                continuation.resume(throwing: error)
            }
        }
    }
}

