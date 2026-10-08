// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Undertone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Undertone", targets: ["Undertone"]),
        .executable(name: "UndertoneDemo", targets: ["UndertoneDemo"]),
    ],
    targets: [
        .target(name: "UndertoneCore"),
        .executableTarget(name: "Undertone", dependencies: ["UndertoneCore"]),
        .executableTarget(name: "UndertoneDemo"),
        .testTarget(name: "UndertoneCoreTests", dependencies: ["UndertoneCore"]),
    ]
)
