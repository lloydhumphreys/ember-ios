import SwiftUI
import EmberSDK

extension Color {
    /// The fill under white labels and glyphs (prominent buttons, Send): the accent as it was before
    /// the dark accent was lightened for text, and darker again with Increase Contrast, so white on
    /// it stays legible. Text in the accent colour uses the accent itself.
    static let accentFill = Color("AccentFill")

    /// The Star swipe action's fill: a deep gold the system's white glyph and label read on.
    static let starAction = Color("StarAction")
}

/// WCAG 2 contrast, for checking colours drawn under white.
enum Contrast {
    /// Relative luminance of an sRGB colour, each component from 0 to 1.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio between two luminances, from 1 to 21.
    static func ratio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The ratio of white on an sRGB colour.
    static func ofWhite(on colour: (red: Double, green: Double, blue: Double)) -> Double {
        ratio(1, luminance(red: colour.red, green: colour.green, blue: colour.blue))
    }

    /// `colour`, darkened only as far as white initials on it need to reach `minimum`, keeping its
    /// hue: the web's avatar colours, a few of which are too light for white.
    static func darkenedForWhite(
        _ colour: (red: Double, green: Double, blue: Double), minimum: Double = 3
    ) -> (red: Double, green: Double, blue: Double) {
        let current = luminance(red: colour.red, green: colour.green, blue: colour.blue)
        let target = 1.05 / minimum - 0.05
        guard current > target else { return colour }
        // Scaling the linear components scales the luminance by the same amount.
        let scale = target / current * 0.995
        return (encode(linear(colour.red) * scale), encode(linear(colour.green) * scale), encode(linear(colour.blue) * scale))
    }

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

/// The colour behind someone's white initials: the web's colour for them, darkened where white
/// on it would fall under 3:1 (three of its eighteen), and grey for no one.
enum AvatarColour {
    static func behindWhite(userID: UserID?) -> (red: Double, green: Double, blue: Double) {
        guard let userID else { return (0.55, 0.55, 0.58) }
        return Contrast.darkenedForWhite(AvatarStyle.colour(for: userID))
    }
}

/// What VoiceOver says of a count of unread rooms, as an element's value.
enum UnreadValue {
    /// "2 unread"; nil at zero, when there's nothing to say. "Unread" reads the same for one or many.
    static func text(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count.formatted()) unread"
    }
}

extension View {
    /// Says `message` to VoiceOver when it appears or changes to another message: an error shown
    /// where focus doesn't go. Once for each time it appears, not each time the view is drawn.
    func announcesWhenShown(_ message: String?) -> some View {
        onChange(of: message) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }
}
