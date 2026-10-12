import CoreMedia
import Foundation

/// Measures how much media has gone past, as a span between the first and
/// last presentation timestamps seen.
///
/// Exists for audio-only recordings. With a picture, `FrameComposer`
/// already tracks this from the frames it renders, and the recorder reads
/// it from there; without one there is no composer at all, and something
/// still has to answer "how long is this recording so far" for the outro
/// and the duration accounting.
///
/// Written from the ScreenCaptureKit sample queue and read from the
/// recorder's actor, hence the lock.
final class MediaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: CMTime?
    private var last: CMTime?

    func note(_ pts: CMTime, duration: CMTime) {
        guard pts.isValid else { return }
        // The sample's own length is included so the clock reports the end
        // of the last buffer rather than its start - at 48kHz in ~10ms
        // chunks that's small, but it's the difference between a duration
        // that converges on the truth and one that always runs short.
        let end = duration.isValid && duration.isNumeric ? pts + duration : pts
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = pts }
        last = end
    }

    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let first, let last else { return 0 }
        let span = (last - first).seconds
        return span.isFinite && span > 0 ? span : 0
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        first = nil
        last = nil
    }
}
