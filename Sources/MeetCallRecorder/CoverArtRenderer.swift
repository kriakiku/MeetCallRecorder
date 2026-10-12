import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The artwork embedded in a finished recording's container, already
/// JPEG-encoded and therefore safe to hand to the assembler on another
/// actor - which is why this is a plain struct outside the renderer rather
/// than a pair of CGImages.
///
/// Two shapes because the players disagree about what they want: a video
/// file's artwork is shown in a 16:9 slot (and reads as a poster frame),
/// while anything playing an `.m4a` shows a square album tile. The wide
/// one is skipped for audio-only output, which carries the square alone.
struct CoverArt: Sendable {
    let wide: Data?
    let square: Data?
}

/// Draws the recording's cover art: the welcome screen's own look - dark
/// field, the gradient bloom at the top, a glowing mark in the middle -
/// carrying this call's identity instead of the app's greeting.
///
/// What sits in the middle is the *call's* icon (Google Meet, Slack),
/// since that's what the file is a recording of; our own mark is a small
/// half-opacity tile in the top corner, there to say who made the file
/// without competing with it. The one piece of information the welcome
/// screen has no equivalent for - how long the meeting ran - gets a pill
/// of its own under the title, because it's the thing you want off a cover
/// at a glance.
///
/// Rendered at well under the video's resolution and JPEG'd fairly hard:
/// this is a thumbnail in a player's sidebar, not something anyone looks
/// at full-size, and it rides inside the recording's container where every
/// kilobyte is dead weight on an otherwise lean file.
@MainActor
enum CoverArtRenderer {
    /// 16:9 at well below even 720p output - a quarter of the pixels of
    /// the smallest video the app produces.
    private static let wideSize = CGSize(width: 1024, height: 576)
    /// Sized for the square tile media players show for an audio file;
    /// 720 is comfortably above what any of them render it at.
    private static let squareSize = CGSize(width: 720, height: 720)
    /// Low enough to keep both covers inside ~100 KB together, high
    /// enough that the gradients don't band - the one thing in this
    /// picture JPEG is actually bad at.
    private static let jpegQuality: CGFloat = 0.72

    /// Every length in `draw` is a multiple of this, measured against the
    /// wide cover's height - so the square cover, being shorter and
    /// narrower, comes out proportionally larger-featured rather than the
    /// same layout squeezed.
    private static let referenceHeight: CGFloat = 576

    // MARK: - Palette

    /// The welcome mark's two gradient stops, reused here so the artwork
    /// and the first screen the user ever saw are recognizably the same
    /// product.
    private static let indigo = NSColor(srgbRed: 0.42, green: 0.33, blue: 0.98, alpha: 1)
    private static let pink = NSColor(srgbRed: 0.93, green: 0.27, blue: 0.47, alpha: 1)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Entry point

    /// `includeWide` is false for audio-only recordings: an `.m4a` has no
    /// 16:9 anything, and the wide cover would be a few dozen kilobytes
    /// nothing would ever display.
    static func render(
        appIcon: NSImage?,
        appName: String,
        callID: String,
        startDate: Date,
        meetingDuration: TimeInterval,
        includeWide: Bool
    ) -> CoverArt {
        func encode(_ size: CGSize) -> Data? {
            guard let image = draw(
                size: size,
                icon: appIcon,
                appName: appName,
                callID: callID,
                startDate: startDate,
                meetingDuration: meetingDuration
            ) else { return nil }
            return jpeg(image)
        }

        return CoverArt(
            wide: includeWide ? encode(wideSize) : nil,
            square: encode(squareSize)
        )
    }

    // MARK: - Drawing

