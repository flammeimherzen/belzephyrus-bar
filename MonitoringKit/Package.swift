// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonitoringKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonitoringKit", targets: ["MonitoringKit"])
    ],
    targets: [
        .target(
            name: "MonitoringKitC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "MonitoringKit",
            dependencies: ["MonitoringKitC"]
        )
    ]
)
