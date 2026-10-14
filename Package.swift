// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TacticalHypervisor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "TacticalHypervisor",
            targets: [
                "TacticalCore",
                "TacticalAudioSVS",
                "TacticalVirtualization",
                "TacticalUI"
            ]
        ),
        .library(
            name: "TacticalCore",
            targets: ["TacticalCore"]
        ),
        .library(
            name: "TacticalAudioSVS",
            targets: ["TacticalAudioSVS"]
        ),
        .library(
            name: "TacticalVirtualization",
            targets: ["TacticalVirtualization"]
        ),
        .library(
            name: "TacticalUI",
            targets: ["TacticalUI"]
        ),
    ],
    targets: [
        .target(
            name: "TacticalCore",
            dependencies: []
        ),
        .target(
            name: "TacticalAudioSVS",
            dependencies: ["TacticalCore"]
        ),
        .target(
            name: "TacticalVirtualization",
            dependencies: ["TacticalCore"]
        ),
        .target(
            name: "TacticalUI",
            dependencies: ["TacticalCore"]
        ),
        .testTarget(
            name: "TacticalCoreTests",
            dependencies: ["TacticalCore", "TacticalAudioSVS"]
        ),
        .testTarget(
            name: "TacticalVirtualizationTests",
            dependencies: ["TacticalVirtualization", "TacticalCore"]
        ),
        .testTarget(
            name: "TacticalAudioSVSTests",
            dependencies: ["TacticalAudioSVS", "TacticalCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
