// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetCallRecorder",
    // macOS 26 is the floor for AVAssetWriter's input receiver API, which
    // replaced the deprecated AVAssetWriterInput.append path this app's
    // whole write loop is built on. This only ever runs on one Mac, so
    // carrying a parallel pre-26 code path would be dead weight.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MeetCallRecorder",
            path: "Sources/MeetCallRecorder"
        )
    ]
)
