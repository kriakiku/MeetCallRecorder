import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Composites each captured window frame onto a fixed-size canvas: the
/// call's chosen background, the window scaled (preserving
/// aspect ratio) to fit within a centered safe area, never touching the
/// `safeInset`-pixel margin. Output is always `outputSize` regardless of
/// the window's actual size - that's the point (fixed 1920x1080/30fps
/// stream even though call windows get resized/moved).
///
/// That is now the whole job. Every plate - welcome, pause, resize,
/// closing - is drawn later by `RecordingAssembler` from the events logged
/// beside the segments, so nothing here has to animate, freeze, or
/// anticipate anything; the one thing the capture path does is turn a
/// sample into a frame, as fast as it can.
/// Asserts sole ownership of a value that region isolation can't prove is
/// disconnected, so it can be handed to a `sending` parameter.
///
/// Both uses are the same shape: a buffer vended by a pool (or copied from
/// a sample) is ours alone in fact - the pool only ever hands out buffers
/// with no outstanding references, and nothing here writes to it once it's
/// passed on (the composer keeps the last frame only to copy it from) -
/// but the checker sees it came from something reachable via `self` and
/// refuses. This states the guarantee the API already relies on; it's the
/// one thing the old `append` left entirely implicit.
struct SoleOwned<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class FrameComposer {
    private let outputSize: CGSize
    private let safeInset: CGFloat
    // Explicit sRGB working/output space for every frame, real or
    // synthetic - without this, a frame built from a CGImage (the title
    // cards) and a frame built from a live ScreenCaptureKit buffer can
    // carry different embedded color profiles even at identical
    // dimensions/pixel format, and AVAssetWriter choking on a color-space
    // change mid-fragment is the leading theory for why recordings were
    // dying in AVAssetWriter right around the first 5s movieFragmentInterval
    // boundary - which lines up suspiciously well with the opening card's
    // ~4.8s duration.
    private static let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let ciContext = CIContext(options: [
        .workingColorSpace: workingColorSpace,
        .outputColorSpace: workingColorSpace
    ])
    private let backgroundImage: CIImage
    private var pixelBufferPool: CVPixelBufferPool?
    /// Synthetic frames get cropped to exactly this before being handed
    /// to `ciContext.render`: a layer whose extent is larger than the
    /// canvas makes `render(_:to:)` fit the *whole* extent into the buffer
    /// rather than clipping at the canvas edge.
    private var canvasRect: CGRect { CGRect(origin: .zero, size: outputSize) }

    /// How long a plate takes to fade in or out. Lives here rather than in
    /// the assembler because the look is this type's business - it is the
    /// same transition the card backdrop below is designed for - and the
    /// assembler reads it to size its own transition frames.
    static let cardTransitionDuration: Double = 0.8
    /// The resize plate's own, much shorter fade. A resize lasts as long as
    /// a drag lasts, which can be a fraction of a second; a transition
    /// sized for a pause would be most of the event.
    static let resizeTransitionDuration: Double = 0.25

    /// A macOS window's corner radius, in points.
    ///
    /// Measured off a live capture of the Meet window under this app's own
    /// stream configuration: alpha crosses 50% 15px in along each edge, and
    /// 4.3px in along the corner's diagonal - which is the 0.293·r that a
    /// circular arc of r=15 gives, so a plain rounded rect is a faithful
    /// stand-in for the system's slightly squircular corner at this size.
    ///
    /// A windowed call already arrives with its corners cut out of the
    /// alpha channel (that's what `shouldBeOpaque = false` buys), so
    /// masking it again changes nothing. A *fullscreen* call is the case
    /// this exists for: the app swaps in a display-sized window with square
    /// corners, and pasted onto the wallpaper that reads as a screenshot of
    /// a screen rather than as a window sitting on a desktop.
    private static let windowCornerRadius: CGFloat = 15
    private var sessionStartPTS: CMTime?
    /// The PTS of the most recently rendered output frame - what
    /// `contentDuration` measures against.
    private(set) var lastRenderedPTS: CMTime?
    /// The PTS of the last frame that came out of a real captured image -
    /// `repeatLastFrame` advances `lastRenderedPTS` but not this. The
    /// resize watch needs the distinction: during a drag the stream stops
    /// delivering real frames and the output fills with repeats of the
    /// pre-drag picture, so "the bounds have settled" says nothing about
    /// whether the *recording* shows the new size yet.
    private(set) var lastRealPTS: CMTime?
    /// What `repeatLastFrame` copies from.
    private var lastOutputBuffer: CVPixelBuffer?

