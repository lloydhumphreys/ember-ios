import SwiftUI
import EmberSDK

/// A message's boosts, one chip each as the web shows them: the booster's face and what they
/// boosted with. Your own chip takes the boost back; the last control adds one.
struct BoostsView: View {
    let message: Message
    let me: User?
    let session: RoomSession
    let customBoost: (Message) -> Void

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 18

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(message.boosts) { boost in
                chip(boost)
            }
            BoostMenu(message: message, session: session, customBoost: customBoost) {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: faceSize + 10)
                    .background(Capsule().strokeBorder(.separator))
                    .contentShape(Capsule())
            }
            .accessibilityLabel("Add Boost")
        }
    }

    @ViewBuilder private func chip(_ boost: Boost) -> some View {
        let name = workspace.name(of: boost.booster)
        let face = HStack(spacing: 4) {
            AvatarView(userID: boost.booster.id, name: name, size: faceSize)
            Text(boost.content)
                .font(.footnote)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isMine(boost) ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
        .background(Capsule().strokeBorder(isMine(boost) ? Color.accentColor.opacity(0.5) : Color.clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) boosted \(boost.content)")

        if isMine(boost) {
            Menu {
                Button("Remove Boost", systemImage: "minus.circle", role: .destructive) {
                    session.removeBoost(boost.id)
                }
            } label: {
                face
            }
            .buttonStyle(.plain)
        } else {
            face
        }
    }

    private func isMine(_ boost: Boost) -> Bool {
        boost.booster.id == (me?.id ?? workspace.me.id)
    }
}

/// The reactions to boost with, and Other… for anything else up to the boost limit.
struct BoostMenu<Label: View>: View {
    let message: Message
    let session: RoomSession
    let customBoost: (Message) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            BoostChoices(message: message, session: session, customBoost: customBoost)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

/// The boost choices, shared by the chip row's add control and the message's context menu.
struct BoostChoices: View {
    let message: Message
    let session: RoomSession
    let customBoost: (Message) -> Void

    /// The reactions in rows of the same kind, as many to a row as a compact menu group holds.
    private static let perRow = 4

    var body: some View {
        ForEach(Array(stride(from: 0, to: Reactions.all.count, by: Self.perRow)), id: \.self) { start in
            ControlGroup {
                ForEach(Reactions.all[start..<min(start + Self.perRow, Reactions.all.count)], id: \.self) { reaction in
                    Button(reaction) { session.boost(message.id, content: reaction) }
                }
            }
            .controlGroupStyle(.compactMenu)
        }
        Button("Other…", systemImage: "character.cursor.ibeam") { customBoost(message) }
    }
}
