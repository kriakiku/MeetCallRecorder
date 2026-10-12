import CoreGraphics
import Foundation
import ImageIO

/// The wallpapers bundled with the app, used only by the background
/// preview in settings.
///
/// The preview draws four cards at once, and for the two photo modes
/// resolving them for real would mean eight wallhaven downloads every
/// time the tab is opened or the mode is changed - a lot of traffic for a
/// picture nobody is recording. These stand in instead: the same kind of
/// wallpaper, from the same pool. Eight of them at 640x360 in WebP cost
/// less than the three 1280x720 ones they replaced - the cards are 256
/// points wide, so 640x360 is already the size the preview resolves to
/// and anything larger was only ever thrown away.
///
/// They never reach a recording. `BackgroundLibrary` doesn't know they
/// exist; a real call always resolves its background for real.
///
/// Split into two sets of four, one per photo mode, so that no card ever
/// repeats a picture its neighbour is already showing - the modes differ
/// in *which meeting gets which*, and a duplicate anywhere in the deck
/// muddles that.
///
/// Attribution for all eight is in Resources/CREDITS.txt, which the About
/// tab can open.
enum SampleBackground: String, CaseIterable, Sendable {
    // Shown for "Photo per meeting": four photographs and illustrations
    // far enough apart that four cards side by side read as four
    // different meetings at a glance.
    /// Vilnius old town - warm, hazy, detailed.
    case vilnius = "sample-4xl39z"
    /// A workshop interior at night - dark blue, the darkest of the set.
    case workshop = "sample-jel1jq"
    /// Ears of wheat in close-up - solid gold, almost abstract.
    case wheat = "sample-2168qx"
    /// A bus on a country road under cooling towers - pale and flat.
    case busStop = "sample-7jx91o"

    // Shown for "Random photo".
    /// A locomotive on a freight line - green and grey, mid-tone.
    case locomotive = "sample-4dj973"
    /// A hillside above city lights at dusk - deep blue and pink.
    case dusk = "sample-pomo69"
    /// An empty side street at dawn - grey, overcast, photographic.
    case street = "sample-og7g27"
    /// A seafront terrace with wind turbines - bright teal.
    case seafront = "sample-5yp5q3"
}

/// Loads and caches the bundled samples, cover-fitted to the canvas like
/// every other background.
actor SampleBackgrounds {
    static let shared = SampleBackgrounds()

    private var cache: [String: CGImage] = [:]

    private init() {}

    /// nil when the app is running as a bare executable rather than from
    /// the .app bundle, which is also the case where there is no Settings
    /// window worth looking at - the preview just shows its placeholder.
    func image(_ sample: SampleBackground, size: CGSize) -> CGImage? {
        let key = "\(sample.rawValue)-\(Int(size.width))x\(Int(size.height))"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: sample.rawValue, withExtension: "webp", subdirectory: "Backgrounds")
                ?? Bundle.main.url(forResource: sample.rawValue, withExtension: "webp") else {
            Log.write("sample background: \(sample.rawValue).webp missing from the bundle")
            return nil
        }
        // WebP has been a first-class ImageIO format since macOS 11, so
        // this is the same decode path the downloaded JPEGs take.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let fitted = BackgroundLibrary.fit(decoded, to: size) else {
            Log.write("sample background: \(sample.rawValue).webp wouldn't decode")
            return nil
        }
        cache[key] = fitted
        return fitted
    }
}
