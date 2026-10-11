// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetCallRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MeetCallRecorder",
            path: "Sources/MeetCallRecorder"
        )
    ]
)
