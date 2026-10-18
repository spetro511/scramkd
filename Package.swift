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
        .executable(
            name: "TacticalApp",
            targets: ["TacticalApp"]
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
            dependencies: ["TacticalCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TacticalApp",
            dependencies: [
                "TacticalCore",
                "TacticalVirtualization",
                "TacticalAudioSVS",
                "TacticalUI"
            ]
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
        .testTarget(
            name: "TacticalUITests",
            dependencies: ["TacticalUI", "TacticalCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
