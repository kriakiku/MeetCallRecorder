import CoreGraphics
import Foundation

/// Which app a call can come from. Replaces the pair of hardcoded
/// detector calls, so the settings window can turn one off without
/// touching the poll loop.
enum CallSource: String, CaseIterable, Identifiable, Sendable {
    case googleMeet
    case slack

    var id: String { rawValue }

    /// What `kCGWindowOwnerName` reports for the app.
    var ownerName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .slack: return "Slack"
        }
    }

    /// The window title prefix that distinguishes a call window from the
    /// app's other windows.
    var titlePrefix: String {
        switch self {
        case .googleMeet: return "Meet: "
        case .slack: return "Huddle"
        }
    }

    var displayName: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .slack: return "Slack huddles"
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    /// Watch for call windows and record them unattended - what the app
    /// has always done.
    case automatic
    /// Start and stop by hand, recording the whole main display plus the
    /// default microphone. Not built yet; see Settings.
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case p720
    case p1080
    case p1440
    case audioOnly

    var id: String { rawValue }

    /// The canvas a call is composited onto, or nil when there is no
    /// picture at all. Everything downstream - the writer, the composer,
    /// the plates, the assembler - sizes itself off this.
    var outputSize: CGSize? {
        switch self {
        case .p720: return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p1440: return CGSize(width: 2560, height: 1440)
        case .audioOnly: return nil
        }
    }

    var isAudioOnly: Bool { outputSize == nil }

    /// Scaled off the 1080p pair that was tuned by hand (12 Mbps staged,
    /// 5 Mbps final), by pixel count rather than by height - bitrate
    /// tracks area, and a height-based scale would leave 1440p starved.
    /// Staging deliberately runs well above the target: every segment is
    /// re-encoded exactly once at assembly, and a source already sitting
    /// at the final rate loses visibly more in that pass.
    private var bitrateScale: Double {
        guard let size = outputSize else { return 0 }
        let reference = 1920.0 * 1080.0
        return (size.width * size.height) / reference
    }

    var stagingBitrate: Int { Int(12_000_000 * bitrateScale) }
    var outputBitrate: Int { Int(5_000_000 * bitrateScale) }

    /// Finished recordings are HEVC in MP4, except audio-only ones, which
    /// are plain AAC in M4A - there's no video track to carry and no
    /// plates to draw, so the whole video half of assembly is skipped.
    var fileExtension: String { isAudioOnly ? "m4a" : "mp4" }

    var displayName: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .audioOnly: return "Audio only"
        }
    }

    var summary: String {
        switch self {
        case .p720: return "1280×720 · smallest files"
        case .p1080: return "1920×1080 · the default"
        case .p1440: return "2560×1440 · sharpest, largest files"
        case .audioOnly: return "No picture · saved as .m4a"
        }
    }
}

/// Everything the settings window owns, persisted to UserDefaults.
///
/// Read at the *start of a call*, never mid-call: a recording keeps the
/// canvas size, background and source list it began with, so changing a
/// setting during a meeting can't resize the output halfway through or
/// swap the backdrop between two segments of the same call.
@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var background: BackgroundMode {
        didSet { store(background.rawValue, Keys.background) }
    }

    var quality: RecordingQuality {
        didSet { store(quality.rawValue, Keys.quality) }
    }

    var captureMode: CaptureMode {
        didSet { store(captureMode.rawValue, Keys.captureMode) }
    }

    /// The sources automatic capture watches. Empty means nothing is
    /// detected at all, which the settings window warns about rather than
    /// preventing - it's a legitimate way to mute the app for a while.
    var enabledSources: Set<CallSource> {
        didSet { store(enabledSources.map(\.rawValue), Keys.enabledSources) }
    }

    private enum Keys {
        static let background = "settings.background"
        static let quality = "settings.quality"
        static let captureMode = "settings.captureMode"
        static let enabledSources = "settings.enabledSources"
    }

    private init() {
        let defaults = UserDefaults.standard
        background = defaults.string(forKey: Keys.background)
            .flatMap(BackgroundMode.init(rawValue:)) ?? .desktop
        quality = defaults.string(forKey: Keys.quality)
            .flatMap(RecordingQuality.init(rawValue:)) ?? .p1080
        captureMode = defaults.string(forKey: Keys.captureMode)
            .flatMap(CaptureMode.init(rawValue:)) ?? .automatic
        // Absent, not empty, is the first-run case: both sources on.
        if let raw = defaults.array(forKey: Keys.enabledSources) as? [String] {
            enabledSources = Set(raw.compactMap(CallSource.init(rawValue:)))
        } else {
            enabledSources = Set(CallSource.allCases)
        }
    }

    func isEnabled(_ source: CallSource) -> Bool { enabledSources.contains(source) }

    func setEnabled(_ source: CallSource, _ enabled: Bool) {
        if enabled {
            enabledSources.insert(source)
        } else {
            enabledSources.remove(source)
        }
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
