import SwiftUI

/// The app mark shown on the welcome screen's first page.
///
/// Drawn rather than loaded from an asset: the app has no icon designed
/// yet, and a shape-based stand-in both animates properly (the glow pulses
/// behind it, the ring sweeps) and is a single file to delete once a real
/// icon lands. Swap the body for `Image(nsImage: NSApp.applicationIconImage)`
/// at that point and the surrounding animation keeps working.
struct WelcomeIconMark: View {
    /// Drives the entrance: the mark rises out of a blur while the glow
    /// behind it opens up.
    var isVisible: Bool

    @State private var pulse = false
    @State private var sweep = false

    private static let gradient = LinearGradient(
        colors: [
            Color(red: 0.42, green: 0.33, blue: 0.98),
            Color(red: 0.93, green: 0.27, blue: 0.47)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            // Two breathing halos, offset in phase, doing the work a drop
            // shadow can't: suggesting the recording light is live.
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(Self.gradient)
                    .frame(width: 148, height: 148)
                    .blur(radius: 34)
                    .opacity(isVisible ? (pulse ? 0.30 : 0.14) : 0)
                    .scaleEffect(pulse ? 1.18 : 0.92)
                    .animation(
                        .easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(Double(index) * 1.3),
                        value: pulse
                    )
            }

            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Self.gradient)
                .frame(width: 124, height: 124)
                .overlay {
                    // A glass sheen across the top half, the way a real
                    // macOS icon catches light.
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                }
                .overlay { recordGlyph }
                .shadow(color: Color(red: 0.42, green: 0.33, blue: 0.98).opacity(0.45), radius: 24, y: 12)
        }
        .frame(width: 180, height: 180)
        .scaleEffect(isVisible ? 1 : 0.55)
        .opacity(isVisible ? 1 : 0)
        .blur(radius: isVisible ? 0 : 14)
        .onAppear {
            pulse = true
            sweep = true
        }
    }

    /// Ring, dot, and a brighter arc that keeps going round it - the arc
    /// is the only part that animates after the entrance settles, which is
    /// enough to keep the screen from looking frozen.
    private var recordGlyph: some View {
        ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 5)
                .frame(width: 66, height: 66)

            Circle()
                .trim(from: 0, to: 0.22)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 66, height: 66)
                .rotationEffect(.degrees(sweep ? 360 : 0))
                .animation(.linear(duration: 3.4).repeatForever(autoreverses: false), value: sweep)

            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
        }
    }
}
