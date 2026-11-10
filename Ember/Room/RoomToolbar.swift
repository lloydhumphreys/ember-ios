import SwiftUI
import EmberSDK

/// The room's bar: a back button carrying the count of other unread rooms, the room's symbol (or
/// a DM's faces) and name, and a menu for starring and notifications.
struct RoomToolbar: ToolbarContent {
    let roomID: RoomID
    let room: Room?
    let status: ReconnectingSocket.Status
    let isLoaded: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var faceSize: CGFloat = 24

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                        .fontWeight(.semibold)
                    if othersUnread > 0 {
                        Text(othersUnread, format: .number)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityLabel("Back")
        }
        ToolbarItem(placement: .principal) {
            title
        }
        ToolbarItem(placement: .topBarTrailing) {
            menu
        }
    }

    /// Unread rooms other than this one, which counts as read while it's open.
    private var othersUnread: Int {
        workspace.unreadRooms.filter { $0.id != roomID }.count
    }

    /// Reconnecting after the timeline has once loaded. The first connection has the timeline's
    /// own spinner.
    private var isReconnecting: Bool {
        isLoaded && status == .connecting
    }

    @ViewBuilder private var title: some View {
        if let room {
            HStack(spacing: 6) {
                if isReconnecting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: faceSize, height: faceSize)
                } else if room.isDirect {
                    GroupAvatarView(people: RoomList.membersShown(room, me: workspace.me.id), size: faceSize)
                } else {
                    Image(systemName: roomSymbol(for: room))
                        .foregroundStyle(.secondary)
                }
                Text(workspace.name(of: room))
                    .font(.headline)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else if isReconnecting {
            ProgressView().controlSize(.mini)
        }
    }

    private var menu: some View {
        let sidebarRoom = workspace.room(roomID)
        let isDirect = sidebarRoom?.room.isDirect ?? false
        let isFavorite = workspace.isFavorite(roomID)
        return Menu {
            Button {
                Task { await workspace.setFavorite(!isFavorite, roomID: roomID) }
            } label: {
                Label(isFavorite ? "Unstar" : "Star", systemImage: isFavorite ? "star.slash" : "star")
            }
            // Starring is for shared rooms; the web's DMs have no star.
            .disabled(sidebarRoom == nil || isDirect)

            if let sidebarRoom {
                Picker(selection: Binding(
                    get: { sidebarRoom.involvement },
                    set: { level in Task { await workspace.setInvolvement(level, roomID: roomID) } }
                )) {
                    ForEach(Involvement.levels(for: sidebarRoom.room.kind), id: \.self) { level in
                        Label(level.title, systemImage: level.symbol).tag(level)
                    }
                } label: {
                    Label("Notifications", systemImage: sidebarRoom.involvement.symbol)
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(sidebarRoom == nil)
    }
}
