import AppKit
import SwiftUI

/// One of the sample meetings the background preview is drawn for.
///
/// Four meetings, four identifiers, two per app: a pair of Meet codes and
/// a pair of Slack huddle titles. The pairing by app is what rules out
/// the obvious misreading - two Meet cards sitting next to each other
/// with different backdrops say plainly that the picture follows the
/// meeting, not the application it came from.
struct BackgroundPreviewSample: Identifiable, Sendable {
    let source: CallSource
    /// The call identifier in the shape `WindowDetector` pulls off a real
    /// window title: the quoted meeting code for Meet, the whole title
    /// for Slack - including the two shapes a huddle title comes in, a
    /// channel and a direct message.
    let callID: String
    /// The part of that identifier a person would recognise the meeting
    /// by, which is all the card has room to print.
    let label: String

    var id: String { seed }

    /// Composed exactly as `AppDelegate.backgroundSeed` does, so a card
    /// shows the image the real call would actually be given rather than
    /// an approximation of it.
    var seed: String { "\(source.ownerName)|\(callID)" }

    /// The Meet codes are real-shaped - three, four, three - but read as
    /// words rather than the noise a generated one is. A sample anybody
    /// can see is a sample is worth more here than a convincing one: it
    /// can't be mistaken for a meeting of your own that the app somehow
    /// knows about.
    static let all: [BackgroundPreviewSample] = [
        BackgroundPreviewSample(source: .googleMeet, callID: "fox-trot-ter", label: "fox-trot-ter"),
        BackgroundPreviewSample(source: .googleMeet, callID: "bee-keep-ers", label: "bee-keep-ers"),
        BackgroundPreviewSample(source: .slack, callID: "Huddle in #design", label: "#design"),
        BackgroundPreviewSample(source: .slack, callID: "Huddle with Jonas", label: "Jonas")
    ]

    /// Which bundled wallpaper stands in for this card, per mode, so the
    /// preview can show the photo modes without downloading four
    /// wallpapers every time the tab is opened. nil for the modes the app
    /// can resolve locally and instantly - those are drawn for real.
    ///
    /// Both photo modes get four distinct pictures, from two disjoint
    /// sets: what separates them isn't how varied one deck looks, it's
    /// that one deck is reproducible and the other isn't, which the
    /// caption under the deck has to carry either way.
    static func sample(for mode: BackgroundMode, at index: Int) -> SampleBackground? {
        let perCard: [SampleBackground]
        switch mode {
        case .seededPhoto:
            perCard = [.vilnius, .workshop, .wheat, .busStop]
        case .randomPhoto:
            perCard = [.locomotive, .dusk, .street, .seafront]
        case .desktop, .seededGradient, .randomGradient:
            return nil
        }
        return perCard.indices.contains(index) ? perCard[index] : perCard.last
    }
}

/// The four sample backdrops, dealt out as an overlapping cascade.
///
/// One preview can only ever show a backdrop; four cut into each other
/// show the thing that actually distinguishes the modes - whether the
/// picture follows the meeting, changes every call, or never changes at
/// all. Hovering lifts a card clear of the two on top of it, which is the
/// only way to see a covered one whole.
///
/// Card geometry is fixed rather than proportional: the settings window is
/// a fixed width, and the cascade only works if the visible sliver of a
/// covered card stays wide enough to hold its label.
struct BackgroundPreviewDeck: View {
    /// Where one card's image has got to. Parallel array rather than a
    /// dictionary so the deck can't be drawn in a different order than
    /// the samples were resolved in.
    enum Slot {
        case loading
        /// `nil` where the mode legitimately has nothing to show - the
        /// desktop mode on a Mac with no desktop picture set, which the
        /// composer renders as plain black.
        case resolved(CGImage?)
    }

    let slots: [Slot]
    let icons: AppIcons

    private static let samples = BackgroundPreviewSample.all
    private static let cardWidth: CGFloat = 256
    /// 16:9, the same shape as every output canvas.
    private static let cardHeight: CGFloat = 144
    /// How far right of the card it covers each one sits...
    private static let step: CGFloat = 104
    /// ...and how far down, which is what makes this read as a dealt deck
    /// rather than a filmstrip.
    private static let drop: CGFloat = 15
    private static let corner: CGFloat = 10
    /// Also the chip's height - the icon is its leading cap.
    private static let chipIcon: CGFloat = 20

    @State private var hovered: BackgroundPreviewSample.ID?

    static var width: CGFloat { cardWidth + step * CGFloat(samples.count - 1) }
    static var height: CGFloat { cardHeight + drop * CGFloat(samples.count - 1) }

