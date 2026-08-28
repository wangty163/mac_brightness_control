import BrightnessControlCore
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(description: message)
    }
}

func testParsesInternalAndExternalDisplaysFromSystemProfilerJSON() throws {
    let json = """
    {
      "SPDisplaysDataType": [
        {
          "_name": "Apple M3 Pro",
          "spdisplays_ndrvs": [
            {
              "_name": "Color LCD",
              "_spdisplays_displayID": "4281106",
              "_spdisplays_resolution": "1512 x 982 @ 120.00Hz",
              "spdisplays_connection_type": "spdisplays_internal",
              "spdisplays_online": "spdisplays_yes"
            },
            {
              "_name": "DELL U2720Q",
              "_spdisplays_displayID": "2",
              "_spdisplays_resolution": "3840 x 2160 @ 60.00Hz",
              "spdisplays_connection_type": "spdisplays_displayport",
              "spdisplays_online": "spdisplays_yes"
            }
          ]
        }
      ]
    }
    """

    let displays = try SystemProfilerParser.parseDisplays(from: json)

    try expect(displays.map(\.name) == ["Color LCD", "DELL U2720Q"], "display names")
    try expect(displays.map(\.kind) == [.internal, .external], "display kinds")
    try expect(displays[0].displayID == 0x4281106, "hexadecimal internal display id")
    try expect(displays[1].displayID == 2, "external display id")
    try expect(displays[1].resolution == "3840 x 2160 @ 60.00Hz", "external resolution")
}

func testParsesGPUWithoutConnectedDisplays() throws {
    let json = """
    {
      "SPDisplaysDataType": [
        {
          "_name": "Apple M3 Pro",
          "spdisplays_metal": "spdisplays_supported"
        }
      ]
    }
    """

    let displays = try SystemProfilerParser.parseDisplays(from: json)
    try expect(displays.isEmpty, "missing display list should mean no connected displays")
}

func testParsesDisplayServicesBrightnessByDisplayID() throws {
    let text = """
        Display =             {
            CBDisplayInfo =                 {
                CBDisplayInfoDeviceID = 437025420722831360;
                CBDisplayInfoDisplayID = 1;
            };
            DisplayServicesBrightness = "0.1";
            DisplayServicesCanChangeBrightness = 1;
        };
        Display =             {
            CBDisplayInfo =                 {
                CBDisplayInfoDisplayID = 12;
            };
            DisplayServicesBrightness = 0;
            DisplayServicesCanChangeBrightness = 0;
        };
    """

    let brightness = CoreBrightnessParser.parseStatusInfo(text)

    try expect(brightness[1]?.percent == 10, "display 1 brightness")
    try expect(brightness[1]?.canChange == true, "display 1 can change")
    try expect(brightness[12]?.percent == 0, "display 12 brightness")
    try expect(brightness[12]?.canChange == false, "display 12 can change")
}

func testM1DDCBackendBuildsGetAndSetCommands() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "37\n", stderr: "")
    ])
    let backend = M1DDCBackend(path: "/opt/homebrew/bin/m1ddc", runner: runner)

    let value = try backend.readBrightness(displayIndex: 2)
    try backend.setBrightness(displayIndex: 2, percent: 8)

    try expect(value == 37, "m1ddc read value")
    try expect(
        runner.commands == [
            ["/opt/homebrew/bin/m1ddc", "display", "2", "get", "luminance"],
            ["/opt/homebrew/bin/m1ddc", "display", "2", "set", "luminance", "8"]
        ],
        "m1ddc commands"
    )
}

func testM1DDCBackendBuildsInputCommand() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "17\n", stderr: "")
    ])
    let backend = M1DDCBackend(path: "/opt/homebrew/bin/m1ddc", runner: runner)

    try backend.setInput(displayIndex: 1, input: 17)

    try expect(
        runner.commands == [
            ["/opt/homebrew/bin/m1ddc", "display", "1", "set", "input", "17"]
        ],
        "m1ddc input command"
    )
}

