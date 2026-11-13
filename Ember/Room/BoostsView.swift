import SwiftUI
import EmberSDK

/// Boosts of one kind on a message: what was boosted, who boosted it in the order they did, and
/// your own boost of it, if you made one.
struct BoostGroup: Identifiable, Equatable {
    let content: String
    var boosters: [User]
    /// Yours, which its chip takes back.
    var mine: Boost?

    var id: String { content }
    var count: Int { boosters.count }
    var isMine: Bool { mine != nil }

    /// One group for each thing boosted, in the order each was first boosted.
    static func of(_ boosts: [Boost], myID: UserID) -> [BoostGroup] {
        var groups: [BoostGroup] = []
        var index: [String: Int] = [:]
        for boost in boosts {
            let at: Int
            if let known = index[boost.content] {
                at = known
            } else {
                at = groups.count
                index[boost.content] = at
                groups.append(BoostGroup(content: boost.content, boosters: []))
            }
            groups[at].boosters.append(boost.booster)
            if boost.booster.id == myID, groups[at].mine == nil { groups[at].mine = boost }
        }
        return groups
    }

    /// What VoiceOver says for it: what was boosted, how many times, and whether you did.
    var spoken: String {
        let whose = isMine ? (count == 1 ? ", yours" : ", including yours") : ""
        return "\(content) \(count)\(whose)"
    }
}

/// A message's boosts, one chip for each thing boosted with how many boosted it, as Slack groups
/// reactions. Yours are marked, and your chip takes your boost back; every chip lists who boosted.
/// The last control adds one.
struct BoostsView: View {
    let message: Message
    let me: User?
    let session: RoomSession
    let customBoost: (Message) -> Void
    /// Whether the screen shows the boost with this id gone, so a removal that failed to answer
    /// made it.
    var showsRemoved: (BoostID) -> Bool = { _ in false }

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .footnote) private var chipHeight: CGFloat = 28

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(BoostGroup.of(message.boosts, myID: me?.id ?? workspace.me.id)) { group in
                chip(group)
            }
            BoostMenu(message: message, session: session, customBoost: customBoost) {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: chipHeight)
                    .background(Capsule().strokeBorder(.separator))
                    .contentShape(Capsule())
            }
            .accessibilityLabel("Add Reaction")
        }
    }

    private func chip(_ group: BoostGroup) -> some View {
        Menu {
            Section {
                ForEach(Array(group.boosters.enumerated()), id: \.offset) { _, booster in
                    Text(workspace.name(of: booster))
                }
            }
            if let mine = group.mine {
                let key = SentChanges.Key.removeBoost(message.id, mine.id)
                Button("Remove Reaction", systemImage: "minus.circle", role: .destructive) {
                    let session = session, showsRemoved = showsRemoved
                    SentChanges.shared.start(key, isDone: { showsRemoved(mine.id) }) {
                        try await session.removeBoost(id: mine.id)
                    }
                }
                .disabled(SentChanges.shared.isSending(key))
            }
        } label: {
            HStack(spacing: 4) {
                Text(group.content)
                    .lineLimit(1)
                Text(group.count, format: .number)
                    .monospacedDigit()
                    .fontWeight(group.isMine ? .semibold : .regular)
                    .foregroundStyle(group.isMine ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .font(.footnote)
            .padding(.horizontal, 10)
            .frame(minHeight: chipHeight)
            .background(Capsule().fill(group.isMine ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
            .background(Capsule().strokeBorder(group.isMine ? Color.accentColor.opacity(0.5) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.spoken)
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
    static let perRow = 4

    /// The reactions a hold on a message offers before anything else: the commonest, one row of them.
    static let quick = ["👍", "❤️", "😂", "🎉"]

    var body: some View {
        ForEach(Array(stride(from: 0, to: Reactions.all.count, by: Self.perRow)), id: \.self) { start in
            ReactionRow(reactions: Array(Reactions.all[start..<min(start + Self.perRow, Reactions.all.count)]), message: message, session: session)
        }
        Button("Other…", systemImage: "character.cursor.ibeam") { customBoost(message) }
    }

    /// Boosts `message` through the room's `async` call, which says whether the room made it.
    static func boost(_ message: Message, with content: String, in session: RoomSession) {
        let id = message.id
        SentChanges.shared.start(.boost(id, content)) { try await session.boost(message: id, content: content) }
    }
}

/// Reactions side by side in a menu, each a tap to react with.
struct ReactionRow: View {
    let reactions: [String]
    let message: Message
    let session: RoomSession

    var body: some View {
        ControlGroup {
            ForEach(reactions, id: \.self) { reaction in
                Button(reaction) { BoostChoices.boost(message, with: reaction, in: session) }
                    .disabled(SentChanges.shared.isSending(.boost(message.id, reaction)))
            }
        }
        .controlGroupStyle(.compactMenu)
    }
}
