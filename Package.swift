// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnatchMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SnatchMac",
            path: "Sources/SnatchMac",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
