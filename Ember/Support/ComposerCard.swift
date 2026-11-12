import SwiftUI
import UIKit

/// The card a composer sits in: Liquid Glass floating over the timeline, which scrolls on
/// underneath it, frosted a shade past the system's so what passes under it blurs rather than
/// reads through.
struct ComposerCard<Content: View>: View {
    /// How far in from the screen's edges the card sits.
    var margin: CGFloat
    private let content: Content

    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    /// With Increase Contrast the card's edge is drawn as a separator is, in both appearances: the
    /// glass's own rim, and the faint light-mode edge, are too slight to find it by. (With Reduce
    /// Transparency the system's glass and material are already opaque, so nothing changes for it.)
    @Environment(\.colorSchemeContrast) private var contrast

    init(margin: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.margin = margin
        self.content = content()
    }

    var body: some View {
        content
            .background(Color.composerFrost)
            .containerShape(shape)
            .clipShape(shape)
            .glassBackground(in: shape)
            .overlay(shape.strokeBorder(
                contrast == .increased ? Color(.separator) : Color.composerEdge,
                lineWidth: contrast == .increased ? 1 : 0.5))
            .padding(.horizontal, margin)
            .padding(.bottom, 8)
    }
}

/// The send button's face: an outline while there's nothing to send, filling in solid in the
/// system tint once there is, so a glance says whether a tap would go.
struct SendGlyph: View {
    var isEnabled: Bool
    var isBusy: Bool

    init(isEnabled: Bool, isBusy: Bool = false) {
        self.isEnabled = isEnabled
        self.isBusy = isBusy
    }

    var body: some View {
        ZStack {
            // Laid out even while spinning, so the row doesn't twitch narrower during a send.
            Image(systemName: isEnabled ? "arrow.up.circle.fill" : "arrow.up.circle")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary.opacity(0.35)),
                    // The fill white reads on, not the accent text is drawn in, which is lighter in dark mode.
                    isEnabled ? AnyShapeStyle(Color.accentFill) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .contentTransition(.symbolEffect(.replace))
                .animation(.snappy, value: isEnabled)
                .opacity(isBusy ? 0 : 1)
            if isBusy { ProgressView().controlSize(.small) }
        }
        // A 44pt target around the glyph, pulled back into the card's padding so the field isn't
        // made taller to hold it.
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .padding(-8)
    }
}

extension Color {
    /// Laid over the composer's glass: the system's glass, a shade frostier.
    static let composerFrost = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.22)
            : UIColor.white.withAlphaComponent(0.4)
    })
}

extension Color {
    /// Round the composer's glass in light mode, where over light messages the glass alone has no
    /// edge to see. The dark glass has one of its own.
    static let composerEdge = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.clear
            : UIColor.black.withAlphaComponent(0.12)
    })
}
