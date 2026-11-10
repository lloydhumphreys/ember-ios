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
        .tint(.yellow)
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
/// a star when it's starred. Muted when its notifications are off.
struct SharedRoomRow: View {
    let room: SidebarRoom

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .body) private var leadingWidth: CGFloat = 32

    var body: some View {
        let unread = RoomList.isMarkedUnread(room, currentRoomID: workspace.currentRoomID)
        HStack(spacing: 12) {
            Image(systemName: roomSymbol(for: room.room))
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: leadingWidth)
            Text(workspace.name(of: room.room))
                .font(.body.weight(unread ? .semibold : .regular))
                .lineLimit(1)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if workspace.isFavorite(room.id) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Starred")
            }
            if unread {
                UnreadDot()
            }
        }
        .foregroundStyle(room.involvement.isQuiet ? .secondary : .primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A DM: the faces of the others in it, their names, a dot when it's
/// unread, and when it was last active.
struct DirectRoomRow: View {
    let room: SidebarRoom

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 32

    var body: some View {
        let unread = RoomList.isMarkedUnread(room, currentRoomID: workspace.currentRoomID)
        let members = RoomList.membersShown(room.room, me: workspace.me.id)
        HStack(spacing: 12) {
            if members.count == 1, let person = members.first {
                AvatarView(userID: person.id, name: workspace.name(of: person), size: avatarSize)
            } else {
                GroupAvatarView(people: members, size: avatarSize)
            }
            HStack(spacing: 4) {
                Text(workspace.name(of: room.room))
                    .font(.body.weight(unread ? .semibold : .regular))
                    .lineLimit(1)
                if members.count == 1, let person = members.first, workspace.isAssistant(person.id) {
                    AssistantMark()
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if let activeAt = room.room.activeAt {
                RelativeTimeText(activeAt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if unread {
                UnreadDot()
            }
        }
        .foregroundStyle(room.involvement.isQuiet ? .secondary : .primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Someone suggested for a DM, in a DM row's style. Tapping it opens the DM
/// with them, starting it if there isn't one.
struct SuggestionRow: View {
    let person: User
    let isStarting: Bool
    let start: () -> Void

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 32

    var body: some View {
        Button(action: start) {
            HStack(spacing: 12) {
                AvatarView(userID: person.id, name: workspace.name(of: person), size: avatarSize)
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
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityElement(children: .combine)
    }
}

/// The mark the assistant wears: the single sparkle.
struct AssistantMark: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Assistant.name)
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
