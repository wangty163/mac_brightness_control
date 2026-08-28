// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BrightnessControlApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BrightnessControlCore", targets: ["BrightnessControlCore"]),
        .executable(name: "BrightnessControlApp", targets: ["BrightnessControlApp"]),
        .executable(name: "BrightnessControlSleepHelper", targets: ["BrightnessControlSleepHelper"]),
        .executable(name: "BrightnessControlCoreTestRunner", targets: ["BrightnessControlCoreTestRunner"])
    ],
    targets: [
        .target(
            name: "DDCPower",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "BrightnessControlCore",
            dependencies: ["DDCPower"]
        ),
        .executableTarget(
            name: "BrightnessControlApp",
            dependencies: ["BrightnessControlCore"],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "BrightnessControlSleepHelper",
            dependencies: ["BrightnessControlCore"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "BrightnessControlCoreTestRunner",
            dependencies: ["BrightnessControlCore"],
            path: "Tests/BrightnessControlCoreTestRunner"
        )
    ]
)
