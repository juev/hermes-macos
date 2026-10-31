// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// The node of `tailnet/`, bound with gomobile by `scripts/build-tailnet.sh`. Two copies of it would
/// be two things to keep in step, so it is built, never committed — and the package builds without
/// it, the way the Android client builds without `tailnet.aar`: the tailnet route then says the node
/// is not in this build instead of failing at launch.
let artifacts = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Artifacts/HermesTailnet.xcframework")
let hasTailnet = FileManager.default.fileExists(atPath: artifacts.path)

/// The part of the client that has nothing to do with a window: the dashboard contract, the
/// transport and the model of a conversation. It builds with `swift test`, without Xcode, so the
/// protocol can be checked against the fixtures in the Android repository on every change.
var targets: [Target] = []

if hasTailnet {
    targets.append(.binaryTarget(name: "HermesTailnet", path: "Artifacts/HermesTailnet.xcframework"))
}

targets += [
    .target(name: "HermesCore", dependencies: hasTailnet ? ["HermesTailnet"] : []),
    // The look of the chat: typography, colours, the rows of a transcript. SwiftUI only, so a
    // snapshot can be rendered without a window and looked at.
    .target(name: "HermesUI", dependencies: ["HermesCore"]),
    .testTarget(name: "HermesCoreTests", dependencies: ["HermesCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "HermesUITests", dependencies: ["HermesUI"]),
    // A check against a live dashboard: the client's own code, one call after another, printing
    // what worked and what did not. `scripts/smoke.sh` runs it with the tokens of the Keychain.
    .executableTarget(name: "hermes-live", dependencies: ["HermesCore"])
]

let package = Package(
    name: "HermesCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HermesCore", targets: ["HermesCore"]),
        .library(name: "HermesUI", targets: ["HermesUI"])
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