func testM1DDCBackendReadsInputCommand() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "15\n", stderr: "")
    ])
    let backend = M1DDCBackend(path: "/opt/homebrew/bin/m1ddc", runner: runner)

    let value = try backend.readInput(displayIndex: 1)

    try expect(value == 15, "m1ddc input read value")
    try expect(
        runner.commands == [
            ["/opt/homebrew/bin/m1ddc", "display", "1", "get", "input"]
        ],
        "m1ddc input read command"
    )
}

func testM1DDCPowerControllerBuildsStandbyCommand() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "5\n", stderr: "")
    ])
    let controller = M1DDCPowerController(path: "/opt/homebrew/bin/m1ddc", runner: runner)

    try controller.setPowerMode(displayIndex: 1, mode: .off)

    try expect(
        runner.commands == [
            ["/opt/homebrew/bin/m1ddc", "display", "1", "set", "standby", "5"]
        ],
        "m1ddc power-off command"
    )
}

func testExternalPowerControllerFactoryPrefersM1DDC() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "/opt/homebrew/bin/m1ddc\n", stderr: ""),
        CommandResult(exitCode: 0, stdout: "5\n", stderr: "")
    ])

    let controller = ExternalPowerControllerFactory.make(preferredTool: "auto", runner: runner)
    try expect(controller.name == "m1ddc", "m1ddc power controller name")

    try controller.setPowerMode(displayIndex: 1, mode: .off)

    try expect(
        runner.commands == [
            ["/usr/bin/which", "m1ddc"],
            ["/opt/homebrew/bin/m1ddc", "display", "1", "set", "standby", "5"]
        ],
        "m1ddc power controller factory commands"
    )
}

func testExternalPowerControllerFallsBackAfterM1DDCFailure() throws {
    let primary = RecordingExternalPowerController(
        name: "m1ddc",
        failure: BrightnessError.commandFailed(
            command: ["m1ddc"],
            exitCode: 1,
            stderr: "no display"
        )
    )
    let fallback = RecordingExternalPowerController(name: "DDC power")
    let controller = FallbackExternalPowerController(primary: primary, fallback: fallback)

    try controller.setPowerMode(displayIndex: 1, mode: .off)

    try expect(
        primary.setCommands == [ExternalPowerCommand(displayIndex: 1, mode: .off)],
        "primary power command"
    )
    try expect(
        fallback.setCommands == [ExternalPowerCommand(displayIndex: 1, mode: .off)],
        "fallback power command"
    )
}

func testDDCCTLBackendParsesCurrentValueAndBuildsSetCommand() throws {
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: "current value = 63, max value = 100\n", stderr: "")
    ])
    let backend = DDCCTLBackend(path: "/opt/homebrew/bin/ddcctl", runner: runner)

    let value = try backend.readBrightness(displayIndex: 1)
    try backend.setBrightness(displayIndex: 1, percent: 21)

    try expect(value == 63, "ddcctl read value")
    try expect(
        runner.commands == [
            ["/opt/homebrew/bin/ddcctl", "-d", "1", "-b", "?"],
            ["/opt/homebrew/bin/ddcctl", "-d", "1", "-b", "21"]
        ],
        "ddcctl commands"
    )
}