    /// `background` arrives already cover-fitted to `outputSize` - see
    /// BackgroundLibrary, which resolves it once per call. It's passed in
    /// rather than loaded here because the photo modes go to the network,
    /// and nothing on the sample path can wait on that. Nil means black,
    /// which is also what a desktop with no picture set gets.
    init(outputSize: CGSize, safeInset: CGFloat, background: CGImage?) {
        self.outputSize = outputSize
        self.safeInset = safeInset
        self.backgroundImage = background.map { CIImage(cgImage: $0) }
            ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
        self.pixelBufferPool = Self.makePixelBufferPool(size: outputSize)
    }

    /// Tucked into the bottom-right corner by two equal gaps - as far in
    /// from the right edge as it is up from the bottom one.
    ///
    /// The vertical gap isn't chosen, it's whatever is left over from
    /// centering the text in the bottom margin: the strip below the window
    /// content, which is the one place on the canvas the window can never
    /// reach. The horizontal gap just matches it, so the stamp sits on the
    /// corner's diagonal instead of being pushed a whole safe inset in
    /// while staying only a few pixels up.
    ///
    /// Both are measured to the text rather than to the bitmap: the stamp
    /// carries a transparent margin for its shadow, and aligning that
    /// would inset the text by the shadow's width and lift it out of the
    /// strip.
    private static func cornerStamp(_ image: CGImage, outputSize: CGSize, inset: CGFloat) -> CIImage {
        let stamp = CIImage(cgImage: image)
        let padding = TitleCardRenderer.recordingIDPadding
        let textHeight = stamp.extent.height - padding * 2
        let gap = (inset - textHeight) / 2
        return stamp.transformed(by: CGAffineTransform(
            translationX: outputSize.width - gap - stamp.extent.width + padding,
            y: gap - padding
        ))
    }

