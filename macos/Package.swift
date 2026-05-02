// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinuxBatteryMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LinuxBatteryMenuBar", targets: ["LinuxBatteryMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "LinuxBatteryMenuBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
