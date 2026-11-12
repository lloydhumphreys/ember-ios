import SwiftUI

/// The New Message button: an orange circle floating over a tab's list, above the tab bar.
struct NewMessageButton: View {
    static let diameter: CGFloat = 56
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                // A fixed size, so the glyph stays inside the circle at every text size.
                .font(.system(size: 18, weight: .medium))
                .imageScale(.large)
                .foregroundStyle(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .floatingFill(.newMessage)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Message")
        // At the accessibility text sizes a long press shows it enlarged, as a tab bar item does.
        .accessibilityShowsLargeContentViewer { Label("New Message", systemImage: "plus") }
    }
}
