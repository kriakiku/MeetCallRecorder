import AppKit
import CoreGraphics
import DynamicColor
import SwiftUI

/// The background the app draws itself: the per-meeting gradient. It
/// touches no network, so it doubles as the fallback when a photo can't
/// be fetched.
enum BackgroundArtwork {

    // MARK: - Seeded gradient

    /// A 4x4 mesh. Three gives one free interior point, which is a
    /// diagonal wash and not much else; five starts producing bands
    /// narrow enough to read as stripes at the size a background is
    /// actually seen. Four has four free interior points, which is enough
    /// for colour regions to meet along curves - the thing that makes a
    /// mesh gradient look like one.
    private static let meshSide = 4

    /// How far an interior control point may wander from its place on the
    /// regular grid, as a fraction of the canvas.
    ///
    /// A third of the cell spacing. Past that, neighbouring points start
    /// crossing over each other and the patch folds back on itself, which
    /// shows up as a hard crease - the one genuinely ugly failure mode
    /// this has.
    private static let meshJitter = 0.14

    /// How many canvas pixels across one grain of noise is.
    private static let grainScale = 1.6

    /// How far the grain swings either side of neutral. High, and
    /// affordable - see `addGrain` for why a static background makes
    /// this nearly free in the encoder.
    private static let grainIntensity = 0.34

    /// Hue offsets from the base, in turns, always non-negative.
    ///
    /// Wider than they look safe, deliberately. The references this is
    /// chasing get their punch from two genuinely different colours
    /// meeting - pink against cyan, orange against blue - and a +/-40
    /// degree spread can't do that.
    ///
    /// What makes the wide ones safe here is the interpolation: the ramp
    /// between harmony colours is built in Cie L*a*b*, where the midpoint
    /// of two distant hues is still a colour. In sRGB it is grey, and
    /// that grey was the "mud" every earlier version of this was fighting
    /// - the one before this avoided averaging altogether, compositing
    /// opaque blurred ribbons with `plusLighter` so that overlaps climbed
    /// towards white instead. A mesh gradient has no such escape: it
    /// averages everywhere, by definition. Moving the averaging into a
    /// perceptual space is what makes it safe to do.
    ///
    /// All one-sided on purpose. An earlier version had mixed-sign
    /// templates (`[0, 0.11, -0.08]`) and tried to keep them out of the
    /// dead zone by giving each hue arc a permitted direction - which
    /// cannot work, because a template containing both signs walks both
    /// ways whatever the direction says. That's what put chartreuse rings
    /// and brown smears in the output. Here the sign is chosen once and
    /// applies to the whole template.
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
    /// brightnesses a background behind a call window has to sit at,
    /// which is the exact mud the brief ruled out. Treating the good part
    /// of the wheel as one contiguous arc and doing all the harmony
    /// arithmetic *inside* it, with reflection at the ends, is what makes
    /// every resulting hue safe by construction - no per-hue checks, no
    /// after-the-fact clamping, nothing to get wrong when a new harmony
    /// is added.
    ///
    /// This is also why the harmony isn't built with DynamicColor's
    /// `adjustedHue`: that walks the whole wheel and would happily step
    /// into the dead zone.
    private static let safeArcStart = 0.32
    private static let safeArcLength = 0.68

    /// An abstract gradient derived from `seed`.
    ///
    /// Rendered by SwiftUI's `MeshGradient` and rasterized through
    /// `ImageRenderer`, which is why this is main-actor work rather than
    /// the pure Core Graphics drawing it replaced. Same canvas, same
    /// determinism: identical seed and size give an identical bitmap, so
    /// a recurring meeting keeps its background across recordings and
    /// across launches.
    @MainActor
    static func gradient(seed: String, size: CGSize) -> CGImage? {
        var rng = SeededGenerator(seed: seed)
        let colors = meshColors(&rng)
        let points = meshPoints(&rng)

        let content = MeshGradient(
            width: meshSide,
            height: meshSide,
            points: points,
            colors: colors,
            // Perceptual, for the same reason the ramp is built in Lab:
            // this is the interpolation that happens *between* the nodes,
            // and in device space it dips towards grey in exactly the
            // same way.
            colorSpace: .perceptual
        )
        .frame(width: size.width, height: size.height)
        .overlay { vignette(size: size) }

        let renderer = ImageRenderer(content: content)
        // The canvas is already in pixels; letting this follow the screen
        // would make a 1080p background on a Retina Mac a 4K bitmap that
        // the composer then throws half of away.
        renderer.scale = 1
        return renderer.cgImage
    }

