import SwiftUI
import EmberSDK

/// The Home tab: the shared rooms, starred first, then the DMs, latest active
/// first, and the people suggested for a DM after them, as Ember's sidebar
/// lists them.
struct RoomsView: View {
    @Binding var path: NavigationPath

    @Environment(Workspace.self) private var workspace
    @State private var isComposing = false
    /// Who's suggested whose DM is starting, so another tap doesn't start it
    /// again.
    @State private var startingWith: UserID?
    @State private var startError: String?

    var body: some View {
        Group {
            if workspace.isLoaded {
                list
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(workspace.account.name)
        .toolbar { toolbar }
        .sheet(isPresented: $isComposing) {
            NewDirectView { roomID in
                isComposing = false
                path.append(RoomLink(roomID: roomID))
            }
        }
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
                Section("Rooms") {
                    ForEach(shared) { RoomRowLink(room: $0) }
                }
            }
            if !directs.isEmpty || !suggested.isEmpty {
                Section("Direct Messages") {
                    ForEach(directs) { RoomRowLink(room: $0) }
                    ForEach(suggested) { person in
                        SuggestionRow(person: person, isStarting: startingWith == person.id) {
                            start(with: person)
                        }
                        .disabled(startingWith != nil)
                    }
                }
            }
        }
        .listStyle(.plain)
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
        if workspace.connection != .open {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionIndicator()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isComposing = true
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
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

/// The quiet sign that the workspace's socket isn't open: a spinner where
/// the navigation bar's leading edge is otherwise empty.
struct ConnectionIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Connecting")
    }
}
