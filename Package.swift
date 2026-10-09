// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS("14.0")],
    products: [.executable(name: "Portside", targets: ["Portside"])],
    targets: [
        .executableTarget(
            name: "Portside",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortsideTests",
            dependencies: ["Portside"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