    /// One colour per mesh node, arranged around a light.
    ///
    /// The first version of this ran the palette as a flat ramp along the
    /// `row + col` diagonal, and it was the wrong shape: a monotone ramp
    /// interpolated smoothly is a wash, and the mesh might as well have
    /// been a two-stop linear gradient. Nothing in it said *where* the
    /// picture was lit from.
    ///
    /// So the palette is laid out radially instead. A seeded point inside
    /// the canvas is the light; hue walks outward from it along the
    /// harmony, brightness falls away from it, and the far corners get
    /// shaded hardest. That gives the one thing the ramp couldn't - a
    /// focal point - and it also puts the darkest parts at the edges,
    /// which is where a call window needs its background to get out of
    /// the way.
    private static func meshColors(_ rng: inout SeededGenerator) -> [Color] {
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
        if basePosition + reach * sign < 0 || basePosition + reach * sign > safeArcLength {
            sign = -sign
        }

        // Mid-bright and properly saturated. The version before this sat
        // at 0.34-0.52 brightness and then shaded on top of that, which
        // came out as mud - the lesson being that "stays behind the call
        // window" is the job of the falloff and the vignette, not of
        // starting from a colour that has nowhere to go.
        let saturation = rng.double(in: 0.58...0.82)
        let brightness = rng.double(in: 0.50...0.68)
        let stops = template.map { offset -> DynamicColor in
            DynamicColor(
                hue: CGFloat(hue(basePosition, offset: offset * sign)),
                saturation: CGFloat(saturation),
                brightness: CGFloat(brightness),
                alpha: 1
            )
        }

        // Interpolated in Cie L*a*b*: see `hueHarmonies` - in sRGB the
        // midpoint between two distant hues is grey, and a mesh gradient
        // is nothing but midpoints.
        let steps = 8
        let ramp = DynamicGradient(colors: stops).colorPalette(amount: UInt(steps), inColorSpace: .lab)
        guard ramp.count == steps else { return [] }

        // Kept off-centre: a light in the middle of the frame is exactly
        // where the call window goes, and the glow would only ever be
        // seen as a rim around it.
        let light = SIMD2(rng.double(in: 0.12...0.88), rng.double(in: 0.10...0.55))

        var colors: [Color] = []
        for row in 0..<meshSide {
            for col in 0..<meshSide {
                let u = Double(col) / Double(meshSide - 1)
                let v = Double(row) / Double(meshSide - 1)
                // Normalised against the longest distance there can be,
                // the diagonal, so `near` spans the full 0...1 whatever
                // corner the light ended up in.
                let distance = ((u - light.x) * (u - light.x) + (v - light.y) * (v - light.y)).squareRoot()
                // Nudged per node. Pure distance makes the four nodes of
                // an edge row almost equidistant from the light, so they
                // all land on the same colour and the row reads as a
                // straight band across the bottom of the frame - the one
                // place the mesh can't hide a seam, because edge points
                // aren't free to move off their edge. A little noise in
                // the falloff breaks the row up without touching the
                // overall shape.
                let near = min(1, max(0, 1 - distance / 1.4142 + rng.double(in: -0.07...0.07)))

                let color = ramp[min(steps - 1, Int((1 - near) * Double(steps)))]
                colors.append(Color(nsColor: color
                    // `lighter` walks HSL lightness, which desaturates as
                    // it climbs; past about this much the focal point
                    // goes chalky instead of bright.
                    .lighter(amount: CGFloat(near * near * 0.15))
                    // Puts back what `lighter` took out. Without it the
                    // focal point reads as chalk rather than light.
                    .saturated(amount: CGFloat(near * 0.12))
                    .shaded(amount: CGFloat((1 - near) * 0.42))))
            }
        }
        return colors
    }

    /// The mesh control points: a regular grid with the interior shaken
    /// loose.
    ///
    /// Edge points may slide *along* their edge but never off it, and the
    /// four corners don't move at all. A control point that leaves the
    /// unit square pulls the patch with it and leaves the canvas corner
    /// filled by extrapolation, which is where the washed-out triangles
    /// in the first attempt came from.
    private static func meshPoints(_ rng: inout SeededGenerator) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for row in 0..<meshSide {
            for col in 0..<meshSide {
                let onVerticalEdge = col == 0 || col == meshSide - 1
                let onHorizontalEdge = row == 0 || row == meshSide - 1
                let x = Double(col) / Double(meshSide - 1)
                    + (onVerticalEdge ? 0 : rng.double(in: -meshJitter...meshJitter))
                let y = Double(row) / Double(meshSide - 1)
                    + (onHorizontalEdge ? 0 : rng.double(in: -meshJitter...meshJitter))
                points.append(SIMD2(Float(x), Float(y)))
            }
        }
        return points
    }

    /// Darkens the corners, which both frames the call window and hides
    /// the one place a mesh can look mechanical: the straight runs along
    /// the edges, where the control points aren't free to move.
    private static func vignette(size: CGSize) -> some View {
        RadialGradient(
            colors: [.clear, .black.opacity(0.30)],
            center: .center,
            startRadius: size.width * 0.16,
            endRadius: size.width * 0.75
        )
    }

    /// A hue in turns, `offset` from `position`, kept inside the safe arc
    /// by reflecting at its ends rather than wrapping - wrapping would
    /// jump the short way across the dead zone and land in exactly the
    /// olive the arc exists to avoid.
    private static func hue(_ position: Double, offset: Double) -> Double {
        var walked = position + offset
        if walked < 0 { walked = -walked }
        if walked > safeArcLength { walked = 2 * safeArcLength - walked }
        return wrap(safeArcStart + max(0, min(safeArcLength, walked)))
    }

    private static func wrap(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }
}