    /// Laid out as a row with negative spacing, *not* as a `ZStack` of
    /// offset cards.
    ///
    /// The offset version drew correctly and was unusable: `.offset` is a
    /// rendering transform, and `onHover`'s tracking area is built from
    /// layout geometry, which the transform never touches. Every card
    /// kept the layout frame of the first one, so four identical,
    /// completely overlapping tracking areas sat under a cascade that
    /// looked spread out - hovering any card lit up whichever of them
    /// answered first. Negative spacing moves the cards in layout
    /// instead, so each one's tracking area is the rectangle you can see.
    ///
    /// The lift stays a transform on purpose: the tracking area staying
    /// put while the card rises is what stops a card that lifts out from
    /// under the pointer from immediately un-hovering itself.
    var body: some View {
        HStack(alignment: .top, spacing: Self.step - Self.cardWidth) {
            ForEach(Array(Self.samples.enumerated()), id: \.element.id) { index, sample in
                card(sample, slot: slot(at: index))
                    // Outside the card, and only ever these two: the
                    // padding is what deals the card downwards in layout,
                    // and nothing between here and `onHover` is allowed
                    // to resize the rectangle being tracked.
                    .padding(.top, CGFloat(index) * Self.drop)
                    // A lifted card has to clear the ones dealt after it,
                    // which are drawn over it by default.
                    .zIndex(hovered == sample.id ? Double(Self.samples.count) : Double(index))
            }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
    }

    private func slot(at index: Int) -> Slot {
        index < slots.count ? slots[index] : .loading
    }

    private func card(_ sample: BackgroundPreviewSample, slot: Slot) -> some View {
        let isHovered = hovered == sample.id
        return ZStack {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(.black.opacity(0.25))

            if case .resolved(let image?) = slot {
                // Fill, not fit: the card is the canvas shape, so filling
                // it shows the backdrop at the proportions a recording
                // will actually use.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }

            switch slot {
            case .loading:
                ProgressView().controlSize(.small)
            case .resolved(nil):
                Text("Nothing set")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .resolved:
                EmptyView()
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(alignment: .topLeading) { chip(sample) }
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.5 : 0.18), lineWidth: 1)
        }
        // The light stroke alone doesn't separate two photographic cards;
        // the shadow under each one is what makes the overlap legible.
        .shadow(color: .black.opacity(0.32), radius: isHovered ? 15 : 7, x: -2, y: 3)
        .scaleEffect(isHovered ? 1.03 : 1)
        .offset(y: isHovered ? -10 : 0)
        // Explicit, so the hit area is the whole card including the parts
        // of it a photo leaves dark, not just what happens to be opaque.
        .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // Attached here, to the card's own rectangle, rather than outside
        // the padding that offsets it in the row - the tracked area is
        // then the card and nothing but the card.
        .onHover { inside in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                if inside {
                    hovered = sample.id
                } else if hovered == sample.id {
                    hovered = nil
                }
            }
        }
    }

    /// Which meeting this card is. Sits top-left, inside the strip of a
    /// covered card that the next card never reaches - and runs under it
    /// when the label is long, so hovering reveals the rest.
    private func chip(_ sample: BackgroundPreviewSample) -> some View {
        HStack(spacing: 5) {
            // The app icon *is* the leading end of the chip, not
            // something sitting on it.
            //
            // A macOS app icon is a glyph on its own rounded plate, and
            // inset into a second rounded background that plate reads as
            // a grey block stuck around the logo. Clipping it to a circle
            // the height of the capsule, flush against the end with no
            // padding in front, makes the two backgrounds into one shape.
            // The scale is there because the bitmap carries transparent
            // margin around the plate - at 1.0 the circle clips nothing
            // and the square comes back.
            iconView(sample.source)
                .frame(width: Self.chipIcon, height: Self.chipIcon)
                .scaleEffect(1.24)
                .clipShape(Circle())

            Text(sample.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.trailing, 8)
        }
        .fixedSize()
        // A flat dark capsule rather than a material: this sits over an
        // arbitrary photo, and only a fixed scrim keeps white content on
        // it readable whatever the picture turns out to be.
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
    }

    @ViewBuilder
    private func iconView(_ source: CallSource) -> some View {
        if let icon = icons.icon(for: source) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFill()
        } else {
            // Nothing to clip and no plate to hide: the symbol just sits
            // on the scrim like the label does.
            Image(systemName: source.fallbackSymbol)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .frame(width: Self.chipIcon, height: Self.chipIcon)
        }
    }

}
