import Foundation

/// The app's log file, shared by everything that has something to say.
///
/// Nothing here runs attached to a terminal - the app is launched by the
/// Finder or by launchd as a login item, so `stderr` goes nowhere a user
/// (or a debugging session) will ever look. Anything worth knowing has to
/// reach ~/Library/Logs/MeetCallRecorder.log.
enum Log {
    static let url = URL(fileURLWithPath: NSString(string: "~/Library/Logs/MeetCallRecorder.log").expandingTildeInPath)

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
