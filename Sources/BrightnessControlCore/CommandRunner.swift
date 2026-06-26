import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: AnyObject {
    func run(_ command: [String]) throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: [String]) throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        if let first = command.first, first.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: first)
            process.arguments = Array(command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }

        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdoutText, stderr: stderrText)
    }
}

func requireSuccessful(_ result: CommandResult, command: [String]) throws -> CommandResult {
    guard result.exitCode == 0 else {
        throw BrightnessError.commandFailed(
            command: command,
            exitCode: result.exitCode,
            stderr: result.stderr.isEmpty ? result.stdout : result.stderr
        )
    }
    return result
}
