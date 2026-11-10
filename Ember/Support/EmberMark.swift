import SwiftUI

/// Ember's flame, as the web client's sign-in card shows it: 48 points square, over the title.
struct EmberMark: View {
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 48

    var body: some View {
        Image("EmberMark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Ember")
    }
}
