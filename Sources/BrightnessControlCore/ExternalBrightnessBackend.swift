import DDCPower
import Foundation

public protocol ExternalBrightnessBackend: AnyObject {
    var name: String { get }
    func readBrightness(displayIndex: Int) throws -> Int?
    func setBrightness(displayIndex: Int, percent: Int) throws
}

public protocol ExternalInputSwitchingBackend: ExternalBrightnessBackend {
    func readInput(displayIndex: Int) throws -> Int?
    func setInput(displayIndex: Int, input: Int) throws
}

public enum ExternalPowerMode: UInt8, Equatable, Sendable {
    case on = 1
    case off = 5
}

public protocol ExternalPowerControlling: AnyObject {
    var name: String { get }
    func setPowerMode(displayIndex: Int, mode: ExternalPowerMode) throws
}

public final class DirectDDCPowerController: ExternalPowerControlling {
    public let name = "DDC power"

    public init() {}

    public func setPowerMode(displayIndex: Int, mode: ExternalPowerMode) throws {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let status = BCDDCSetExternalDisplayPower(
            UInt32(displayIndex),
            mode.rawValue,
            &errorBuffer,
            errorBuffer.count
        )

        guard status == 0 else {
            let messageBytes = errorBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let message = String(decoding: messageBytes, as: UTF8.self)
            throw BrightnessError.invalidOutput(message.isEmpty ? "Failed to set external display power." : message)
        }
    }
}

public final class M1DDCPowerController: ExternalPowerControlling {
    public let name = "m1ddc"
    private let path: String
    private let runner: CommandRunning

    public init(path: String, runner: CommandRunning) {
        self.path = path
        self.runner = runner
    }

    public func setPowerMode(displayIndex: Int, mode: ExternalPowerMode) throws {
        let command = [path, "display", "\(displayIndex)", "set", "standby", "\(mode.rawValue)"]
        let result = try runner.run(command)
        _ = try requireSuccessful(result, command: command)
    }
}

public enum ExternalPowerControllerFactory {
    public static func make(preferredTool: String = "auto", runner: CommandRunning) -> any ExternalPowerControlling {
        if preferredTool == "auto" || preferredTool == "m1ddc" {
            if let path = findExecutable("m1ddc", runner: runner) {
                return M1DDCPowerController(path: path, runner: runner)
            }
        }
        return DirectDDCPowerController()
    }

    private static func findExecutable(_ name: String, runner: CommandRunning) -> String? {
        if let result = try? runner.run(["/usr/bin/which", name]), result.exitCode == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

public final class M1DDCBackend: ExternalInputSwitchingBackend {
    public let name = "m1ddc"
    private let path: String
    private let runner: CommandRunning

    public init(path: String, runner: CommandRunning) {
        self.path = path
        self.runner = runner
    }

    public func readBrightness(displayIndex: Int) throws -> Int? {
        let command = [path, "display", "\(displayIndex)", "get", "luminance"]
        let result = try runner.run(command)
        guard result.exitCode == 0 else { return nil }
        return parseFirstInteger(result.stdout)
    }

    public func setBrightness(displayIndex: Int, percent: Int) throws {
        let command = [path, "display", "\(displayIndex)", "set", "luminance", "\(percent)"]
        let result = try runner.run(command)
        _ = try requireSuccessful(result, command: command)
    }

    public func readInput(displayIndex: Int) throws -> Int? {
        let command = [path, "display", "\(displayIndex)", "get", "input"]
        let result = try runner.run(command)
        guard result.exitCode == 0 else { return nil }
        return parseFirstInteger(result.stdout)
    }

    public func setInput(displayIndex: Int, input: Int) throws {
        let command = [path, "display", "\(displayIndex)", "set", "input", "\(input)"]
        let result = try runner.run(command)
        _ = try requireSuccessful(result, command: command)
    }
}

public final class DDCCTLBackend: ExternalBrightnessBackend {
    public let name = "ddcctl"
    private let path: String
    private let runner: CommandRunning

    public init(path: String, runner: CommandRunning) {
        self.path = path
        self.runner = runner
    }

    public func readBrightness(displayIndex: Int) throws -> Int? {
        let command = [path, "-d", "\(displayIndex)", "-b", "?"]
        let result = try runner.run(command)
        guard result.exitCode == 0 else { return nil }
        let text = result.stdout + "\n" + result.stderr
        if let raw = firstMatch(in: text, pattern: #"current value\s*=\s*([0-9]+)"#) {
            return Int(raw)
        }
        return parseFirstInteger(text)
    }

    public func setBrightness(displayIndex: Int, percent: Int) throws {
        let command = [path, "-d", "\(displayIndex)", "-b", "\(percent)"]
        let result = try runner.run(command)
        _ = try requireSuccessful(result, command: command)
    }
}

public enum ExternalBackendFactory {
    public static func make(preferredTool: String = "auto", runner: CommandRunning) -> ExternalBrightnessBackend? {
        if preferredTool == "none" {
            return nil
        }
        if preferredTool == "auto" || preferredTool == "m1ddc" {
            if let path = findExecutable("m1ddc", runner: runner) {
                return M1DDCBackend(path: path, runner: runner)
            }
            if preferredTool == "m1ddc" {
                return nil
            }
        }
        if preferredTool == "auto" || preferredTool == "ddcctl" {
            if let path = findExecutable("ddcctl", runner: runner) {
                return DDCCTLBackend(path: path, runner: runner)
            }
        }
        return nil
    }

    private static func findExecutable(_ name: String, runner: CommandRunning) -> String? {
        if let result = try? runner.run(["/usr/bin/which", name]), result.exitCode == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return nil
    }
}

private func parseFirstInteger(_ text: String) -> Int? {
    firstMatch(in: text, pattern: #"([0-9]+)"#).flatMap(Int.init)
}