    private static func makePixelBufferPool(size: CGSize) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return pool
    }

    /// One rendered output frame: a pixel buffer at `outputSize` and the
    /// time it should be presented at. AVAssetWriter's pixel buffer
    /// receiver takes exactly this pair, so there's no CMSampleBuffer (or
    /// format description) to build any more.
    ///
    /// Read-only is not just a formality: the receiver takes the buffer as
    /// `sending`, i.e. it wants sole ownership, and the wrap happens here -
    /// at the one point where the buffer is provably nobody else's, having
    /// just come out of the pool and been rendered into. That's the same
    /// "don't hand over something you might still be writing to" rule the
    /// old API left entirely to the caller.
    typealias Frame = (buffer: CVReadOnlyPixelBuffer, pts: CMTime)

    /// Renders the window content from `source`, scaled/centered into the
    /// safe area over the wallpaper. Keeps `source`'s presentation time so
    /// A/V sync and frame pacing survive unchanged.
    func compose(_ source: CMSampleBuffer) -> Frame? {
        guard let pool = pixelBufferPool, let inputPixelBuffer = CMSampleBufferGetImageBuffer(source) else { return nil }

        let windowImage = CIImage(cvPixelBuffer: inputPixelBuffer)
        let availableWidth = outputSize.width - safeInset * 2
        let availableHeight = outputSize.height - safeInset * 2
        let scale = min(availableWidth / windowImage.extent.width, availableHeight / windowImage.extent.height)
        let scaledWindow = windowImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let dx = (outputSize.width - scaledWindow.extent.width) / 2 - scaledWindow.extent.minX
        let dy = (outputSize.height - scaledWindow.extent.height) / 2 - scaledWindow.extent.minY
        let positionedWindow = scaledWindow.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        // The radius is cut at output resolution, after the scale down, so
        // the arc is as crisp as the canvas allows - and it's measured
        // through the same scale the window itself went through, so the
        // corner comes out exactly as round as a real window of this size
        // seen at this reduction, fullscreen or not.
        let pointsToCanvas = scale * Self.pixelsPerPoint(of: source, bufferWidth: windowImage.extent.width)
        let roundedWindow = Self.roundingCorners(positionedWindow, radius: Self.windowCornerRadius * pointsToCanvas)

        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(source)
        if sessionStartPTS == nil { sessionStartPTS = sourcePTS }
        let composed = roundedWindow.composited(over: backgroundImage)

        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBuffer)
        guard let outputPixelBuffer else { return nil }
        render(composed, into: outputPixelBuffer)

        lastRenderedPTS = sourcePTS
        lastRealPTS = sourcePTS
        lastOutputBuffer = outputPixelBuffer
        return (Self.handOff(outputPixelBuffer), sourcePTS)
    }

    /// The previous output frame again, at `pts` - for the samples
    /// ScreenCaptureKit delivers with no image at all because nothing in
    /// the window changed.
    ///
    /// The video track must not go quiet while audio keeps coming. A
    /// still window (cameras off, a static slide) yields nothing but such
    /// samples, and a fragmented writer left with audio running seconds
    /// ahead of the last video frame fails with -16341 - reproduced on a
    /// motionless window with no resize involved, and gone with either
    /// the fragmenting or the audio track removed, or with this.
    ///
    /// Copied into a fresh pool buffer rather than handed over again: the
    /// one already passed on belongs to the writer now. Only ever read
    /// from here after that, never written.
    func repeatLastFrame(at pts: CMTime) -> Frame? {
        guard let pool = pixelBufferPool, let last = lastOutputBuffer, pts.isValid else { return nil }
        if let previous = lastRenderedPTS, CMTimeCompare(pts, previous) <= 0 { return nil }

        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBuffer)
        guard let outputPixelBuffer else { return nil }
        render(CIImage(cvPixelBuffer: last), into: outputPixelBuffer)

        lastRenderedPTS = pts
        lastOutputBuffer = outputPixelBuffer
        return (Self.handOff(outputPixelBuffer), pts)
    }

    /// How much has actually been written to the output timeline -
    /// wall-clock time from start() to stop() isn't the same thing, since
    /// a grace period spent waiting for a lost window to come back
    /// produces zero frames but still takes real time.
    var contentDuration: TimeInterval {
        guard let start = sessionStartPTS, let last = lastRenderedPTS else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(last, start))
    }

    /// `contentDuration`, but measured to the last *real* frame - see
    /// `lastRealPTS`.
    var realContentDuration: TimeInterval {
        guard let start = sessionStartPTS, let last = lastRealPTS else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(last, start))
    }

    /// How many buffer pixels one screen point is, for the window in
    /// `sample`. ScreenCaptureKit reports the captured content's rect in
    /// points with every frame, and the buffer is that rect at the
    /// display's backing scale, so the ratio is the scale - read off the
    /// sample rather than from `NSScreen.main`, which is the *focused*
    /// screen and need not be the one the call is on. Falls back to it
    /// anyway if the attachment is ever missing.
    private static func pixelsPerPoint(of sample: CMSampleBuffer, bufferWidth: CGFloat) -> CGFloat {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rectDict = attachments.first?[.contentRect] as? NSDictionary,
              let contentRect = CGRect(dictionaryRepresentation: rectDict),
              contentRect.width >= 1 else {
            return NSScreen.main?.backingScaleFactor ?? 2
        }
        return bufferWidth / contentRect.width
    }

    /// Cuts rounded corners of `radius` out of `image`'s alpha channel -
    /// see `windowCornerRadius` for why a square-cornered capture needs
    /// them. A no-op for anything too small to round.
    ///
    /// Source-in keeps the premultiplied invariant the rest of this file
    /// is careful about: it scales colour and alpha by the mask's alpha
    /// together, so an antialiased edge pixel stays a valid premultiplied
    /// pixel rather than the RGB > A nonsense that used to kill the writer.
    private static func roundingCorners(_ image: CIImage, radius: CGFloat) -> CIImage {
        let rect = image.extent
        guard radius >= 1, rect.width > radius * 2, rect.height > radius * 2,
              let generator = CIFilter(name: "CIRoundedRectangleGenerator"),
              let masking = CIFilter(name: "CISourceInCompositing") else { return image }
        generator.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        generator.setValue(radius, forKey: kCIInputRadiusKey)
        generator.setValue(CIColor.white, forKey: kCIInputColorKey)
        guard let mask = generator.outputImage else { return image }
        masking.setValue(image, forKey: kCIInputImageKey)
        masking.setValue(mask, forKey: kCIInputBackgroundImageKey)
        return masking.outputImage?.cropped(to: rect) ?? image
    }

    /// The single way anything becomes an output frame.
    private func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        ciContext.render(image.cropped(to: canvasRect), to: buffer)
    }

    /// The sealed look a plate's text sits on: blurred and darkened, and
    /// completely static for as long as the plate is up.
    private static let cardBackdropBlurRadius: Double = 24
    private static let cardBackdropDarkenFactor: CGFloat = 0.45

    /// Gaussian blur that samples edge-extended pixels instead of the
    /// transparent black that lies outside an image's extent.
    ///
    /// Without the clamp the blur mixes that transparent black into every
    /// border pixel, so a card's "sealed" backdrop carries a dark,
    /// semi-transparent frame all the way around it. On the card itself that
    /// reads as a black vignette; the moment the card fades out it looks
    /// like the black border *disappears* and a background appears under
    /// it, because what shows through is the real, un-blurred wallpaper.
    /// Clamping makes the blur spill the edge content outward instead of
    /// fading into nothing, which is what a frosted panel actually does.
    private static func blurred(_ image: CIImage, radius: Double, clippedTo rect: CGRect) -> CIImage {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return (filter.outputImage ?? image).cropped(to: rect)
    }

    /// Wraps a freshly rendered pool buffer for handing to the writer.
    /// See `SoleOwned` for why the assertion is needed and why it holds.
    private static func handOff(_ buffer: CVPixelBuffer) -> sending CVReadOnlyPixelBuffer {
        CVReadOnlyPixelBuffer(unsafeBuffer: SoleOwned(buffer).value)
    }

    /// Composites `card` over a blurred, darkened `still` - the look every
    /// plate shares, from the welcome card to the one held up while the
    /// window is being resized. Falls back to the call's background when
    /// there's no still to use, which is the welcome plate's case: it
    /// isn't standing in for a picture that was just there, so it gets the
    /// same backdrop the recording itself is about to sit on.
    static func composeCardOverStill(card: CGImage, still: CGImage?, background: CGImage?, outputSize: CGSize, safeInset: CGFloat, recordingID: CGImage?) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: outputSize)
        let base = still.map { CIImage(cgImage: $0) }
            ?? background.map { CIImage(cgImage: $0) }
            ?? CIImage(color: .black).cropped(to: canvas)

        let backdrop = blurred(base.cropped(to: canvas), radius: cardBackdropBlurRadius, clippedTo: canvas)
            .applyingComponentMultiply(cardBackdropDarkenFactor)

        var composed = CIImage(cgImage: card).composited(over: backdrop)
        if let recordingID {
            composed = cornerStamp(recordingID, outputSize: outputSize, inset: safeInset).composited(over: composed)
        }
        composed = composed.cropped(to: canvas)
        let context = CIContext(options: [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: workingColorSpace
        ])
        return context.createCGImage(composed, from: canvas)
    }
}

