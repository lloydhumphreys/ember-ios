import SwiftUI

/// How a banned person's avatar shows, as the web shows it: dimmed, under a red prohibition mark.
/// The mark is hidden from VoiceOver, so whatever shows the avatar says they're banned.
private struct BannedMark: ViewModifier {
    let isBanned: Bool
    /// The avatar's size, which the mark's is a share of.
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isBanned ? 0.5 : 1)
            .overlay {
                if isBanned {
                    Image(systemName: "nosign")
                        .font(.system(size: size * 0.6))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Dims this avatar of `size` under a red prohibition mark when its person `isBanned`.
    func bannedMark(_ isBanned: Bool, size: CGFloat) -> some View {
        modifier(BannedMark(isBanned: isBanned, size: size))
    }
}
