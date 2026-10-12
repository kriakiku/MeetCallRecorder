import AppKit
import CoreGraphics
import CoreImage

/// The two backgrounds the app draws itself: the cutting mat and the
/// per-meeting gradient. Neither touches the network, so both double as
/// the fallback when a photo can't be fetched.
enum BackgroundArtwork {

    // MARK: - Cutting mat

    /// A self-healing cutting mat: deep blue board, white grid, angle
    /// guides at the corners, edge ticks.
    ///
    /// Everything is sized off the canvas height rather than fixed pixels,
    /// so 720p and 1440p get the same board at different resolutions
    /// instead of a differently-proportioned one.
    static func cuttingMat(size: CGSize) -> CGImage? {
        guard let context = makeContext(size: size) else { return nil }

        // Not flat: a real mat picks up a sheen from above, and a plain
        // fill reads as a coloured rectangle rather than as plastic.
        drawLinearGradient(
            in: context,
            size: size,
            colors: [
                CGColor(red: 0.078, green: 0.247, blue: 0.369, alpha: 1),
                CGColor(red: 0.047, green: 0.161, blue: 0.251, alpha: 1),
                CGColor(red: 0.031, green: 0.110, blue: 0.180, alpha: 1)
            ],
            locations: [0, 0.55, 1]
        )

        // One "inch" is a twelfth of the height, which keeps the familiar
        // mat proportions on any canvas: roughly 21 x 12 cells at 16:9.
        let unit = size.height / 12
        let margin = unit * 0.6

        context.setLineCap(.butt)

        // Minor grid first, then major over it - drawing the bright lines
        // last keeps the intersections crisp rather than letting the
        // half-alpha minor lines wash over them.
        strokeGrid(
            context, size: size, margin: margin, spacing: unit / 2,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.095),
            lineWidth: max(0.5, unit * 0.006)
        )
        strokeGrid(
            context, size: size, margin: margin, spacing: unit,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.26),
            lineWidth: max(0.8, unit * 0.011)
        )

        drawBorder(context, size: size, margin: margin, unit: unit)
        drawAngleGuides(context, size: size, margin: margin, unit: unit)
        drawEdgeTicks(context, size: size, margin: margin, unit: unit)

        guard let flat = context.makeImage() else { return nil }
        // A touch of grain breaks up the large flat areas, which otherwise
        // band badly once the encoder gets to them.
        return addGrain(to: flat, size: size, intensity: 0.022) ?? flat
    }

    /// The outer cut border - a brighter double rule, the way a mat's
    /// printed edge reads.
    private static func drawBorder(_ context: CGContext, size: CGSize, margin: CGFloat, unit: CGFloat) {
        let outer = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
        context.setLineWidth(max(1, unit * 0.016))
        context.stroke(outer)

        let inset = unit * 0.16
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        context.setLineWidth(max(0.6, unit * 0.008))
        context.stroke(outer.insetBy(dx: inset, dy: inset))
    }

    /// The 30/45/60° guides a mat carries in its corners for mitre cuts.
    private static func drawAngleGuides(_ context: CGContext, size: CGSize, margin: CGFloat, unit: CGFloat) {
        let length = unit * 3.4
        context.setLineWidth(max(0.7, unit * 0.009))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))

        // Mirrored into all four corners by flipping the direction each
        // ray travels, so one set of angles describes the whole board.
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: margin, y: margin), 1, 1),
            (CGPoint(x: size.width - margin, y: margin), -1, 1),
            (CGPoint(x: margin, y: size.height - margin), 1, -1),
            (CGPoint(x: size.width - margin, y: size.height - margin), -1, -1)
        ]
        for (origin, sx, sy) in corners {
            for degrees in [30.0, 45.0, 60.0] {
                let radians = degrees * .pi / 180
                context.move(to: origin)
                context.addLine(to: CGPoint(
                    x: origin.x + cos(radians) * length * sx,
                    y: origin.y + sin(radians) * length * sy
                ))
            }
        }
        context.strokePath()
    }

    /// Ruler ticks just inside the border, longer every whole unit.
    private static func drawEdgeTicks(_ context: CGContext, size: CGSize, margin: CGFloat, unit: CGFloat) {
        context.setLineWidth(max(0.7, unit * 0.010))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))

        let step = unit / 4
        var x = margin + step
        var index = 1
        while x < size.width - margin {
            let length = index % 4 == 0 ? unit * 0.26 : unit * 0.13
            context.move(to: CGPoint(x: x, y: margin))
            context.addLine(to: CGPoint(x: x, y: margin + length))
            context.move(to: CGPoint(x: x, y: size.height - margin))
            context.addLine(to: CGPoint(x: x, y: size.height - margin - length))
            x += step
            index += 1
        }

        var y = margin + step
        index = 1
        while y < size.height - margin {
            let length = index % 4 == 0 ? unit * 0.26 : unit * 0.13
            context.move(to: CGPoint(x: margin, y: y))
            context.addLine(to: CGPoint(x: margin + length, y: y))
            context.move(to: CGPoint(x: size.width - margin, y: y))
            context.addLine(to: CGPoint(x: size.width - margin - length, y: y))
            y += step
            index += 1
        }
        context.strokePath()
    }

    private static func strokeGrid(_ context: CGContext, size: CGSize, margin: CGFloat, spacing: CGFloat, color: CGColor, lineWidth: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        var x = margin
        while x <= size.width - margin + 0.5 {
            context.move(to: CGPoint(x: x, y: margin))
            context.addLine(to: CGPoint(x: x, y: size.height - margin))
            x += spacing
        }
        var y = margin
        while y <= size.height - margin + 0.5 {
            context.move(to: CGPoint(x: margin, y: y))
            context.addLine(to: CGPoint(x: size.width - margin, y: y))
            y += spacing
        }
        context.strokePath()
    }

    // MARK: - Seeded gradient

    /// An abstract gradient derived from `seed`.
    ///
    /// The brief was "beautiful, no mud, no strange transitions". Mud
    /// comes from *averaging* distant hues - the midpoint of two opposites
    /// in sRGB is grey - so the defence isn't to keep every hue close
    /// together (that just gives a flat, one-colour wash; the first
    /// version did exactly that and looked like a green sheet of paper).
    /// It's to never average at all: the lights are composited with
    /// `plusLighter` over a dark base, so where two of them overlap the
    /// result climbs towards white rather than sinking towards grey. That
    /// makes wider, more interesting spreads safe, so hue offsets come
    /// from a small set of hand-picked harmonies instead of one clamp.
    /// Hue offsets from the base, in turns, always non-negative.
    ///
    /// Wider than they look safe, deliberately. The references this is
    /// chasing get their punch from two genuinely different colours
    /// meeting - pink against cyan, orange against blue - and a ±40°
    /// spread can't do that. What makes the wide ones safe is that the
    /// ribbons are drawn *opaque*: only the blur mixes them, and only in a
    /// band at the boundary.
    ///
    /// All one-sided on purpose. An earlier version had mixed-sign
    /// templates (`[0, 0.11, -0.08]`) and tried to keep them out of the
    /// dead zone by giving each hue arc a permitted direction - which
    /// cannot work, because a template containing both signs walks both
    /// ways whatever the direction says. That's what put chartreuse rings
    /// and brown smears in the output. Here the sign is the caller's to
    /// choose and applies to the whole template at once.
    private static let hueHarmonies: [[Double]] = [
        [0, 0.07, 0.13],            // analogous - calm, close to one colour
        [0, 0.12, 0.20],            // mid spread
        [0, 0.18, 0.31],            // wide
        [0, 0.24, 0.38],            // widest - two clearly different colours
        [0, 0.09, 0.19, 0.30]       // four bands walking round
    ]

    /// The usable arc of the hue wheel, as a start and a length in turns:
    /// 0.32 (green) round through teal, blue, violet, magenta and rose to
    /// 1.0 (red).
    ///
    /// The ~0.08-0.30 gap it leaves out - amber through yellow-green - is
    /// not a matter of taste. Those hues are brown and olive at the
    /// brightnesses a background behind a call window has to sit at, which
    /// is the exact mud the brief ruled out. Treating the good part of the
    /// wheel as one contiguous arc and doing all the harmony arithmetic
    /// *inside* it, with reflection at the ends, is what makes every
    /// resulting hue safe by construction - no per-hue checks, no
    /// after-the-fact clamping, nothing to get wrong when a new harmony is
    /// added.
    private static let safeArcStart = 0.32
    private static let safeArcLength = 0.68

    static func gradient(seed: String, size: CGSize) -> CGImage? {
        var rng = SeededGenerator(seed: seed)

        // Everything hue-related happens as a position along the safe
        // arc, converted to a real hue only at the point of use.
        let basePosition = rng.double(in: 0...safeArcLength)
        let template = hueHarmonies[rng.int(below: hueHarmonies.count)]
        // Side is the seed's choice whenever the template fits that way,
        // and forced only when it doesn't. Always taking the roomier side
        // sounds safer but silently biases every palette towards the
        // middle of the arc - which is violet, and it showed: two thirds
        // of the seeds came out purple.
        let reach = template.max() ?? 0
        var sign: Double = rng.int(below: 2) == 0 ? -1 : 1
        let landing = basePosition + reach * sign
        if landing < 0 || landing > safeArcLength { sign = -sign }
        let harmony = template.map { $0 * sign }
        let angle = rng.double(in: 0...(2 * .pi))

        guard let context = makeContext(size: size) else { return nil }

        // A diagonal two-hue base, which is what gives the picture an
        // overall direction before anything is laid over it.
        drawLinearGradient(
            in: context,
            size: size,
            colors: [
                color(hue: hue(basePosition, offset: 0), saturation: 0.74, brightness: 0.42, alpha: 1),
                color(hue: hue(basePosition, offset: harmony[1] * 0.6), saturation: 0.80, brightness: 0.22, alpha: 1)
            ],
            locations: [0, 1],
            angle: angle
        )

        // Ribbons, not blobs. A radial gradient's boundary is a circle, so
        // stacking them gives concentric haze - which is what the previous
        // version looked like, and is nothing like the references: those
        // are colour regions meeting along *curves*. A very wide bezier
        // stroke blurred past recognition is a curve-bounded region, so
        // that's what these are. Each one enters and leaves off-canvas, so
        // no stroke end is ever visible as a cap inside the frame.
        for (index, step) in harmony.enumerated() {
            let ribbonHue = hue(basePosition, offset: step + rng.double(in: -0.025...0.025) * sign)
            // One light accent so the flow has a highlight to read
            // against; the rest stay deep enough to sit behind a call
            // window without competing with it.
            let brightness = index == 1
                ? rng.double(in: 0.66...0.88)
                : rng.double(in: 0.38...0.62)
            let ribbon = color(
                hue: ribbonHue,
                saturation: rng.double(in: 0.66...0.88),
                brightness: brightness,
                alpha: rng.double(in: 0.78...0.95)
            )

            // The first ribbon is the picture's subject: wide, and routed
            // through the middle. Without that guarantee a seed could put
            // every ribbon's curve out past a corner and leave the canvas
            // as bare base gradient - which happened, and looked like a
            // flat blue rectangle with a smudge in one corner. The rest
            // are narrower accents folding across it.
            let isSubject = index == 0
            let width = (isSubject ? rng.double(in: 0.62...1.00) : rng.double(in: 0.24...0.58)) * size.height

            context.setStrokeColor(ribbon)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(ribbonPath(rng: &rng, size: size, throughCentre: isSubject))
            context.strokePath()
        }

        drawVignette(in: context, size: size)

        guard let raw = context.makeImage() else { return nil }

        // Heavy, and the reason the strokes above can be drawn opaque: at
        // this radius a stroke edge stops being an edge and becomes the
        // transition between two colour fields. Blurring past the canvas
        // and cropping back, because CIGaussianBlur samples transparent
        // black outside the extent and would otherwise darken all four
        // sides.
        let blurred = blur(raw, size: size, radius: Double(size.height) * 0.085) ?? raw
        return addGrain(to: blurred, size: size, intensity: 0.028) ?? blurred
    }

    /// Converts a position-plus-offset in safe-arc space to a real hue.
    ///
    /// Offsets that run off either end are *reflected*, not wrapped:
    /// wrapping would jump the short way across the dead zone and land
    /// exactly in the olive the arc exists to avoid.
    private static func hue(_ position: Double, offset: Double) -> Double {
        var walked = position + offset
        if walked < 0 { walked = -walked }
        if walked > safeArcLength { walked = 2 * safeArcLength - walked }
        return wrap(safeArcStart + min(max(walked, 0), safeArcLength))
    }

    /// A cubic bezier that crosses the canvas, entering and leaving well
    /// outside it.
    ///
    /// Entry and exit are placed on *different* sides, so the curve always
    /// traverses rather than clipping a corner, and both are pushed a long
    /// way out so the round caps of a very wide stroke never appear in
    /// frame. The two control points sit inside the canvas, which is what
    /// bends the stroke into an S rather than a bar.
    private static func ribbonPath(rng: inout SeededGenerator, size: CGSize, throughCentre: Bool) -> CGPath {
        let overshoot = max(size.width, size.height) * 0.55

        // 0 = left, 1 = top, 2 = right, 3 = bottom.
        let entrySide = rng.int(below: 4)
        // Any side but the one it came in on.
        let exitSide = (entrySide + 1 + rng.int(below: 3)) % 4

        func point(onSide side: Int, at t: Double) -> CGPoint {
            switch side {
            case 0: return CGPoint(x: -overshoot, y: t * size.height)
            case 1: return CGPoint(x: t * size.width, y: size.height + overshoot)
            case 2: return CGPoint(x: size.width + overshoot, y: t * size.height)
            default: return CGPoint(x: t * size.width, y: -overshoot)
            }
        }

        let start = point(onSide: entrySide, at: rng.double(in: 0.1...0.9))
        let end = point(onSide: exitSide, at: rng.double(in: 0.1...0.9))
        // Pulled towards the middle for the subject ribbon, free to
        // wander for the accents.
        let spread = throughCentre ? 0.22 : 0.45
        let control1 = CGPoint(
            x: rng.double(in: (0.35 - spread)...(0.35 + spread)) * size.width,
            y: rng.double(in: (0.5 - spread)...(0.5 + spread)) * size.height
        )
        let control2 = CGPoint(
            x: rng.double(in: (0.65 - spread)...(0.65 + spread)) * size.width,
            y: rng.double(in: (0.5 - spread)...(0.5 + spread)) * size.height
        )

        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)
        return path
    }

    /// A soft darkening towards the corners, drawn as an inverted radial
    /// gradient in multiply so it deepens what's there rather than laying
    /// grey over it.
    private static func drawVignette(in context: CGContext, size: CGSize) {
        context.setBlendMode(.multiply)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        drawRadialGradient(
            in: context,
            center: center,
            radius: Double(max(size.width, size.height)) * 0.78,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 0.68, green: 0.66, blue: 0.74, alpha: 1)
            ]
        )
        context.setBlendMode(.normal)
    }

    // MARK: - Drawing helpers

    private static func makeContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func color(hue: Double, saturation: Double, brightness: Double, alpha: Double) -> CGColor {
        let nsColor = NSColor(
            calibratedHue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: alpha
        )
        return nsColor.usingColorSpace(.sRGB)?.cgColor
            ?? CGColor(red: 0, green: 0, blue: 0, alpha: alpha)
    }

    private static func wrap(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    private static func drawLinearGradient(
        in context: CGContext,
        size: CGSize,
        colors: [CGColor],
        locations: [CGFloat],
        angle: Double = .pi / 2
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: locations
        ) else { return }
        // Long enough that the gradient spans the canvas at any angle.
        let reach = max(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = CGPoint(x: center.x - cos(angle) * reach, y: center.y - sin(angle) * reach)
        let end = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawRadialGradient(in context: CGContext, center: CGPoint, radius: Double, colors: [CGColor]) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: []
        )
    }

    private static let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])

    private static func blur(_ image: CGImage, size: CGSize, radius: Double) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: size)
        let source = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        // Clamped first so the blur has something to sample beyond the
        // edges; without it the border fades to transparent.
        filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: canvas) else { return nil }
        return ciContext.createCGImage(output, from: canvas)
    }

    /// Fine monochrome noise, composited very faintly.
    ///
    /// Large smooth gradients are the worst case for an 8-bit encoder -
    /// they come out in visible stair-step bands. A little grain
    /// dithers the steps away and costs almost nothing in bitrate at
    /// this intensity.
    private static func addGrain(to image: CGImage, size: CGSize, intensity: Double) -> CGImage? {
        let canvas = CGRect(origin: .zero, size: size)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let grain = noise
            .cropped(to: canvas)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputBrightnessKey: 0,
                kCIInputContrastKey: 1
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: intensity)
            ])
        let composited = grain.composited(over: CIImage(cgImage: image)).cropped(to: canvas)
        return ciContext.createCGImage(composited, from: canvas)
    }
}
