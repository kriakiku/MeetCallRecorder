import Foundation

/// One thing that happened during a call, placed on its segment's own
/// timeline.
///
/// This is what lets the overlays be composited when the finished file is
/// assembled rather than burned into the capture as it happens. Live
/// compositing can only ever react: a resize isn't known to have ended
/// until after it has, so the picture carries the detection lag and the
/// "has it held still long enough?" wait inside it. An assembler reading
/// these knows both ends of every event before it draws anything.
struct TimelineEvent: Codable {
    enum Kind: String, Codable {
        /// First segment of the call - gets the welcome plate.
        case intro
        /// Segment that resumes the call after the window was away.
        case pause
        /// A stretch of this segment where the window was being resized.
        case resize
        /// The closing plate. Never logged - there is nothing during a
        /// call that decides it. The assembler is handed one of these
        /// because every finished recording ends with one.
        case outro
    }

    let kind: Kind
    /// Segment file this is positioned against, by name.
    let segment: String
    /// Seconds from the first frame of `segment`.
    let at: Double
    /// `resize` only: where it ended, same base as `at`.
    var until: Double?
    /// `pause` only: how long the call was away before this segment.
    var gap: Double?
}

/// The per-call event log, written next to its segments.
///
/// JSONL, appended a line at a time, rather than one JSON document
/// rewritten on every change: a call that dies mid-recording - which,
/// with the writer failures this app is still chasing, is the normal
/// case rather than the exception - has to keep the events already
/// recorded, and rewriting a whole document is exactly how those get
/// lost.
enum RecordingTimeline {
    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent("events.jsonl")
    }

    static func append(_ event: TimelineEvent, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)

        let url = Self.url(in: folder)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Every event recorded for a call, in the order they happened.
    /// Unparseable lines are skipped rather than failing the lot - a
    /// half-written final line is what a crash mid-append leaves.
    static func read(in folder: URL) -> [TimelineEvent] {
        guard let contents = try? String(contentsOf: Self.url(in: folder), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return contents
            .split(separator: "\n")
            .compactMap { try? decoder.decode(TimelineEvent.self, from: Data($0.utf8)) }
    }
}
