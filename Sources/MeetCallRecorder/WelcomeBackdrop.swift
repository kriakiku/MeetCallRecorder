import SwiftUI

/// The tinted base the welcome screen is built on: window colour with the
/// icon mark's gradient bled in behind the top of the content.
///
/// Deliberately built from system colours plus opacity so it reads
/// correctly in both light and dark mode without a second palette. Shared
/// with the background preview in settings, which wants the same bloom
/// behind its cards - that screen is a showcase rather than a form, and
/// the welcome screen is where this app's showcase look lives.
struct WelcomeBackdrop: View {
    /// How far down the tint reaches. The welcome window gives it a whole
    /// hero; the settings preview only wants it behind the deck.
    var bleed: CGFloat = 420

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay(alignment: .top) {
                EllipticalGradient(
                    colors: [
                        Color(red: 0.42, green: 0.33, blue: 0.98).opacity(0.22),
                        Color(red: 0.93, green: 0.27, blue: 0.47).opacity(0.10),
                        .clear
                    ],
                    center: .top,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.75
                )
                .frame(height: bleed)
            }
    }
}
