import SwiftUI
import EmberSDK

/// The Home tab: the shared rooms, starred first, then the DMs, latest active
/// first, and the people suggested for a DM after them, as Ember's sidebar
/// lists them.
struct RoomsView: View {
    @Binding var path: NavigationPath

    @Environment(Workspace.self) private var workspace
    @Environment(NetworkStatus.self) private var network
    /// Who's suggested whose DM is starting, so another tap doesn't start it
    /// again.
    @State private var startingWith: UserID?
    @State private var startError: String?

    var body: some View {
        SidebarGate { list }
        .navigationTitle(workspace.account.name)
        .toolbar { toolbar }
        .alert(
            "Couldn’t Start the Conversation",
            isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })
        ) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "")
        }
    }

    private var list: some View {
        let shared = workspace.sharedRooms
        let directs = workspace.directRooms
        let suggested = workspace.suggestedPeople
        return List {
            if !shared.isEmpty {
                Section {
                    ForEach(shared) { RoomRowLink(room: $0) }
                } header: {
                    PinnedSectionHeader("Rooms")
                }
                .listSectionSeparator(.hidden, edges: .top)
            }
            if !directs.isEmpty || !suggested.isEmpty {
                Section {
                    ForEach(directs) { RoomRowLink(room: $0) }
                    ForEach(suggested) { person in
                        SuggestionRow(person: person, isStarting: startingWith == person.id) {
                            start(with: person)
                        }
                        .disabled(startingWith != nil)
                    }
                } header: {
                    PinnedSectionHeader("Direct Messages")
                }
                .listSectionSeparator(.hidden, edges: .top)
            }
        }
        .listStyle(.plain)
        .clearsFloatingNewMessage()
        // Over the list rather than in it, with hit-testing off, so pull to
        // refresh still works through it.
        .overlay {
            if shared.isEmpty, directs.isEmpty, suggested.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right")
                    .allowsHitTesting(false)
            }
        }
        .refreshable { await workspace.reload() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if ConnectionIndicator.isShown(workspace: workspace, network: network) {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionIndicator()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            AccountMenu()
        }
    }

    private func start(with person: User) {
        guard startingWith == nil else { return }
        startingWith = person.id
        Task {
            defer { startingWith = nil }
            do {
                let room = try await workspace.startDirect(with: [person.id])
                path.append(RoomLink(roomID: room.id))
            } catch {
                startError = error.localizedDescription
            }
        }
    }
}

/// The quiet sign that the workspace's socket isn't open, where the navigation
/// bar's leading edge is otherwise empty: a crossed-out Wi-Fi symbol while the
/// device is offline, and a spinner while it's online and connecting.
struct ConnectionIndicator: View {
    @Environment(NetworkStatus.self) private var network

    var body: some View {
        if network.isOnline {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Connecting")
        } else {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Offline")
        }
    }

    /// Not while nothing has loaded and the list shows a failure with Retry instead (`SidebarPhase`).
    @MainActor static func isShown(workspace: Workspace, network: NetworkStatus) -> Bool {
        guard SidebarPhase(workspace) != .failed else { return false }
        return !network.isOnline || workspace.connection != .open
    }
}
