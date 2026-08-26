// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BoyaManager",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "BoyaManager"
        ),
        .testTarget(
            name: "BoyaManagerTests",
            dependencies: [ "BoyaManager" ]
        ),
    ]
)
