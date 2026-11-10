import SwiftUI

/// Three dots in an incoming bubble, for while someone's writing. Drawn where their message will
/// appear, the same shape, so the words simply replace the dots when they land.
struct TypingBubble: View {
    init() {}

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Dot(delay: Double(index) * 0.2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typing")
    }
}

/// One dot, breathing on a loop a fifth of a second behind the one before it.
private struct Dot: View {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUp = false

    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 7, height: 7)
            .opacity(isUp ? 1 : 0.35)
            .scaleEffect(isUp ? 1 : 0.8)
            // An animation rather than a timer, so it stops with the view. Reduce Motion leaves
            // the dots lit and still.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever().delay(delay), value: isUp)
            .onAppear { isUp = true }
    }
}
