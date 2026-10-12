import Foundation
import ImageIO
import CoreGraphics

/// On-disk bookkeeping for recordings that haven't been finalized yet.
///
/// Every call in progress owns a folder under `staging/` named
/// `<App>-<CallID>`, holding its `segment-NNN.mp4` files plus a `call.meta`
/// describing it. A call gets more than one segment whenever its writer had
/// to be replaced mid-call - the hardware H.264 encoder dying, an app
/// restart, or the call being suspended because we briefly switched to a
/// different one - and all of them are concatenated back into a single file
/// when the call is finally finalized.
///
/// The folder existing *is* the "this call isn't finished" signal: it's
/// created on the first segment and only removed once the merged result has
/// been moved out, so an app that goes away mid-call (crash, `pkill`,
/// `manage.sh update`, a Quit during a call) leaves everything the next
/// launch needs to pick the call back up.
enum CrashRecovery {
    /// A call folder left behind on disk, as read back at launch.
    struct StaleCall {
        let folder: URL
        let ownerName: String
        let callID: String
        let startDate: Date
        /// Content duration of the segments in this folder, as recorded by
        /// the process that wrote them - the outro's "recording duration"
        /// has to cover the whole call, not just its last segment.
        let closedDuration: TimeInterval
        /// The identifier stamped on this call's frames - read back so
        /// the segments written after a restart carry the same one.
        let recordingID: String
        /// What these segments were actually captured at. Read back
        /// rather than taken from the current setting: changing quality
        /// between the crash and the restart must not change the canvas
        /// a half-recorded call is assembled onto.
        let quality: RecordingQuality
    }

    // MARK: - Call folders

    /// What a call folder knows about itself.
    ///
    /// JSON rather than the obvious macOS answer of a plist: the one time
    /// anybody opens this file is to work out what a folder stuck in
    /// staging belongs to, and `cat` beats `plutil -p`. Being Codable is
    /// the part that matters - swapping the encoder is one line if that
    /// ever stops being true.
    ///
    /// Every field but the three that identify the call decodes as
    /// optional, because a folder whose meta can't be read gets deleted,
    /// segments and all. Adding a field later must not be able to do
    /// that.
    private struct CallMeta: Codable {
        let ownerName: String
        let callID: String
        let startDate: Date
        let closedDuration: TimeInterval
        let recordingID: String
        let quality: RecordingQuality

