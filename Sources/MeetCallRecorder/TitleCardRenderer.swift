import AppKit

/// Renders the plates shown at the start/end of a recording, over a pause,
/// and while the window is being resized - app icon, call identity, timing
/// info - as plain, transparent-background CGImages. RecordingAssembler
/// composites each one over a blurred, darkened freeze of the frame the
/// picture was on (or, for the welcome plate, the desktop wallpaper) and
/// owns all the fading; this type only draws the icon+text content.
/// All AppKit/text drawing happens here on the main actor, not down in the
/// ScreenCaptureKit sample-handling path.
@MainActor
enum TitleCardRenderer {
    // Date and time are formatted separately and joined with a plain space -
    // DateFormatter's own combined dateStyle+timeStyle output inserts a
    // locale-specific separator (usually ", ") between them, which reads
    // oddly on a single centered line.
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func renderIntro(appIcon: NSImage?, appName: String, callID: String, startDate: Date, outputSize: CGSize) -> CGImage? {
        let tz = TimeZone.current.abbreviation(for: startDate) ?? TimeZone.current.identifier
        let dateLine = "\(dateOnlyFormatter.string(from: startDate)) \(timeOnlyFormatter.string(from: startDate)) (\(tz))"
        return render(outputSize: outputSize, icon: appIcon, lines: [
            (appName, .title),
            (callID, .subtitle),
            (dateLine, .caption)
        ])
    }

    static func renderGap(pauseDuration: TimeInterval, outputSize: CGSize) -> CGImage? {
        render(outputSize: outputSize, icon: symbol("pause.circle", pointSize: 72), lines: [
            ("Recording paused", .title),
            (formatDuration(pauseDuration), .subtitle)
        ])
    }

    /// `meetingDuration` is the meeting's own span - start to last frame,
    /// pauses included - not how much of it has footage. See the caller.
    static func renderOutro(appIcon: NSImage?, appName: String, callID: String, meetingDuration: TimeInterval, outputSize: CGSize) -> CGImage? {
        render(outputSize: outputSize, icon: appIcon, lines: [
            (appName, .title),
            (callID, .subtitle),
            ("Meeting duration: \(formatDuration(meetingDuration))", .caption)
        ])
    }

    /// The plate held up while the captured window is being dragged to a
    /// new size.
    ///
    /// An ordinary centered card, like the others. It used to be a small
    /// badge floating at the middle of the window itself, over a blur
    /// masked to the window's own silhouette - which needed the window's
    /// alpha, and therefore needed the staged video to keep it. A plate
    /// drawn over the whole frozen frame needs none of that and reads the
    /// same.
    static func renderResize(outputSize: CGSize) -> CGImage? {
        render(outputSize: outputSize, icon: symbol("arrow.up.left.and.arrow.down.right", pointSize: 96), lines: [
            ("Resizing window", .title)
        ])
    }

    /// A system symbol tinted plain white - the same opaque treatment
    /// every other piece of card content gets. `render` draws it with
    /// `sourceOver`, so there's no stroke/shadow machinery to feed an
    /// alpha into even if there were one to use.
    private static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil).map { image in
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            return tinted(image.withSymbolConfiguration(config) ?? image, color: .white)
        }
    }

    /// Transparent margin baked around the identifier so its shadow has
    /// somewhere to fall. FrameComposer subtracts it when aligning the
    /// stamp, so the *text* sits where it's asked to, not the bitmap.
    nonisolated static let recordingIDPadding: CGFloat = 12

    // MARK: - The identifier's own treatment

    /// The identifier is the one piece of text stamped onto an otherwise
    /// untouched frame - the whole call, not a dimmed card backdrop - so
    /// it alone gets the translucent-with-outline treatment: faint enough
    /// not to draw the eye, with a dark stroke and soft shadow underneath
    /// so it stays legible whatever happens to be behind it, bright
    /// wallpaper included. Card text has no such problem - it already sits
    /// on a blurred, darkened backdrop every plate provides for it - so it
    /// stays plain opaque white with no stroke or shadow of its own.
    private static let recordingIDAlpha: CGFloat = 0.55

    private static func recordingIDAttributes(font: NSFont, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(recordingIDAlpha),
            .strokeColor: NSColor.black.withAlphaComponent(0.5),
            .strokeWidth: -3.0,
            .paragraphStyle: paragraph
        ]
    }

    /// The recording's identifier, as a small translucent stamp. Drawn
    /// tight to the text; FrameComposer places it in the corner.
    ///
    /// Monospaced on purpose: the identifier is there to be read off a
    /// frame and typed back in, and a proportional font makes that harder
    /// than it needs to be. Sized to sit inside the canvas's safe-area
    /// margin, which is all the room there is below the window content.
    static func renderRecordingID(_ identifier: String) -> CGImage? {
        let string = NSAttributedString(string: identifier, attributes: recordingIDAttributes(
            font: .monospacedSystemFont(ofSize: 17, weight: .medium),
            alignment: .right
        ))

        let textSize = string.size()
        let padding = recordingIDPadding
        let size = CGSize(width: ceil(textSize.width) + padding * 2, height: ceil(textSize.height) + padding * 2)
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = .zero
        shadow.set()
        string.draw(at: CGPoint(x: padding, y: padding))

        return ctx.makeImage()
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let result = NSImage(size: image.size)
        result.lockFocus()
        color.set()
        let rect = CGRect(origin: .zero, size: image.size)
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    private enum LineStyle { case title, subtitle, caption }

    /// Draws icon+text centered on an otherwise fully transparent canvas -
    /// no background fill, no dimming. FrameComposer is responsible for
    /// whatever sits behind this at composite time.
    ///
    /// Plain opaque white, no stroke, no shadow - unlike the identifier,
    /// this always lands on the blurred, darkened backdrop every plate
    /// provides for it, which is contrast enough on its own.
    private static func render(outputSize: CGSize, icon: NSImage?, lines: [(String, LineStyle)]) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        var cursorY = outputSize.height / 2 + 120

        if let icon {
            let iconSize: CGFloat = 128
            let iconRect = CGRect(x: (outputSize.width - iconSize) / 2, y: cursorY - iconSize, width: iconSize, height: iconSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            cursorY -= iconSize + 36
        }

        for (text, style) in lines {
            // Size, weight and opacity together carry the hierarchy
            // between the lines.
            let font: NSFont
            let color: NSColor
            switch style {
            case .title: font = .systemFont(ofSize: 44, weight: .semibold); color = .white
            case .subtitle: font = .systemFont(ofSize: 30, weight: .regular); color = NSColor.white.withAlphaComponent(0.85)
            case .caption: font = .systemFont(ofSize: 22, weight: .regular); color = NSColor.white.withAlphaComponent(0.7)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrString = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ])
            let lineSize = attrString.size()
            let rect = CGRect(x: (outputSize.width - lineSize.width) / 2, y: cursorY - lineSize.height, width: lineSize.width, height: lineSize.height)
            attrString.draw(in: rect)
            cursorY -= lineSize.height + 14
        }

        return ctx.makeImage()
    }
}
