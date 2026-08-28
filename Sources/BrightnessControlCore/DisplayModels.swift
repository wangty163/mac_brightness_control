import Foundation

public enum DisplayKind: String, Codable, Sendable {
    case `internal`
    case external
}

public struct DisplayInfo: Equatable, Sendable {
    public let displayID: UInt32?
    public let name: String
    public let kind: DisplayKind
    public let online: Bool
    public let resolution: String?
    public let connectionType: String?

    public init(
        displayID: UInt32?,
        name: String,
        kind: DisplayKind,
        online: Bool,
        resolution: String?,
        connectionType: String?
    ) {
        self.displayID = displayID
        self.name = name
        self.kind = kind
        self.online = online
        self.resolution = resolution
        self.connectionType = connectionType
    }
}

public struct BrightnessInfo: Equatable, Sendable {
    public let brightness: Double?
    public let canChange: Bool

    public init(brightness: Double?, canChange: Bool) {
        self.brightness = brightness
        self.canChange = canChange
    }

    public var percent: Int? {
        guard let brightness else { return nil }
        return Int((brightness * 100).rounded())
    }
}

public struct DisplayStatus: Identifiable, Equatable, Sendable {
    public let id: String
    public let display: DisplayInfo
    public let brightnessPercent: Int?
    public let canChange: Bool
    public let source: String?
    public let externalIndex: Int?
    public let note: String?

    public init(
        display: DisplayInfo,
        brightnessPercent: Int?,
        canChange: Bool,
        source: String?,
        externalIndex: Int?,
        note: String?
    ) {
        self.display = display
        self.brightnessPercent = brightnessPercent
        self.canChange = canChange
        self.source = source
        self.externalIndex = externalIndex
        self.note = note
        if display.kind == .internal, let displayID = display.displayID {
            self.id = "internal-\(displayID)"
        } else if let externalIndex {
            self.id = "external-\(externalIndex)"
        } else {
            self.id = "\(display.kind.rawValue)-\(display.name)"
        }
    }
}

public struct DisplaySnapshot: Equatable, Sendable {
    public let displays: [DisplayStatus]
    public let externalBackendName: String?

    public init(displays: [DisplayStatus], externalBackendName: String?) {
        self.displays = displays
        self.externalBackendName = externalBackendName
    }

    public var externalPresent: Bool {
        displays.contains { $0.display.kind == .external }
    }
}

public struct InternalPrivacyDisplayState: Equatable, Sendable {
    public let displayID: UInt32
    public let brightnessPercent: Int?

    public init(displayID: UInt32, brightnessPercent: Int?) {
        self.displayID = displayID
        self.brightnessPercent = brightnessPercent
    }
}

public struct ExternalPrivacyDisplayState: Codable, Equatable, Sendable {
    public let displayIndex: Int
    public let brightnessPercent: Int?
    public let restoreInput: Int

    public init(displayIndex: Int, brightnessPercent: Int?, restoreInput: Int) {
        self.displayIndex = displayIndex
        self.brightnessPercent = brightnessPercent
        self.restoreInput = restoreInput
    }
}

public struct DisplayPrivacyModeSnapshot: Equatable, Sendable {
    public let internalDisplays: [InternalPrivacyDisplayState]
    public let externalDisplays: [ExternalPrivacyDisplayState]

    public init(
        internalDisplays: [InternalPrivacyDisplayState],
        externalDisplays: [ExternalPrivacyDisplayState]
    ) {
        self.internalDisplays = internalDisplays
        self.externalDisplays = externalDisplays
    }
}

public enum DisplayTarget: Equatable, Sendable {
    case all
    case `internal`
    case external
}

public enum BrightnessError: Error, LocalizedError, Equatable {
    case commandFailed(command: [String], exitCode: Int32, stderr: String)
    case invalidOutput(String)
    case missingDisplayID(String)
    case missingExternalBackend
    case missingExternalInputBackend
    case missingDisplayServicesSymbol(String)
    case displayServicesFailed(operation: String, code: Int32)
    case noKnownExternalDisplay

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, exitCode, stderr):
            return "\(command.joined(separator: " ")) failed with \(exitCode): \(stderr)"
        case let .invalidOutput(message):
            return message
        case let .missingDisplayID(name):
            return "Display \(name) has no display id."
        case .missingExternalBackend:
            return "No external brightness backend found. Install m1ddc or ddcctl."
        case .missingExternalInputBackend:
            return "No external input switching backend found. Install m1ddc."
        case let .missingDisplayServicesSymbol(name):
            return "DisplayServices symbol not found: \(name)"
        case let .displayServicesFailed(operation, code):
            return "DisplayServices \(operation) failed with code \(code)."
        case .noKnownExternalDisplay:
            return "No known external display is available for DDC power-off. Open the lid or reconnect the display, wait for detection, then try again."
        }
    }
}
