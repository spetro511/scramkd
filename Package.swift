// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scramkd",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ScramK",
            targets: [
                "ScramKCore",
                "ScramKAudio",
                "ScramKVirtualization",
                "ScramKUI",
            ]
        ),
        .library(
            name: "ScramKCore",
            targets: ["ScramKCore"]
        ),
        .library(
            name: "ScramKAudio",
            targets: ["ScramKAudio"]
        ),
        .library(
            name: "ScramKVirtualization",
            targets: ["ScramKVirtualization"]
        ),
        .library(
            name: "ScramKUI",
            targets: ["ScramKUI"]
        ),
        .executable(
            name: "scramkd",
            targets: ["scramkd"]
        ),
        .executable(
            name: "scramkctl",
            targets: ["scramkctl"]
        ),
    ],
    targets: [
        .target(
            name: "ScramKCore",
            dependencies: []
        ),
        .target(
            name: "ScramKAudio",
            dependencies: ["ScramKCore", "CScramKAudioRealtime"]
        ),
        .target(
            name: "CScramKAudioRealtime",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fno-objc-arc"])],
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AVFoundation")]
        ),
        .target(
            name: "ScramKVirtualization",
            dependencies: ["ScramKCore"]
        ),
        .target(
            name: "ScramKUI",
            dependencies: ["ScramKCore", "ScramKVirtualization"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "scramkd",
            dependencies: [
                "ScramKCore",
                "ScramKVirtualization",
                "ScramKAudio",
                "ScramKUI",
            ]
        ),
        .executableTarget(
            name: "scramkctl",
            dependencies: ["ScramKCore"]
        ),
        .testTarget(
            name: "ScramKCoreTests",
            dependencies: ["ScramKCore", "ScramKAudio"]
        ),
        .testTarget(
            name: "ScramKVirtualizationTests",
            dependencies: ["ScramKVirtualization", "ScramKCore"]
        ),
        .testTarget(
            name: "ScramKAudioTests",
            dependencies: ["ScramKAudio", "ScramKCore", "CScramKAudioRealtime"]
        ),
        .testTarget(
            name: "ScramKUITests",
            dependencies: ["ScramKUI", "ScramKCore", "ScramKVirtualization"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
