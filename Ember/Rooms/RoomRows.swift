import SwiftUI
import EmberSDK

/// A room or DM in a list: its row, as a link to the room, with star and
/// notification level on a swipe and a long press.
struct RoomRowLink: View {
    let room: SidebarRoom

    @Environment(Workspace.self) private var workspace

    var body: some View {
        NavigationLink(value: RoomLink(roomID: room.id)) {
            if room.room.isDirect {
                DirectRoomRow(room: room)
            } else {
                SharedRoomRow(room: room)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !room.room.isDirect {
                starButton
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            muteButton
        }
        .contextMenu {
            if !room.room.isDirect {
                Section { starButton }
            }
            Section { levelPicker }
        }
    }

    private var isFavorite: Bool { workspace.isFavorite(room.id) }

    /// Only shared rooms take a star, as on the web: a DM's place in the list
    /// is when it was last active.
    private var starButton: some View {
        let favorite = isFavorite
        return Button {
            Task { await workspace.setFavorite(!favorite, roomID: room.id) }
        } label: {
            Label(favorite ? "Unstar" : "Star", systemImage: favorite ? "star.slash" : "star")
        }
        // The system draws the label and glyph in white: 4.87:1 on this gold, where yellow gave 1.5:1.
        .tint(.starAction)
    }

    /// Off, or back to the level the room starts at. The other levels are a
    /// choice a swipe can't make, so they're on the long press.
    private var muteButton: some View {
        let quiet = room.involvement.isQuiet
        return Button {
            let level: Involvement = quiet ? .starting(for: room.room.kind) : .nothing
            Task { await workspace.setInvolvement(level, roomID: room.id) }
        } label: {
            Label(quiet ? "Unmute" : "Mute", systemImage: quiet ? "bell" : "bell.slash")
        }
        .tint(.indigo)
    }

    private var levelPicker: some View {
        Picker(selection: Binding(
            get: { room.involvement },
            set: { level in Task { await workspace.setInvolvement(level, roomID: room.id) } }
        )) {
            ForEach(Involvement.levels(for: room.room.kind), id: \.self) { level in
                Label(level.title, systemImage: level.symbol).tag(level)
            }
        } label: {
            Label("Notifications", systemImage: room.involvement.symbol)
        }
        .pickerStyle(.menu)
    }
}

/// A shared room: its symbol and name, bold with a dot when it's unread, and
/// a star when it's starred. Dimmed, with a crossed-out bell, when its notifications are off.
///
/// At the accessibility text sizes the name has the row's width to wrap in, with
/// the symbol at its start and the star and dot on a line beneath.
struct SharedRoomRow: View {
    let room: SidebarRoom

    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var leadingWidth: CGFloat = 32

    var body: some View {
        let unread = RoomList.isMarkedUnread(room, currentRoomID: workspace.currentRoomID)
        let name = workspace.name(of: room.room)
        let favorite = workspace.isFavorite(room.id)
        let muted = MutedMark.shows(for: room.involvement)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Text(Image(systemName: roomSymbol(for: room.room))).foregroundStyle(.secondary)) \(name)")
                        .font(.body.weight(unread ? .semibold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    if favorite || muted || unread {
                        HStack(spacing: 8) {
                            if favorite { star }
                            if muted { MutedMark() }
                            if unread { UnreadDot() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: roomSymbol(for: room.room))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: leadingWidth)
                    Text(name)
                        .font(.body.weight(unread ? .semibold : .regular))
                        .lineLimit(1)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                    if favorite { star }
                    if muted { MutedMark() }
                    if unread {
                        UnreadDot()
                    }
                }
            }
        }
        .foregroundStyle(muted ? .secondary : .primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Starred")
    }
}

/// A DM: the faces of the others in it, their names, a dot when it's
/// unread, when it was last active, and a crossed-out bell when it's muted.
///
/// At the accessibility text sizes the faces, the time and the dot share a line
/// above the names, which have the row's width to wrap in.
struct DirectRoomRow: View {
    let room: SidebarRoom

    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 32

    var body: some View {
        let unread = RoomList.isMarkedUnread(room, currentRoomID: workspace.currentRoomID)
        let members = RoomList.membersShown(room.room, me: workspace.me.id)
        let isAssistant = members.count == 1 && members.first.map { workspace.isAssistant($0.id) } == true
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        avatar(members)
                        Spacer(minLength: 0)
                        activity(unread: unread)
                    }
                    names(unread: unread, isAssistant: isAssistant)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    avatar(members)
                    names(unread: unread, isAssistant: isAssistant)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                    activity(unread: unread)
                }
            }
        }
        .foregroundStyle(MutedMark.shows(for: room.involvement) ? .secondary : .primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func avatar(_ members: [User]) -> some View {
        if members.count == 1, let person = members.first {
            AvatarView(userID: person.id, name: workspace.name(of: person), size: avatarSize)
        } else {
            GroupAvatarView(people: members, size: avatarSize)
        }
    }

    @ViewBuilder
    private func names(unread: Bool, isAssistant: Bool) -> some View {
        let name = workspace.name(of: room.room)
        if typeSize.isAccessibilitySize {
            Text(isAssistant ? "\(name) \(AssistantMark.inline)" : "\(name)")
                .font(.body.weight(unread ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 4) {
                Text(name)
                    .font(.body.weight(unread ? .semibold : .regular))
                    .lineLimit(1)
                if isAssistant {
                    AssistantMark()
                }
            }
        }
    }

    @ViewBuilder
    private func activity(unread: Bool) -> some View {
        if MutedMark.shows(for: room.involvement) {
            MutedMark()
        }
        if let activeAt = room.room.activeAt {
            RelativeTimeText(activeAt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if unread {
            UnreadDot()
        }
    }
}

/// Someone suggested for a DM, in a DM row's style. Tapping it opens the DM
/// with them, starting it if there isn't one.
struct SuggestionRow: View {
    let person: User
    let isStarting: Bool
    let start: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 32

    var body: some View {
        Button(action: start) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            avatar
                            Spacer(minLength: 0)
                            if isStarting {
                                ProgressView()
                            }
                        }
                        Text(workspace.isAssistant(person.id)
                            ? "\(workspace.name(of: person)) \(AssistantMark.inline)"
                            : "\(workspace.name(of: person))")
                            .fixedSize(horizontal: false, vertical: true)
                            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) {
                        avatar
                        HStack(spacing: 4) {
                            Text(workspace.name(of: person))
                                .lineLimit(1)
                            if workspace.isAssistant(person.id) {
                                AssistantMark()
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                        Spacer(minLength: 0)
                        if isStarting {
                            ProgressView()
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        AvatarView(userID: person.id, name: workspace.name(of: person), size: avatarSize)
    }
}

/// A plain list's section title, on the list's own background across the
/// list's full width: pinned at the top while its rows scroll under it, the
/// rows don't show through.
struct PinnedSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.systemBackground))
            .listRowInsets(EdgeInsets())
            .accessibilityAddTraits(.isHeader)
    }
}

/// The mark the assistant wears: the single sparkle.
struct AssistantMark: View {
    /// The mark as text, to wrap with a name.
    static var inline: Text {
        Text(Image(systemName: "sparkle"))
            .foregroundStyle(.secondary)
            .accessibilityLabel(Assistant.name)
    }

    var body: some View {
        Image(systemName: "sparkle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Assistant.name)
    }
}

/// A muted room's mark, where a starred room's star goes, so muting shows by more than the row's
/// dimming, and VoiceOver says it.
struct MutedMark: View {
    static let label = "Muted"

    /// Whether a room at `involvement` shows as muted: its notifications are off.
    static func shows(for involvement: Involvement) -> Bool { involvement.isQuiet }

    var body: some View {
        Image(systemName: "bell.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Self.label)
    }
}

struct UnreadDot: View {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: size, height: size)
            .accessibilityLabel("Unread")
    }
}
