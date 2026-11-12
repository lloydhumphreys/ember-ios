import SwiftUI

// iOS 26 API with the nearest iOS 18 equivalent. On iOS 26 each helper is exactly the call it
// replaces.

extension View {
    /// Liquid Glass on iOS 26, answering touches when `interactive`; the regular material, in the
    /// same shape, before it.
    @ViewBuilder
    func glassBackground(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// `.glassProminent` on iOS 26; `.borderedProminent` before it. Filled with `accentFill`, which
    /// white labels read on.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(.accentFill)
        } else {
            buttonStyle(.borderedProminent).tint(.accentFill)
        }
    }

    /// Room under the list's last row for the New Message button floating over it, so the row
    /// scrolls clear of the button.
    func clearsFloatingNewMessage() -> some View {
        contentMargins(.bottom, NewMessageButton.diameter + 24, for: .scrollContent)
    }

    /// The tab bar shrinks while a list scrolls down on iOS 26. Earlier tab bars don't shrink.
    @ViewBuilder
    func minimizesTabBarOnScrollDown() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// A bar along the bottom that content scrolls under: `safeAreaBar` on iOS 26, which adds the
    /// scroll edge effect behind it; `safeAreaInset` before it, over a fade to the screen's
    /// background, so what scrolls under the bar doesn't show through it or below it.
    @ViewBuilder
    func bottomBar(spacing: CGFloat? = nil, @ViewBuilder content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: spacing) {
                content()
                    .background {
                        LinearGradient(
                            stops: [
                                .init(color: Color(.systemBackground).opacity(0), location: 0),
                                .init(color: Color(.systemBackground), location: 0.45),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        // To the screen's foot, not under the keyboard, which would stretch
                        // the fade down behind it and leave the bar see-through.
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                    }
            }
        }
    }

    /// The room title's capsule: Liquid Glass on iOS 26, as `glassBackground` gives; before it a
    /// light fill, which the regular material is too faint to stand in for on a clear bar.
    @ViewBuilder
    func titleBackground(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassBackground(in: shape, interactive: true)
        } else {
            background(Color(.secondarySystemFill), in: shape)
        }
    }

    /// Before iOS 26 a long-press preview is drawn from the view alone, so a row with no
    /// background of its own lifts see-through; this gives it the screen's. iOS 26 is unchanged.
    @ViewBuilder
    func opaqueContextMenuPreview() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            background(Color(.systemBackground))
        }
    }

    /// A floating button's circle: Liquid Glass tinted with `color` on iOS 26, answering touches;
    /// filled with it, over a shadow, before.
    @ViewBuilder
    func floatingFill(_ color: Color) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(color.opacity(0.8)).interactive(), in: .circle)
        } else {
            background(color, in: .circle).shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
    }

    /// A tap that lands on none of the view's controls, such as between the composer's field and
    /// its buttons, where the field is only as tall as its text, runs `action`. Behind the
    /// content, so the controls still take their own taps.
    func focusesOnTap(_ action: @escaping () -> Void) -> some View {
        background { Color.clear.contentShape(.rect).onTapGesture(perform: action) }
    }
}

extension Color {
    /// The New Message button's orange: the accent colour, brighter in dark mode, where the dark
    /// screen behind dulls it to brown.
    static let newMessage = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.33, blue: 0, alpha: 1)
            : UIColor(named: "AccentColor") ?? .systemOrange
    })
}

/// A toolbar's cancel button: the system's own glyph on iOS 26, its "Cancel" title before it.
struct CancelButton: View {
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .cancel, action: action)
        } else {
            Button("Cancel", role: .cancel, action: action)
        }
    }
}

/// A toolbar's confirming button: role `.confirm` on iOS 26. Before it the confirmation
/// placement alone gives the emphasis.
struct ConfirmButton: View {
    var title: LocalizedStringKey
    var action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(title, role: .confirm, action: action)
        } else {
            Button(title, action: action)
        }
    }
}
