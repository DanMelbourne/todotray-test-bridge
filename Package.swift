// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "todotray-test-bridge",
    platforms: [.macOS(.v13)],
    products: [
        // A target is reachable only from inside its own package, so this line
        // is what lets an app add the bridge as a dependency at all.
        .library(name: "TodoTrayTestBridge", targets: ["TodoTrayTestBridge"]),
    ],
    targets: [
        .target(
            name: "TodoTrayTestBridge",
            path: "Sources/TodoTrayTestBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "TodoTrayTestBridgeTests",
            dependencies: ["TodoTrayTestBridge"],
            path: "Tests/TodoTrayTestBridgeTests"
        ),
    ]
)