    private static func draw(
        size: CGSize,
        icon: NSImage?,
        appName: String,
        callID: String,
        startDate: Date,
        meetingDuration: TimeInterval
    ) -> CGImage? {
        // Opaque: a cover is always composited onto something by whoever
        // displays it, and JPEG has no alpha to carry anyway.
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let scale = size.height / referenceHeight
        let inset = 40 * scale
        let maxTextWidth = size.width - inset * 4

        drawBackdrop(in: ctx, size: size)

        // The block is centered as a whole, so its height has to be known
        // before anything is drawn - the same reason the title cards
        // measure first and draw second.
        let iconSize = 168 * scale
        let title = fitted(appName, font: rounded(44 * scale, .semibold), color: .white, maxWidth: maxTextWidth)
        let subtitle = fitted(callID, font: .systemFont(ofSize: 27 * scale, weight: .regular),
                              color: NSColor.white.withAlphaComponent(0.82), maxWidth: maxTextWidth)
        let durationText = fitted(TitleCardRenderer.formatDuration(meetingDuration),
                                  font: rounded(25 * scale, .medium), color: .white, maxWidth: maxTextWidth)
        let pillHeight = 50 * scale
        let caption = fitted(dateFormatter.string(from: startDate),
                             font: .systemFont(ofSize: 19 * scale, weight: .regular),
                             color: NSColor.white.withAlphaComponent(0.5), maxWidth: maxTextWidth)

        let gapUnderIcon = 34 * scale
        let gapUnderTitle = 12 * scale
        let gapUnderSubtitle = 26 * scale
        let gapUnderPill = 20 * scale
        let blockHeight = iconSize + gapUnderIcon
            + title.size().height + gapUnderTitle
            + subtitle.size().height + gapUnderSubtitle
            + pillHeight + gapUnderPill
            + caption.size().height

        // Nudged down a little from dead center: the attribution tile and
        // the bloom both weigh on the top of the picture.
        var cursorY = (size.height + blockHeight) / 2 - 10 * scale

        let iconRect = CGRect(x: (size.width - iconSize) / 2, y: cursorY - iconSize, width: iconSize, height: iconSize)
        drawHalo(in: ctx, around: iconRect, scale: scale)
        if let icon {
            withShadow(blur: 26 * scale, offsetY: -10 * scale) {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else {
            // No icon for the source app - an uninstalled web app, or a
            // call recovered from staging whose owner has since gone away.
            // Our own mark stands in, which is also what the welcome
            // screen shows there.
            withShadow(blur: 26 * scale, offsetY: -10 * scale) {
                drawAppMark(in: ctx, rect: iconRect, sheen: true)
            }
        }
        cursorY -= iconSize + gapUnderIcon

        cursorY = drawCentered(title, at: cursorY, width: size.width) - gapUnderTitle
        cursorY = drawCentered(subtitle, at: cursorY, width: size.width) - gapUnderSubtitle

        let pillWidth = durationText.size().width + 34 * scale + pillHeight * 0.55
        let pillRect = CGRect(
            x: (size.width - pillWidth) / 2,
            y: cursorY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
        drawDurationPill(in: ctx, rect: pillRect, text: durationText, scale: scale)
        cursorY -= pillHeight + gapUnderPill

        _ = drawCentered(caption, at: cursorY, width: size.width)

        drawAttribution(in: ctx, size: size, inset: inset, scale: scale)

        return ctx.makeImage()
    }

    /// `WelcomeBackdrop` in Core Graphics: an ellipse of indigo fading
    /// through pink, anchored to the top edge. Drawn into a y-squashed
    /// space because that gradient is elliptical on the welcome screen
    /// too - a circular one rises too far down the picture and turns the
    /// whole cover purple.
    ///
    /// The base is a fixed dark field rather than `windowBackgroundColor`:
    /// a cover is looked at in whatever player opens the file, which has
    /// no appearance to follow, and the bloom's opacities are lifted a
    /// little to carry over that darker base.
    private static func drawBackdrop(in ctx: CGContext, size: CGSize) {
        let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor,
            NSColor(srgbRed: 0.05, green: 0.05, blue: 0.065, alpha: 1).cgColor
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])

        guard let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            indigo.withAlphaComponent(0.38).cgColor,
            pink.withAlphaComponent(0.14).cgColor,
            indigo.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 0.45, 1]) else { return }

        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height)
        ctx.scaleBy(x: 1, y: 0.62)
        ctx.drawRadialGradient(
            bloom,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: size.width * 0.85,
            options: []
        )
        ctx.restoreGState()
    }

    /// The welcome mark's two breathing halos, caught mid-breath: a still
    /// picture gets one of each, offset from one another the way the
    /// animated pair is offset in phase.
    private static func drawHalo(in ctx: CGContext, around rect: CGRect, scale: CGFloat) {
        func halo(_ color: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                color.withAlphaComponent(alpha).cgColor,
                color.withAlphaComponent(alpha * 0.35).cgColor,
                color.withAlphaComponent(0).cgColor
            ] as CFArray, locations: [0, 0.5, 1]) else { return }
            ctx.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius,
                options: []
            )
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        halo(indigo, center: CGPoint(x: center.x - 14 * scale, y: center.y + 10 * scale),
             radius: rect.width * 1.05, alpha: 0.42)
        halo(pink, center: CGPoint(x: center.x + 18 * scale, y: center.y - 14 * scale),
             radius: rect.width * 0.85, alpha: 0.30)
    }

    /// The meeting's length, in a glass pill with a record dot - the only
    /// element on the cover that isn't borrowed from the welcome screen,
    /// and the one thing someone scanning a folder of recordings actually
    /// reads off the artwork.
    private static func drawDurationPill(in ctx: CGContext, rect: CGRect, text: NSAttributedString, scale: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()
        ctx.restoreGState()

        let dotDiameter = rect.height * 0.26
        let dotRect = CGRect(
            x: rect.minX + 17 * scale,
            y: rect.midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        )
        ctx.saveGState()
        ctx.setFillColor(pink.cgColor)
        ctx.fillEllipse(in: dotRect)
        ctx.restoreGState()

        let textSize = text.size()
        text.draw(at: CGPoint(x: dotRect.maxX + 12 * scale, y: rect.midY - textSize.height / 2))
    }

    /// Our own mark and name in the top corner at a little over half
    /// opacity - present if you look, invisible if you're looking at the
    /// meeting instead, which is the whole point of putting it up there
    /// rather than in the middle where the welcome screen has it.
    private static func drawAttribution(in ctx: CGContext, size: CGSize, inset: CGFloat, scale: CGFloat) {
        let markSize = 26 * scale
        let markRect = CGRect(x: inset, y: size.height - inset - markSize, width: markSize, height: markSize)

        ctx.saveGState()
        ctx.setAlpha(0.6)
        drawAppMark(in: ctx, rect: markRect, sheen: false)
        ctx.restoreGState()

        let label = NSAttributedString(string: "MeetCallRecorder", attributes: [
            .font: rounded(15 * scale, .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ])
        let labelSize = label.size()
        label.draw(at: CGPoint(x: markRect.maxX + 9 * scale, y: markRect.midY - labelSize.height / 2))
    }

    /// `WelcomeIconMark` in one still frame: gradient tile, glass sheen,
    /// hairline border, record glyph. Everything is a fraction of `rect`
    /// so the same drawing serves the 26pt attribution tile and the
    /// 168pt stand-in for a missing app icon.
    private static func drawAppMark(in ctx: CGContext, rect: CGRect, sheen: Bool) {
        let radius = rect.width * 0.242
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            indigo.cgColor, pink.cgColor
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
        if sheen, let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.white.withAlphaComponent(0.35).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gloss,
                start: CGPoint(x: rect.midX, y: rect.maxY),
                end: CGPoint(x: rect.midX, y: rect.midY),
                options: []
            )
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(max(1, rect.width * 0.008))
        ctx.strokePath()

        // Ring and dot, at the proportions the animated mark uses: a 66pt
        // ring with a 5pt stroke and a 26pt dot inside a 124pt tile.
        let ringDiameter = rect.width * 0.532
        let ringRect = CGRect(
            x: rect.midX - ringDiameter / 2,
            y: rect.midY - ringDiameter / 2,
            width: ringDiameter,
            height: ringDiameter
        )
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(rect.width * 0.040)
        ctx.strokeEllipse(in: ringRect.insetBy(dx: rect.width * 0.020, dy: rect.width * 0.020))

        let dotDiameter = rect.width * 0.21
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(
            x: rect.midX - dotDiameter / 2,
            y: rect.midY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        ))
        ctx.restoreGState()
    }

    // MARK: - Text helpers

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Lays out one centered line, shrinking the font until it fits rather
    /// than truncating: a meeting identifier is mostly identifier, and the
    /// end of it is the part that distinguishes one call from another. Past
    /// 70% of the asked-for size it gives up and truncates, since a line
    /// nobody can read is no better than a clipped one.
    private static func fitted(_ text: String, font: NSFont, color: NSColor, maxWidth: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        func string(_ font: NSFont) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ])
        }

        var candidate = string(font)
        let width = candidate.size().width
        guard width > maxWidth else { return candidate }
        let shrunk = max(font.pointSize * 0.7, font.pointSize * maxWidth / width)
        candidate = string(NSFont(descriptor: font.fontDescriptor, size: shrunk) ?? font)
        return candidate
    }

    /// Draws a measured line centered on `width`, returning the y the next
    /// line starts from - the top-down cursor the title cards use, so the
    /// two renderers read the same way.
    private static func drawCentered(_ string: NSAttributedString, at cursorY: CGFloat, width: CGFloat) -> CGFloat {
        let size = string.size()
        // A truncating paragraph style needs a rect no wider than the
        // space there is, or it never truncates; a measured line is
        // already no wider than that.
        string.draw(in: CGRect(x: (width - size.width) / 2, y: cursorY - size.height, width: size.width, height: size.height))
        return cursorY - size.height
    }

    private static func withShadow(blur: CGFloat, offsetY: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = CGSize(width: 0, height: offsetY)
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Encoding

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