        init(ownerName: String, callID: String, startDate: Date, closedDuration: TimeInterval, recordingID: String, quality: RecordingQuality) {
            self.ownerName = ownerName
            self.callID = callID
            self.startDate = startDate
            self.closedDuration = closedDuration
            self.recordingID = recordingID
            self.quality = quality
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ownerName = try container.decode(String.self, forKey: .ownerName)
            callID = try container.decode(String.self, forKey: .callID)
            startDate = try container.decode(Date.self, forKey: .startDate)
            closedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .closedDuration) ?? 0
            recordingID = try container.decodeIfPresent(String.self, forKey: .recordingID) ?? RecordingID.generate()
            // Absent in metas written before quality was selectable, and
            // everything written then was 1080p.
            quality = try container.decodeIfPresent(RecordingQuality.self, forKey: .quality) ?? .p1080
        }
    }

    /// Creates the staging directory and marks it for what it is: a
    /// working area, not somewhere the user keeps anything.
    ///
    /// Nothing in here is a recording. It is half-written fragments of
    /// one, rewritten every second and deleted the moment the call is
    /// assembled - so Time Machine backing it up means a snapshot per call
    /// of files that no longer exist by the next one, and Spotlight
    /// indexing it means churning through video that will never be
    /// searched for.
    ///
    /// Hiding and backup exclusion are both real URL resource keys.
    /// Spotlight has no equivalent key: `.metadata_never_index` is the
    /// only lever that needs neither root (`mdutil`) nor the user adding
    /// the path to Settings' privacy list by hand, and it is documented
    /// for volume roots rather than subfolders. Treat it as a request
    /// rather than a guarantee - it costs an empty file to ask.
    static func prepareStagingDirectory(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)

        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        values.isHidden = true
        try? url.setResourceValues(values)

        let marker = url.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: nil)
        }
    }

    private static func metaURL(in folder: URL) -> URL {
        folder.appendingPathComponent("call.json")
    }

    static func writeCallMeta(folder: URL, ownerName: String, callID: String, startDate: Date, closedDuration: TimeInterval, recordingID: String, quality: RecordingQuality) {
        let meta = CallMeta(
            ownerName: ownerName,
            callID: callID,
            startDate: startDate,
            closedDuration: closedDuration,
            recordingID: recordingID,
            quality: quality
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: metaURL(in: folder), options: .atomic)
    }

    private static func readCallMeta(in folder: URL) -> CallMeta? {
        guard let data = try? Data(contentsOf: metaURL(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CallMeta.self, from: data)
    }

    /// The picture a call ended on, read back out of its last segment -
    /// what a closing plate gets drawn over for a call finalized long
    /// after its writer and composer are gone.
    ///
    /// Read from the video rather than saved alongside it: the frame is
    /// already on disk in the segment, so keeping a second copy as a PNG
    /// only bought a way for the two to disagree, plus a full-canvas
    /// render and a file write every time a segment closed.
    static func extractLastFrame(from segment: URL) async -> CGImage? {
        guard let ffmpeg = locateFFmpeg() else { return nil }
        let pngURL = segment.deletingPathExtension().appendingPathExtension("lastframe.png")
        defer { try? FileManager.default.removeItem(at: pngURL) }

        // -sseof needs a container duration to seek against, which a
        // segment abandoned by a failed writer doesn't have; decoding the
        // whole thing and letting -update overwrite the same file leaves
        // the last decoded frame either way, just slower.
        let tailSeek = ["-y", "-sseof", "-2", "-i", segment.path, "-update", "1", "-frames:v", "1", pngURL.path]
        let fullDecode = ["-y", "-i", segment.path, "-an", "-update", "1", pngURL.path]
        for arguments in [tailSeek, fullDecode] {
            if await runFFmpeg(ffmpeg, arguments),
               let source = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return image
            }
        }
        return nil
    }

    /// Segment files in a call folder, in the order they were written.
    static func segments(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            // .mov is what staging writes now (see CallRecorder.start);
            // .mp4 segments are older calls recovered after an update.
            .filter { ["mov", "mp4"].contains($0.pathExtension) && $0.lastPathComponent.hasPrefix("segment-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func nextSegmentURL(in folder: URL) -> URL {
        folder.appendingPathComponent(String(format: "segment-%03d.mov", segments(in: folder).count + 1))
    }

    /// Every call folder still sitting in staging - i.e. every call that
    /// never got finalized, whether because the app went away mid-call or
    /// because it was still inside its grace window at the time.
    static func findStaleCalls(in stagingDir: URL) -> [StaleCall] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var result: [StaleCall] = []
        for folder in entries {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let meta = readCallMeta(in: folder), !meta.ownerName.isEmpty else {
                // No metadata to identify the call by - nothing can be
                // resumed or named from it, so drop it rather than leave
                // it accumulating forever.
                try? fm.removeItem(at: folder)
                continue
            }
            result.append(StaleCall(
                folder: folder,
                ownerName: meta.ownerName,
                callID: meta.callID,
                startDate: meta.startDate,
                closedDuration: meta.closedDuration,
                recordingID: meta.recordingID,
                quality: meta.quality
            ))
        }
        return result
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Best available estimate of when a call folder last got new data -
    /// used to size the pause card when resuming it.
    static func lastWrite(in folder: URL) -> Date {
        segments(in: folder).map(modDate).max() ?? modDate(folder)
    }

    // MARK: - Finalizing

    /// Remuxes every segment into a file that can actually be opened,
    /// and reports how much video they hold between them.
    ///
    /// Any segment whose writer died mid-call never got finishWriting(),
    /// so it declares no duration and its tail carries decode timestamps
    /// unrelated to its presentation ones. ffmpeg reads the fragments
    /// anyway, rebases the timestamps to zero and writes a complete moov;
    /// AVFoundation, which assembles the result, is far stricter and
    /// would simply refuse most of them. It is still a stream copy - no
    /// re-encoding happens here.
    ///
    /// The returned `scratch` files are the caller's to delete once the
    /// inputs have been consumed.
    static func normalizeSegments(_ segments: [URL], scratchDir: URL) async -> (inputs: [URL], durations: [Double], scratch: [URL], total: TimeInterval) {
        guard let ffmpeg = locateFFmpeg() else { return (segments, [], [], 0) }
        let runID = UUID().uuidString
        var inputs: [URL] = []
        var durations: [Double] = []
        var scratch: [URL] = []
        var total: TimeInterval = 0

        for (index, segment) in segments.enumerated() {
            let normalized = scratchDir.appendingPathComponent(".normalize-\(runID)-\(index).mp4")
            let ok = await runFFmpeg(ffmpeg, [
                "-y", "-i", segment.path,
                "-c", "copy", "-avoid_negative_ts", "make_zero",
                "-muxdelay", "0", "-muxpreload", "0",
                "-f", "mp4", normalized.path
            ])
            if ok, FileManager.default.fileExists(atPath: normalized.path) {
                scratch.append(normalized)
                inputs.append(normalized)
            } else {
                log("assemble: could not normalize \(segment.lastPathComponent), using it as-is")
                inputs.append(segment)
            }
            let duration = await probeDuration(inputs[index]) ?? 0
            durations.append(duration)
            total += duration
            log("assemble: \(segment.lastPathComponent) -> \(String(format: "%.2f", duration))s")
        }
        return (inputs, durations, scratch, total)
    }

    static func probeDuration(_ url: URL) async -> Double? {
        guard let ffprobe = locateFFprobe() else { return nil }
        return await Task.detached(priority: .utility) { () -> Double? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// Runs ffmpeg with `arguments`, locating the binary itself - the
    /// assembler's audio pass uses this too.
    static func runFFmpegArgs(_ arguments: [String]) async -> Bool {
        guard let ffmpeg = locateFFmpeg() else { return false }
        return await runFFmpeg(ffmpeg, arguments)
    }

    private static func runFFmpeg(_ ffmpeg: String, _ arguments: [String]) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            // Inherit stderr rather than discarding it - a failed merge
            // used to leave nothing but "merge failed" in the log, with
            // ffmpeg's actual complaint thrown away.
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private static func locateFFmpeg() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Diagnostics go to stderr - the launchd log - next to the
    /// recorder's own, rather than to the app log, which is the
    /// user-facing "what happened to my calls" timeline.
    private static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write("[\(ts)] \(message)\n".data(using: .utf8)!)
    }

    private static func locateFFprobe() -> String? {
        ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

}
