import AppKit
import CoreImage
import CoreMedia
import CoreVideo

/// Composites each captured window frame onto a fixed-size canvas: the
/// system desktop wallpaper as background, the window scaled (preserving
/// aspect ratio) to fit within a centered safe area, never touching the
/// `safeInset`-pixel margin. Output is always `outputSize` regardless of
/// the window's actual size - that's the point (fixed 1920x1080/30fps
/// stream even though call windows get resized/moved).
final class FrameComposer {
    private let outputSize: CGSize
    private let safeInset: CGFloat
    private let ciContext = CIContext()
    private let backgroundImage: CIImage
    private var pixelBufferPool: CVPixelBufferPool?

    init(outputSize: CGSize, safeInset: CGFloat) {
        self.outputSize = outputSize
        self.safeInset = safeInset
        self.backgroundImage = Self.loadDesktopWallpaper(fitting: outputSize)
            ?? CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
        self.pixelBufferPool = Self.makePixelBufferPool(size: outputSize)
    }

    private static func loadDesktopWallpaper(fitting size: CGSize) -> CIImage? {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = CIImage(contentsOf: url) else {
            return nil
        }
        // Cover-fit: scale up to fill `size` entirely, then crop any excess.
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2 - scaled.extent.minX
        let dy = (scaled.extent.height - size.height) / 2 - scaled.extent.minY
        return scaled
            .transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))
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

    /// Returns a new sample buffer at `outputSize`, with the window content
    /// from `source` scaled/centered into the safe area over the wallpaper.
    /// Reuses `source`'s timing info so A/V sync and frame pacing survive
    /// unchanged.
    func compose(_ source: CMSampleBuffer) -> CMSampleBuffer? {
        guard let pool = pixelBufferPool, let inputPixelBuffer = CMSampleBufferGetImageBuffer(source) else { return nil }

        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBuffer)
        guard let outputPixelBuffer else { return nil }

        let windowImage = CIImage(cvPixelBuffer: inputPixelBuffer)
        let availableWidth = outputSize.width - safeInset * 2
        let availableHeight = outputSize.height - safeInset * 2
        let scale = min(availableWidth / windowImage.extent.width, availableHeight / windowImage.extent.height)
        let scaledWindow = windowImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let dx = (outputSize.width - scaledWindow.extent.width) / 2 - scaledWindow.extent.minX
        let dy = (outputSize.height - scaledWindow.extent.height) / 2 - scaledWindow.extent.minY
        let positionedWindow = scaledWindow.transformed(by: CGAffineTransform(translationX: dx, y: dy))

        let composed = positionedWindow.composited(over: backgroundImage)
        ciContext.render(composed, to: outputPixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: outputPixelBuffer, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timingInfo)

        var result: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: outputPixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &result
        )
        return result
    }
}
