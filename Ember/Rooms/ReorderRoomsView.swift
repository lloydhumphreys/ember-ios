import SwiftUI
import EmberSDK

/// Reorder: your starred rooms, and for an administrator the order shared rooms come in for
/// everyone, each dragged by its handle. Each move saves at once.
struct ReorderRoomsView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let starred = workspace.favoriteRooms
        let shared = workspace.roomsInSharedOrder
        NavigationStack {
            List {
                if RoomReorder.offersStarred(favoriteCount: starred.count) {
                    Section("Starred") {
                        ForEach(starred) { row($0) }
                            .onMove { offsets, destination in
                                Task { await workspace.moveFavorites(fromOffsets: offsets, toOffset: destination) }
                            }
                    }
                }
                if RoomReorder.offersShared(me: workspace.me, sharedCount: shared.count) {
                    Section("For Everyone") {
                        ForEach(shared) { row($0) }
                            .onMove { offsets, destination in
                                Task { await workspace.moveSharedRooms(fromOffsets: offsets, toOffset: destination) }
                            }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .workspaceNotice()
        }
    }

    private func row(_ room: SidebarRoom) -> some View {
        Label {
            Text(workspace.name(of: room.room))
                .lineLimit(1)
        } icon: {
            Image(systemName: roomSymbol(for: room.room))
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Shows what the workspace says it couldn't do, such as a move or a star the server refused.
    /// `isActive` false while something this screen presents shows it instead.
    func workspaceNotice(isActive: Bool = true) -> some View {
        modifier(WorkspaceNotice(isActive: isActive))
    }
}

private struct WorkspaceNotice: ViewModifier {
    let isActive: Bool
    @Environment(Workspace.self) private var workspace
    /// Only while this screen is the one showing, so two screens don't both try to show it.
    @State private var isShown = false

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        content
            .onAppear { isShown = true }
            .onDisappear { isShown = false }
            .alert(
                workspace.notice ?? "",
                isPresented: Binding(get: { isActive && isShown && workspace.notice != nil }, set: { if !$0 { workspace.notice = nil } })
            ) {
                Button("OK", role: .cancel) { workspace.notice = nil }
            }
    }
}
