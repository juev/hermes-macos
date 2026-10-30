// swift-tools-version: 6.0
import PackageDescription

/// The part of the client that has nothing to do with a window: the dashboard contract, the
/// transport and the model of a conversation. It builds with `swift test`, without Xcode, so the
/// protocol can be checked against the fixtures in the Android repository on every change.
let package = Package(
    name: "HermesCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HermesCore", targets: ["HermesCore"])
    ],
    targets: [
        .target(name: "HermesCore"),
        .testTarget(name: "HermesCoreTests", dependencies: ["HermesCore"])
    ],
    swiftLanguageModes: [.v6]
)
