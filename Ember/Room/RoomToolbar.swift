import SwiftUI
import EmberSDK

/// The room's bar: a back button carrying the count of other unread rooms, the room's symbol (or
/// a DM's faces) and name, and a menu for starring and notifications.
struct RoomToolbar: ToolbarContent {
    let roomID: RoomID
    let room: Room?
    let status: ReconnectingSocket.Status
    let isLoaded: Bool
    /// Who has the room open, for its details.
    let present: [User]

    @Environment(Workspace.self) private var workspace
    @Environment(NetworkStatus.self) private var network
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
            // The count the button shows, said as what it counts.
            .accessibilityValue(UnreadValue.text(othersUnread) ?? "")
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

    private var connection: RoomConnection? {
        RoomConnection(isOnline: network.isOnline, isLoaded: isLoaded, status: status)
    }

    /// The faces' size: following the text size, but held to what the bar's height has room for.
    private var shownFaceSize: CGFloat { RoomTitleLayout.faceSize(faceSize) }

    @ViewBuilder private var title: some View {
        if let room {
            RoomInfoButton(roomID: roomID, present: present) {
                HStack(spacing: 6) {
                    if let connection {
                        RoomConnectionView(connection: connection, controlSize: .mini)
                            .frame(width: shownFaceSize, height: shownFaceSize)
                    } else if room.isDirect {
                        GroupAvatarView(people: RoomList.membersShown(room, me: workspace.me.id), size: shownFaceSize)
                    } else {
                        // Smaller than the name it marks, as the "#" a name is written with is.
                        Image(systemName: roomSymbol(for: room))
                            .font(.footnote.weight(.semibold))
                            // The bar draws its symbols large; this one stays the size of its font.
                            .imageScale(.medium)
                            .foregroundStyle(.secondary)
                    }
                    Text(workspace.name(of: room))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // On glass of its own, as the bar's buttons are, so messages scrolling under the bar
                // don't show through the name, and with room round the faces so the capsule's ends
                // don't cut them.
                .padding(.leading, room.isDirect || connection != nil ? RoomTitleLayout.facePadding : 12)
                .padding(.trailing, 12)
                .padding(.vertical, RoomTitleLayout.facePadding)
                .titleBackground(in: .capsule)
                .contentShape(.capsule)
                .accessibilityElement(children: .combine)
            }
        } else if let connection {
            RoomConnectionView(connection: connection, controlSize: .mini)
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

/// What a room's or a thread's bar shows of its connection: offline while the device is, and
/// reconnecting once the timeline has loaded (the first connection has the timeline's spinner).
enum RoomConnection: Equatable {
    case offline
    case reconnecting

    init?(isOnline: Bool, isLoaded: Bool, status: ReconnectingSocket.Status) {
        if !isOnline {
            self = .offline
        } else if isLoaded && status == .connecting {
            self = .reconnecting
        } else {
            return nil
        }
    }
}

struct RoomConnectionView: View {
    let connection: RoomConnection
    var controlSize: ControlSize = .small

    var body: some View {
        switch connection {
        case .offline:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Offline")
        case .reconnecting:
            ProgressView()
                .controlSize(controlSize)
                .accessibilityLabel("Connecting")
        }
    }
}

/// Sizes the room's title takes in the bar.
enum RoomTitleLayout {
    /// The largest the faces grow: the bar keeps its height at every text size, so anything taller
    /// is cut off.
    static let largestFace: CGFloat = 30
    /// Room between the faces and the capsule's edge.
    static let facePadding: CGFloat = 4

    static func faceSize(_ scaled: CGFloat) -> CGFloat { min(scaled, largestFace) }
}