func testDisplayManagerEnablesPrivacyModeCapturesAndForcesDisplays() throws {
    let json = """
    {
      "SPDisplaysDataType": [
        {
          "spdisplays_ndrvs": [
            {
              "_name": "Color LCD",
              "_spdisplays_displayID": "1",
              "spdisplays_connection_type": "spdisplays_internal",
              "spdisplays_online": "spdisplays_yes"
            },
            {
              "_name": "ACER  N270IC",
              "_spdisplays_displayID": "3",
              "spdisplays_online": "spdisplays_yes"
            }
          ]
        }
      ]
    }
    """
    let coreBrightness = """
        Display =             {
            CBDisplayInfo =                 {
                CBDisplayInfoDisplayID = 1;
            };
            DisplayServicesBrightness = "0.56";
            DisplayServicesCanChangeBrightness = 1;
        };
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: json, stderr: ""),
        CommandResult(exitCode: 0, stdout: coreBrightness, stderr: ""),
        CommandResult(exitCode: 0, stdout: json, stderr: "")
    ])
    let internalController = RecordingInternalBrightnessController(readValues: [:])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: { internalController },
        externalPowerControllerProvider: { externalPowerController }
    )

    let snapshot = try manager.enablePrivacyMode()

    try expect(
        snapshot.internalDisplays == [
            InternalPrivacyDisplayState(displayID: 1, brightnessPercent: 56)
        ],
        "captured internal brightness"
    )
    try expect(
        snapshot.externalDisplays == [
            ExternalPrivacyDisplayState(displayIndex: 1, brightnessPercent: nil, restoreInput: 15)
        ],
        "privacy mode captures external display indices"
    )
    try expect(
        internalController.setCommands == [
            InternalSetCommand(displayID: 1, percent: 0)
        ],
        "internal privacy brightness command"
    )
    try expect(
        externalPowerController.setCommands == [
            ExternalPowerCommand(displayIndex: 1, mode: .off)
        ],
        "external privacy power command"
    )
    try expect(
        runner.commands == [
            ["system_profiler", "SPDisplaysDataType", "-json"],
            ["/usr/libexec/corebrightnessdiag", "status-info"]
        ],
        "privacy enable commands"
    )
}

func testDisplayManagerPowersOffExternalDisplaysDirectly() throws {
    let beforeJSON = """
    {
      "SPDisplaysDataType": [
        {
          "spdisplays_ndrvs": [
            {
              "_name": "Color LCD",
              "_spdisplays_displayID": "1",
              "spdisplays_connection_type": "spdisplays_internal",
              "spdisplays_online": "spdisplays_yes"
            },
            {
              "_name": "ACER  N270IC",
              "_spdisplays_displayID": "3",
              "spdisplays_online": "spdisplays_yes"
            }
          ]
        }
      ]
    }
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: beforeJSON, stderr: "")
    ])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: {
            throw BrightnessError.invalidOutput("unused")
        },
        externalPowerControllerProvider: { externalPowerController }
    )

    try manager.disconnectExternalDisplays()

    try expect(
        externalPowerController.setCommands == [
            ExternalPowerCommand(displayIndex: 1, mode: .off)
        ],
        "external power commands"
    )
    try expect(
        runner.commands == [
            ["system_profiler", "SPDisplaysDataType", "-json"]
        ],
        "external power-off display discovery commands"
    )
}

func testDisplayManagerRestoresPrivacyModeSnapshot() throws {
    let runner = RecordingCommandRunner(results: [])
    let internalController = RecordingInternalBrightnessController(readValues: [:])
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: { internalController }
    )
    let snapshot = DisplayPrivacyModeSnapshot(
        internalDisplays: [
            InternalPrivacyDisplayState(displayID: 1, brightnessPercent: 56)
        ],
        externalDisplays: []
    )

    try manager.restorePrivacyMode(from: snapshot)

    try expect(
        internalController.setCommands == [
            InternalSetCommand(displayID: 1, percent: 56)
        ],
        "internal restore command"
    )
    try expect(
        runner.commands.isEmpty,
        "privacy restore commands"
    )
}

