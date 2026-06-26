import Foundation

public final class DisplayManager: @unchecked Sendable {
    public static let defaultExternalPrivacyHideInput = 17
    public static let defaultExternalPrivacyRestoreInput = 15

    private let runner: CommandRunning
    private let preferredExternalTool: String
    private let internalControllerProvider: () throws -> any InternalBrightnessControlling
    private let externalPowerControllerProvider: () -> any ExternalPowerControlling

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        preferredExternalTool: String = "auto",
        internalControllerProvider: @escaping () throws -> any InternalBrightnessControlling = { try DisplayServicesController() },
        externalPowerControllerProvider: (() -> any ExternalPowerControlling)? = nil
    ) {
        self.runner = runner
        self.preferredExternalTool = preferredExternalTool
        self.internalControllerProvider = internalControllerProvider
        self.externalPowerControllerProvider = externalPowerControllerProvider ?? {
            ExternalPowerControllerFactory.make(preferredTool: preferredExternalTool, runner: runner)
        }
    }

    public func loadSnapshot() throws -> DisplaySnapshot {
        let displays = try loadDisplays()
        let brightnessByDisplayID = loadCoreBrightnessValues()
        let externalBackend = ExternalBackendFactory.make(preferredTool: preferredExternalTool, runner: runner)
        let internalController = try? internalControllerProvider()

        var externalIndex = 0
        let statuses: [DisplayStatus] = displays.map { display in
            if display.kind == .internal {
                return internalStatus(
                    display: display,
                    brightnessByDisplayID: brightnessByDisplayID,
                    internalController: internalController
                )
            }

            externalIndex += 1
            return externalStatus(
                display: display,
                externalIndex: externalIndex,
                externalBackend: externalBackend
            )
        }

        return DisplaySnapshot(displays: statuses, externalBackendName: externalBackend?.name)
    }

    public func setBrightness(_ percent: Int, for status: DisplayStatus) throws {
        switch status.display.kind {
        case .internal:
            guard let displayID = status.display.displayID else {
                throw BrightnessError.missingDisplayID(status.display.name)
            }
            try internalControllerProvider().setBrightness(displayID: displayID, percent: percent)
        case .external:
            guard let backend = ExternalBackendFactory.make(preferredTool: preferredExternalTool, runner: runner) else {
                throw BrightnessError.missingExternalBackend
            }
            guard let externalIndex = status.externalIndex else {
                throw BrightnessError.invalidOutput("External display has no index.")
            }
            try backend.setBrightness(displayIndex: externalIndex, percent: percent)
        }
    }

    public func setBrightness(_ percent: Int, target: DisplayTarget) throws {
        let snapshot = try loadSnapshot()
        for status in snapshot.displays where matches(status, target: target) {
            try setBrightness(percent, for: status)
        }
    }

    public func disconnectExternalDisplays() throws {
        let displays = try loadDisplays()
        let externalDisplays = displays.filter { $0.kind == .external }
        guard !externalDisplays.isEmpty else { return }

        let powerController = externalPowerControllerProvider()
        for externalIndex in 1...externalDisplays.count {
            try powerController.setPowerMode(displayIndex: externalIndex, mode: .off)
        }
    }

    public func enablePrivacyMode(
        hideInput: Int = DisplayManager.defaultExternalPrivacyHideInput,
        fallbackRestoreInput: Int = DisplayManager.defaultExternalPrivacyRestoreInput
    ) throws -> DisplayPrivacyModeSnapshot {
        let snapshot = try capturePrivacyModeSnapshot(fallbackRestoreInput: fallbackRestoreInput)
        try enforcePrivacyMode(using: snapshot, hideInput: hideInput)
        return snapshot
    }

    public func enforcePrivacyMode(
        using snapshot: DisplayPrivacyModeSnapshot,
        hideInput: Int = DisplayManager.defaultExternalPrivacyHideInput
    ) throws {
        _ = hideInput
        let internalController = try internalControllerProvider()
        for display in snapshot.internalDisplays {
            try internalController.setBrightness(displayID: display.displayID, percent: 0)
        }

        try disconnectExternalDisplays()
    }

    public func restorePrivacyMode(from snapshot: DisplayPrivacyModeSnapshot) throws {
        let internalController = try internalControllerProvider()
        for display in snapshot.internalDisplays {
            if let brightnessPercent = display.brightnessPercent {
                try internalController.setBrightness(displayID: display.displayID, percent: brightnessPercent)
            }
        }

    }

    public func setExternalPrivacyMode(
        enabled: Bool,
        hideInput: Int = DisplayManager.defaultExternalPrivacyHideInput,
        restoreInput: Int = DisplayManager.defaultExternalPrivacyRestoreInput
    ) throws {
        _ = hideInput
        _ = restoreInput
        if enabled {
            try disconnectExternalDisplays()
        }
    }

    private func capturePrivacyModeSnapshot(fallbackRestoreInput: Int) throws -> DisplayPrivacyModeSnapshot {
        let displays = try loadDisplays()
        let brightnessByDisplayID = loadCoreBrightnessValues()
        let hasInternalDisplay = displays.contains { $0.kind == .internal }
        let internalController = hasInternalDisplay ? try internalControllerProvider() : nil

        var internalDisplays: [InternalPrivacyDisplayState] = []

        for display in displays where display.kind == .internal {
            guard let displayID = display.displayID else {
                throw BrightnessError.missingDisplayID(display.name)
            }
            let fallbackBrightness = try? internalController?.readBrightness(displayID: displayID)
            internalDisplays.append(
                InternalPrivacyDisplayState(
                    displayID: displayID,
                    brightnessPercent: brightnessByDisplayID[displayID]?.percent ?? fallbackBrightness ?? nil
                )
            )
        }

        return DisplayPrivacyModeSnapshot(
            internalDisplays: internalDisplays,
            externalDisplays: []
        )
    }

    private func loadDisplays() throws -> [DisplayInfo] {
        let command = ["system_profiler", "SPDisplaysDataType", "-json"]
        let result = try runner.run(command)
        return try SystemProfilerParser.parseDisplays(from: requireSuccessful(result, command: command).stdout)
    }

    private func loadCoreBrightnessValues() -> [UInt32: BrightnessInfo] {
        let command = ["/usr/libexec/corebrightnessdiag", "status-info"]
        guard let result = try? runner.run(command), result.exitCode == 0 else {
            return [:]
        }
        return CoreBrightnessParser.parseStatusInfo(result.stdout)
    }

    private func internalStatus(
        display: DisplayInfo,
        brightnessByDisplayID: [UInt32: BrightnessInfo],
        internalController: (any InternalBrightnessControlling)?
    ) -> DisplayStatus {
        guard let displayID = display.displayID else {
            return DisplayStatus(
                display: display,
                brightnessPercent: nil,
                canChange: false,
                source: nil,
                externalIndex: nil,
                note: "Missing display id"
            )
        }

        if let info = brightnessByDisplayID[displayID], let percent = info.percent {
            return DisplayStatus(
                display: display,
                brightnessPercent: percent,
                canChange: info.canChange,
                source: "corebrightnessdiag",
                externalIndex: nil,
                note: nil
            )
        }

        let fallback = try? internalController?.readBrightness(displayID: displayID)
        return DisplayStatus(
            display: display,
            brightnessPercent: fallback ?? nil,
            canChange: fallback != nil,
            source: fallback == nil ? nil : "DisplayServices",
            externalIndex: nil,
            note: fallback == nil ? "Could not read internal brightness" : nil
        )
    }

    private func externalStatus(
        display: DisplayInfo,
        externalIndex: Int,
        externalBackend: ExternalBrightnessBackend?
    ) -> DisplayStatus {
        guard let externalBackend else {
            return DisplayStatus(
                display: display,
                brightnessPercent: nil,
                canChange: false,
                source: nil,
                externalIndex: externalIndex,
                note: "Install m1ddc or ddcctl to control external brightness"
            )
        }

        let percent = try? externalBackend.readBrightness(displayIndex: externalIndex)
        return DisplayStatus(
            display: display,
            brightnessPercent: percent ?? nil,
            canChange: true,
            source: externalBackend.name,
            externalIndex: externalIndex,
            note: percent == nil ? "External brightness read failed" : nil
        )
    }

    private func matches(_ status: DisplayStatus, target: DisplayTarget) -> Bool {
        switch target {
        case .all:
            return true
        case .internal:
            return status.display.kind == .internal
        case .external:
            return status.display.kind == .external
        }
    }
}
