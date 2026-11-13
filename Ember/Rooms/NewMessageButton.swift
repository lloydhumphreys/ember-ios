import SwiftUI

/// The New button: an orange circle floating over a tab's list, above the tab bar. It starts a new
/// message, or for someone who can make rooms, offers New Message and New Room.
struct NewMessageButton: View {
    static let diameter: CGFloat = 56
    var newRoom: (() -> Void)?
    var action: () -> Void

    var body: some View {
        if let newRoom {
            Menu {
                Button(action: action) {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                Button(action: newRoom) {
                    Label("New Room", systemImage: "number")
                }
            } label: {
                circle
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("New")
            .accessibilityShowsLargeContentViewer { Label("New", systemImage: "plus") }
        } else {
            Button(action: action) {
                circle
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Message")
            // At the accessibility text sizes a long press shows it enlarged, as a tab bar item does.
            .accessibilityShowsLargeContentViewer { Label("New Message", systemImage: "plus") }
        }
    }

    private var circle: some View {
        Image(systemName: "plus")
            // A fixed size, so the glyph stays inside the circle at every text size.
            .font(.system(size: 18, weight: .medium))
            .imageScale(.large)
            .foregroundStyle(.white)
            .frame(width: Self.diameter, height: Self.diameter)
            .floatingFill(.newMessage)
            .contentShape(.circle)
    }
}