func testDisplayManagerEnforcesPrivacyModeFromSnapshotWithoutReloadingDisplays() throws {
    let json = """
    {
      "SPDisplaysDataType": [
        {
          "spdisplays_ndrvs": [
            {
              "_name": "Color LCD",
              "_spdisplays_displayID": "1",
              "spdisplays_connection_type": "spdisplays_internal",
              "spdisplays_online": "spdisplays_yes"
            }
          ]
        }
      ]
    }
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: json, stderr: "")
    ])
    let internalController = RecordingInternalBrightnessController(readValues: [:])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: { internalController },
        externalPowerControllerProvider: { externalPowerController }
    )
    let snapshot = DisplayPrivacyModeSnapshot(
        internalDisplays: [
            InternalPrivacyDisplayState(displayID: 1, brightnessPercent: 56)
        ],
        externalDisplays: []
    )

    try manager.enforcePrivacyMode(using: snapshot)

    try expect(
        internalController.setCommands == [
            InternalSetCommand(displayID: 1, percent: 0)
        ],
        "internal enforce command"
    )
    try expect(
        runner.commands.isEmpty,
        "privacy enforce commands"
    )
    try expect(
        externalPowerController.setCommands.isEmpty,
        "no external power command without external displays"
    )
}

func testPrivacyEnforcementLoopDoesNotRepowerAnOffDisplay() throws {
    let runner = RecordingCommandRunner(results: [])
    let internalController = RecordingInternalBrightnessController(readValues: [:])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: { internalController },
        externalPowerControllerProvider: { externalPowerController }
    )
    let snapshot = DisplayPrivacyModeSnapshot(
        internalDisplays: [
            InternalPrivacyDisplayState(displayID: 1, brightnessPercent: 56)
        ],
        externalDisplays: [
            ExternalPrivacyDisplayState(displayIndex: 1, brightnessPercent: nil, restoreInput: 15)
        ]
    )

    try manager.enforcePrivacyMode(using: snapshot, powerOffExternalDisplays: false)

    try expect(
        internalController.setCommands == [InternalSetCommand(displayID: 1, percent: 0)],
        "privacy loop keeps the internal display dimmed"
    )
    try expect(
        externalPowerController.setCommands.isEmpty,
        "privacy loop does not resend DDC to an off external display"
    )
}

func testPrivacyModeUsesExpectedExternalDisplayWhenLidClosed() throws {
    let closedLidJSON = """
    {
      "SPDisplaysDataType": [
        {
          "_name": "Apple M3 Pro",
          "spdisplays_ndrvs": []
        }
      ]
    }
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: closedLidJSON, stderr: ""),
        CommandResult(exitCode: 1, stdout: "", stderr: "no internal display")
    ])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: {
            throw BrightnessError.invalidOutput("unused")
        },
        externalPowerControllerProvider: { externalPowerController }
    )

    let snapshot = try manager.enablePrivacyMode(expectedExternalDisplayIndices: [1])

    try expect(
        snapshot.externalDisplays == [
            ExternalPrivacyDisplayState(displayIndex: 1, brightnessPercent: nil, restoreInput: 15)
        ],
        "closed-lid privacy snapshot preserves expected external display"
    )
    try expect(
        externalPowerController.setCommands == [
            ExternalPowerCommand(displayIndex: 1, mode: .off)
        ],
        "closed-lid privacy power command"
    )
}

