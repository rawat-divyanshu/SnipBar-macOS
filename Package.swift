// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SnipBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SnipBar", targets: ["SnipBar"])
    ],
    targets: [
        .executableTarget(
            name: "SnipBar",
            path: "Sources/SnipBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("SwiftData"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .testTarget(
            name: "SnipBarTests",
            dependencies: ["SnipBar"],
            path: "Tests/SnipBarTests"
        )
    ]
)
