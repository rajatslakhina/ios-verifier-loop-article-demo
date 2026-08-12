// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VerifierLoopKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "VerifierLoop", targets: ["VerifierLoop"]),
        .library(name: "VerifierLoopUI", targets: ["VerifierLoopUI"])
    ],
    targets: [
        .target(name: "VerifierLoop"),
        .target(name: "VerifierLoopUI", dependencies: ["VerifierLoop"]),
        .testTarget(name: "VerifierLoopTests", dependencies: ["VerifierLoop"])
    ]
)
