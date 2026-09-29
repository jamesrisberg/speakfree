// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speakfree",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.1"),
    ],
    targets: [
        // whisper.cpp 1.8.3 + ggml 0.9.5 as one static library for macOS arm64, built by
        // scripts/vendor/build-whisper-xcframework.sh. Linked statically, so nothing from
        // Homebrew is on the link line and no whisper dylib has to be shipped beside a host.
        .binaryTarget(
            name: "whisper",
            path: "scripts/vendor/whisper.xcframework"
        ),
        // C module wrapping the whisper.cpp headers that match the static library above.
        .target(
            name: "CWhisper",
            dependencies: ["whisper"],
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        // Tiny Objective-C bridge so Swift can catch NSException from AVAudioEngine
        // (e.g. installTap on a transient Bluetooth-handoff format). See CTryCatch.h.
        .target(
            name: "CTryCatch",
            path: "Sources/CTryCatch",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SpeakFreeLib",
            dependencies: [
                "Sparkle",
                "CWhisper",
                "CTryCatch",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SpeakFreeLib",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "speakfree",
            dependencies: ["SpeakFreeLib"],
            path: "Sources/SpeakFree"
        ),
        // Performance-regression harness (T2.0): benchmarks per-fixture inference time +
        // simulated end-to-end latency over the audio golden fixtures, writes a fingerprinted
        // baseline JSON, and gates regressions (>+15% median) against a matching baseline.
        // `swift run perf-harness run` / `swift run perf-harness compare <candidate> <baseline>`.
        .executableTarget(
            name: "perf-harness",
            dependencies: ["SpeakFreeLib"],
            path: "Sources/PerfHarness"
        ),
        // Offline A/B harness for Parakeet vocabulary boosting (vocab-boost-eval loop).
        // Compares batch TDT, sliding-window, sliding+vocab, and batch+CTC-rescore+guard
        // on corpus wavs. Not shipped; local eval only.
        .executableTarget(
            name: "vocab-eval",
            dependencies: [
                "SpeakFreeLib",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VocabEval"
        ),
        .testTarget(
            name: "SpeakFreeTests",
            dependencies: ["SpeakFreeLib"],
            path: "Tests/SpeakFreeTests",
            resources: [
                .copy("Corpus/cases.json"),
                .copy("AudioFixtures"),
            ]
        ),
    ]
)
