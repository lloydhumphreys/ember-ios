import SwiftUI
import EmberSDK

/// The Activity tab: only the rooms and DMs marked unread, shared rooms
/// first, in the Home tab's rows.
struct ActivityView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(NetworkStatus.self) private var network

    var body: some View {
        SidebarGate { list }
        .navigationTitle("Activity")
        .toolbar {
            if ConnectionIndicator.isShown(workspace: workspace, network: network) {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionIndicator()
                }
            }
        }
    }

    private var list: some View {
        let unread = workspace.unreadRooms
        return List {
            ForEach(unread) { room in
                RoomRowLink(room: room)
                    // A plain list draws a line above its first row too; only the ones between rows stay.
                    .listRowSeparator(room.id == unread.first?.id ? .hidden : .automatic, edges: .top)
            }
        }
        .listStyle(.plain)
        .clearsFloatingNewMessage()
        .overlay {
            if unread.isEmpty {
                ContentUnavailableView("No Unread Messages", systemImage: "bell")
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await workspace.reload() }
    }
}
