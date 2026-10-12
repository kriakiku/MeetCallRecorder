import Foundation

/// What fills the canvas behind the call window.
///
/// The window is scaled to fit a centered safe area, so there is always a
/// margin showing - this is what's in it. Resolved once per call (see
/// `BackgroundLibrary`), never per segment, so a call that restarts its
/// writer doesn't change backdrop halfway through.
enum BackgroundMode: String, CaseIterable, Identifiable, Sendable {
    /// The current desktop picture. What the app did before any of this
    /// was configurable, and still the default - it makes a recording
    /// read as a screenshot of a real desktop.
    case desktop
    /// A drawn cutting-mat board: deep blue, gridded, with angle guides.
    /// Always available, identical every time, no network.
    case blueprint
    /// A fresh wallpaper from wallhaven.cc each call - top-rated of the
    /// past year, SFW, general category only.
    case randomPhoto
    /// The same source, but picked from a hash of the meeting ID, so one
    /// recurring huddle keeps the same picture across every recording of
    /// it.
    case seededPhoto
    /// An abstract gradient generated from the meeting ID - stable per
    /// meeting like `seededPhoto`, but drawn locally, so it never waits on
    /// or fails over from the network.
    case seededGradient

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .desktop: return "Desktop picture"
        case .blueprint: return "Cutting mat"
        case .randomPhoto: return "Random photo"
        case .seededPhoto: return "Photo per meeting"
        case .seededGradient: return "Gradient per meeting"
        }
    }

    var summary: String {
        switch self {
        case .desktop:
            return "Whatever your desktop is showing. No network, changes when your wallpaper does."
        case .blueprint:
            return "A drawn blue cutting mat with grid and angle guides. Same every time."
        case .randomPhoto:
            return "A different wallhaven.cc wallpaper each call, from the top-rated of the past year."
        case .seededPhoto:
            return "A wallhaven.cc wallpaper chosen from the meeting ID - the same huddle keeps the same picture."
        case .seededGradient:
            return "A gradient generated from the meeting ID. Stable per meeting, never touches the network."
        }
    }

    /// Whether resolving it can go out to the network, and therefore needs
    /// a cache and a fallback.
    var usesNetwork: Bool {
        self == .randomPhoto || self == .seededPhoto
    }
}

/// A small, stable PRNG so "seeded by meeting ID" means the same thing on
/// every launch.
///
/// `Hasher`/`hashValue` can't be used for any of this: Swift seeds it
/// per-process, so the same meeting would get a different picture every
/// time the app restarted - exactly the thing the seeded modes exist to
/// avoid. This is FNV-1a followed by SplitMix64, both fully specified.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        // A zero state would make SplitMix64 return a constant stream.
        state = hash == 0 ? 0x9e37_79b9_7f4a_7c15 : hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// `0..<upper`, used for picking pages, indices and palettes.
    mutating func int(below upper: Int) -> Int {
        guard upper > 0 else { return 0 }
        return Int(next() % UInt64(upper))
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