extension CIImage {
    /// Fades opacity to `alpha` (0 = fully transparent, 1 = unchanged).
    /// Both our sources (a live capture via CIImage(cvPixelBuffer:) and a
    /// card via CIImage(cgImage:) from a premultipliedLast CGContext) carry
    /// *premultiplied* alpha, so scaling only the A channel - the obvious
    /// first thing to try - leaves RGB > A, which isn't a valid premultiplied
    /// pixel. CIContext.render happily writes that nonsense into the output
    /// buffer, and AVAssetWriter was the one paying for it: recordings were
    /// dying with -16341 right as the first opening-card transition ran.
    /// Scaling R/G/B/A together keeps the premultiplied
    /// invariant (RGB <= A) intact at every step of the fade.
    func applyingAlpha(_ alpha: Double) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return self }
        filter.setValue(self, forKey: kCIInputImageKey)
        let a = CGFloat(alpha)
        filter.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: a, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: a, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: a), forKey: "inputAVector")
        return filter.outputImage ?? self
    }

    /// Multiplies RGB by `factor`, leaving alpha untouched - a cheap
    /// "darken" for the backdrop a plate's text sits on.
    func applyingComponentMultiply(_ factor: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return self }
        filter.setValue(self, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: factor, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: factor, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: factor, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return filter.outputImage ?? self
    }
}
