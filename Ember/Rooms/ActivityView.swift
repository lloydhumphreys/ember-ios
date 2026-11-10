import SwiftUI
import EmberSDK

/// The Activity tab: only the rooms and DMs marked unread, shared rooms
/// first, in the Home tab's rows.
struct ActivityView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if workspace.isLoaded {
                list
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            if workspace.connection != .open {
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
        .overlay {
            if unread.isEmpty {
                ContentUnavailableView("No Unread Messages", systemImage: "bell")
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await workspace.reload() }
    }
}