func testPrivacyModeRejectsClosedLidWithoutKnownExternalDisplay() throws {
    let closedLidJSON = """
    {
      "SPDisplaysDataType": [
        {
          "_name": "Apple M3 Pro",
          "spdisplays_ndrvs": []
        }
      ]
    }
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: closedLidJSON, stderr: ""),
        CommandResult(exitCode: 1, stdout: "", stderr: "no internal display")
    ])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: {
            throw BrightnessError.invalidOutput("unused")
        },
        externalPowerControllerProvider: { externalPowerController }
    )

    do {
        _ = try manager.enablePrivacyMode(expectedExternalDisplayIndices: [])
        throw TestFailure(description: "closed-lid privacy should reject a missing target")
    } catch BrightnessError.noKnownExternalDisplay {
        try expect(externalPowerController.setCommands.isEmpty, "missing target sends no DDC command")
    }
}

func testDisplayManagerExternalPrivacyModePowersOffExternalDisplays() throws {
    let beforeJSON = """
    {
      "SPDisplaysDataType": [
        {
          "spdisplays_ndrvs": [
            {
              "_name": "ACER  N270IC",
              "_spdisplays_displayID": "3",
              "spdisplays_online": "spdisplays_yes"
            },
            {
              "_name": "Color LCD",
              "_spdisplays_displayID": "1",
              "spdisplays_connection_type": "spdisplays_internal",
              "spdisplays_online": "spdisplays_yes"
            }
          ]
        }
      ]
    }
    """
    let runner = RecordingCommandRunner(results: [
        CommandResult(exitCode: 0, stdout: beforeJSON, stderr: "")
    ])
    let externalPowerController = RecordingExternalPowerController()
    let manager = DisplayManager(
        runner: runner,
        internalControllerProvider: {
            throw BrightnessError.invalidOutput("unused")
        },
        externalPowerControllerProvider: { externalPowerController }
    )

    try manager.setExternalPrivacyMode(enabled: true)

    try expect(
        externalPowerController.setCommands == [
            ExternalPowerCommand(displayIndex: 1, mode: .off)
        ],
        "external privacy power command"
    )
    try expect(
        runner.commands == [
            ["system_profiler", "SPDisplaysDataType", "-json"]
        ],
        "external privacy display discovery commands"
    )
}

func testMenuPanelSizingUsesModernHeightForTwoDisplays() throws {
    try expect(MenuPanelSizing.width == 380, "modern menu width")
    try expect(
        MenuPanelSizing.height(displayCount: 1, isLoading: false, hasError: false) == 362,
        "single-display menu removes unused vertical space"
    )
    try expect(
        MenuPanelSizing.height(displayCount: 2, isLoading: false, hasError: false) == 440,
        "modern two-display menu height"
    )
}

func testMenuPanelSizingBoundsModernLoadingAndManyDisplayStates() throws {
    try expect(
        MenuPanelSizing.height(displayCount: 0, isLoading: true, hasError: false) == 322,
        "modern loading menu height"
    )
    try expect(
        MenuPanelSizing.height(displayCount: 5, isLoading: false, hasError: true) == 600,
        "modern many-display menu height cap"
    )
}

func testModernMenuSizing() throws {
    try expect(MenuPanelSizing.width == 380.0, "modern menu width")
    try expect(
        MenuPanelSizing.height(displayCount: 2, isLoading: false, hasError: false) == 440.0,
        "modern menu height for two displays"
    )
    try expect(
        MenuPanelSizing.height(displayCount: 4, isLoading: false, hasError: true) == 600.0,
        "modern menu height remains bounded"
    )
}

func testParsesSleepDisabledIORegistryState() throws {
    try expect(
        SleepDisabledStateParser.parse("|   \"SleepDisabled\" = Yes") == true,
        "enabled SleepDisabled state"
    )
    try expect(
        SleepDisabledStateParser.parse("|   \"SleepDisabled\" = No") == false,
        "disabled SleepDisabled state"
    )
    try expect(
        SleepDisabledStateParser.parse("|   \"OtherProperty\" = Yes") == nil,
        "missing SleepDisabled state"
    )
}

func testMenuPanelSizingIncludesErrorsOnlyWhenPresent() throws {
    try expect(
        MenuPanelSizing.height(displayCount: 2, isLoading: false, hasError: true)
            - MenuPanelSizing.height(displayCount: 2, isLoading: false, hasError: false) == 42,
        "error row should expand the menu only when present"
    )
    try expect(
        MenuPanelSizing.height(displayCount: 0, isLoading: true, hasError: true)
            - MenuPanelSizing.height(displayCount: 0, isLoading: true, hasError: false) == 42,
        "loading error should expand the menu only when present"
    )
}

final class RecordingCommandRunner: CommandRunning {
    var commands: [[String]] = []
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ command: [String]) throws -> CommandResult {
        commands.append(command)
        if results.isEmpty {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}

final class RecordingInternalBrightnessController: InternalBrightnessControlling {
    var setCommands: [InternalSetCommand] = []
    private var readValues: [UInt32: Int]

    init(readValues: [UInt32: Int]) {
        self.readValues = readValues
    }

    func readBrightness(displayID: UInt32) throws -> Int? {
        readValues[displayID]
    }

    func setBrightness(displayID: UInt32, percent: Int) throws {
        setCommands.append(InternalSetCommand(displayID: displayID, percent: percent))
    }
}

struct InternalSetCommand: Equatable {
    let displayID: UInt32
    let percent: Int
}

final class RecordingExternalPowerController: ExternalPowerControlling {
    let name: String
    var setCommands: [ExternalPowerCommand] = []
    private let failure: Error?

    init(name: String = "test-power", failure: Error? = nil) {
        self.name = name
        self.failure = failure
    }

    func setPowerMode(displayIndex: Int, mode: ExternalPowerMode) throws {
        setCommands.append(ExternalPowerCommand(displayIndex: displayIndex, mode: mode))
        if let failure {
            throw failure
        }
    }
}

struct ExternalPowerCommand: Equatable {
    let displayIndex: Int
    let mode: ExternalPowerMode
}

let tests: [(String, () throws -> Void)] = [
    ("parse system_profiler displays", testParsesInternalAndExternalDisplaysFromSystemProfilerJSON),
    ("parse system_profiler without displays", testParsesGPUWithoutConnectedDisplays),
    ("parse corebrightnessdiag brightness", testParsesDisplayServicesBrightnessByDisplayID),
    ("m1ddc backend commands", testM1DDCBackendBuildsGetAndSetCommands),
    ("m1ddc input command", testM1DDCBackendBuildsInputCommand),
    ("m1ddc input read command", testM1DDCBackendReadsInputCommand),
    ("m1ddc power command", testM1DDCPowerControllerBuildsStandbyCommand),
    ("external power factory m1ddc", testExternalPowerControllerFactoryPrefersM1DDC),
    ("external power fallback", testExternalPowerControllerFallsBackAfterM1DDCFailure),
    ("ddcctl backend commands", testDDCCTLBackendParsesCurrentValueAndBuildsSetCommand),
    ("display manager privacy enable", testDisplayManagerEnablesPrivacyModeCapturesAndForcesDisplays),
    ("display manager external power off", testDisplayManagerPowersOffExternalDisplaysDirectly),
    ("display manager privacy restore", testDisplayManagerRestoresPrivacyModeSnapshot),
    ("display manager privacy enforce", testDisplayManagerEnforcesPrivacyModeFromSnapshotWithoutReloadingDisplays),
    ("display manager privacy loop", testPrivacyEnforcementLoopDoesNotRepowerAnOffDisplay),
    ("display manager closed-lid privacy", testPrivacyModeUsesExpectedExternalDisplayWhenLidClosed),
    ("display manager missing closed-lid target", testPrivacyModeRejectsClosedLidWithoutKnownExternalDisplay),
    ("display manager external privacy power off", testDisplayManagerExternalPrivacyModePowersOffExternalDisplays),
    ("modern menu sizing for two displays", testMenuPanelSizingUsesModernHeightForTwoDisplays),
    ("bounded modern menu sizing states", testMenuPanelSizingBoundsModernLoadingAndManyDisplayStates),
    ("modern menu sizing", testModernMenuSizing),
    ("menu sizing follows error content", testMenuPanelSizingIncludesErrorsOnlyWhenPresent),
    ("parse SleepDisabled state", testParsesSleepDisabledIORegistryState)
]

var failures: [String] = []
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures.append("\(name): \(error)")
        print("FAIL \(name): \(error)")
    }
}

if failures.isEmpty {
    print("All \(tests.count) core tests passed")
} else {
    exit(1)
}
