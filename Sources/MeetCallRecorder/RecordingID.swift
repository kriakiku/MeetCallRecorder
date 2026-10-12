import Foundation

/// The identifier a recording carries: generated once when its call
/// folder is created, written into `call.meta`, and stamped onto every
/// frame of the finished video.
///
/// It survives an app restart mid-call by being read back out of the
/// meta file, so the segments of one call all carry the same one.
enum RecordingID {
    enum Style {
        /// `recUdra-JmfQ4j9F` - short enough to read off a frame and type
        /// back in, which is the whole point of stamping it on the video.
        case prefixed
        case uuid
    }

    /// Fixed for now; meant to become a setting, which is why the other
    /// style exists at all.
    static let defaultStyle: Style = .prefixed

    private static let prefix = "recUdra-"
    private static let randomLength = 8
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func generate(style: Style = defaultStyle) -> String {
        switch style {
        case .prefixed:
            return prefix + String((0..<randomLength).compactMap { _ in alphabet.randomElement() })
        case .uuid:
            return UUID().uuidString
        }
    }
}
