import SwiftUI
import EmberSDK

/// A room's details: its mark and name, how much of it reaches you, whether it's starred, and who's
/// in it: for a group DM its members, for a closed room its members, for a shared room whoever else
/// has it open. Whoever can change a shared room edits or deletes it here.
struct RoomInfoView: View {
    let roomID: RoomID
    /// Who has the room open now, as its socket last said.
    let present: [User]
    /// Called as soon as Edit Room saves the room without you in it, while its sheet is still up.
    var onLeaving: () -> Void = {}
    /// Called once the room is deleted, or saved without you in it and Edit Room is down.
    var onLeft: () -> Void = {}

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    /// A shared room's settings, once loaded: who's in it, and whether you can change it.
    @State private var settings: RoomSettings?
    @State private var isEditing = false
    /// Set when Edit Room saved the room without you, so the room is left once its sheet is down.
    @State private var leftWhileEditing = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?
    @ScaledMetric(relativeTo: .title) private var markSize: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var faceSize: CGFloat = 32

    var body: some View {
        NavigationStack {
            Group {
                if let sidebarRoom = workspace.room(roomID) {
                    details(sidebarRoom)
                } else {
                    ContentUnavailableView("Room Unavailable", systemImage: "number")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PersonChoice.self) { PersonView(userID: $0.userID) }
            .toolbar {
                if canAdminister {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Edit") { isEditing = true }
                            .disabled(isDeleting)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isEditing, onDismiss: {
                guard leftWhileEditing else { return }
                leftWhileEditing = false
                onLeft()
            }) {
                if let settings {
                    RoomEditView(roomID: roomID, settings: settings) { left in
                        if left {
                            leftWhileEditing = true
                            onLeaving()
                        } else {
                            Task { await loadSettings() }
                        }
                        isEditing = false
                    }
                }
            }
            .alert(
                "Couldn’t Delete the Room",
                isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
        // Message on someone's screen closes Room Info, so their DM opens on the tab, not behind it.
        .environment(\.dismissesSheet, dismiss)
        .presentationDetents([.medium, .large])
        .task(id: roomID) { await loadSettings() }
    }

    /// Whether you can change or delete the room, as its settings say. Never for a DM.
    private var canAdminister: Bool {
        guard let settings, !settings.room.isDirect else { return false }
        return settings.canAdminister && workspace.room(roomID) != nil
    }

    /// A shared room's settings. A DM has none to load.
    private func loadSettings() async {
        guard let room = workspace.room(roomID)?.room, !room.isDirect else { return }
        if let loaded = try? await workspace.client.roomSettings(roomID) {
            settings = loaded
        }
    }

    private func delete() {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await workspace.deleteRoom(roomID)
                onLeft()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private func details(_ sidebarRoom: SidebarRoom) -> some View {
        let room = sidebarRoom.room
        let others = RoomList.membersShown(room, me: workspace.me.id)
        return List {
            Section {
                heading(room, others: others)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Picker("Notifications", selection: Binding(
                    get: { sidebarRoom.involvement },
                    set: { level in Task { await workspace.setInvolvement(level, roomID: roomID) } }
                )) {
                    ForEach(Involvement.levels(for: room.kind), id: \.self) { level in
                        Label(level.title, systemImage: level.symbol).tag(level)
                    }
                }
                .pickerStyle(.menu)
                // Starring is for shared rooms; the web's DMs have no star.
                if !room.isDirect {
                    Toggle("Star", isOn: Binding(
                        get: { workspace.isFavorite(roomID) },
                        set: { favorite in Task { await workspace.setFavorite(favorite, roomID: roomID) } }
                    ))
                }
            }
            // A DM with one other person is already them, in the heading.
            if room.isDirect, others.count > 1 {
                Section {
                    ForEach(others) { person in row(person) }
                }
            }
            if !room.isDirect {
                let here = Self.othersHere(present, me: workspace.me.id) { workspace.name(of: $0) }
                if !here.isEmpty {
                    Section("Here Now") {
                        ForEach(here) { person in row(person) }
                    }
                }
            }
            // An open room has everyone in it, so only a closed room lists its members.
            if room.kind == .closed, let settings {
                let members = Self.members(settings)
                if !members.isEmpty {
                    Section("Members") {
                        ForEach(members) { person in row(person) }
                    }
                }
            }
            if canAdminister {
                Section {
                    Button("Delete Room", role: .destructive) { isConfirmingDelete = true }
                        .disabled(isDeleting)
                        .deleteConfirmation("Delete this room and all its messages?", isPresented: $isConfirmingDelete) {
                            delete()
                        }
                }
            }
        }
    }

    /// A closed room's members, as its settings list them.
    static func members(_ settings: RoomSettings) -> [User] {
        settings.people.filter(\.member).map(\.user)
    }

    /// Someone in the room, opening their screen. Someone banned is dimmed under a prohibition mark,
    /// and VoiceOver says they're banned.
    private func row(_ person: User) -> some View {
        let isBanned = Self.isBanned(person.id, people: workspace.people)
        return NavigationLink(value: PersonChoice(userID: person.id)) {
            HStack(spacing: 12) {
                AvatarView(userID: person.id, name: workspace.name(of: person), size: faceSize)
                    .bannedMark(isBanned, size: faceSize)
                Text(workspace.name(of: person))
            }
        }
        .accessibilityValue(isBanned ? "Banned" : "")
    }

    /// Whether the directory has someone as banned. Someone it doesn't have isn't.
    static func isBanned(_ id: UserID, people: [UserID: DirectoryUser]) -> Bool {
        people[id]?.status == .banned
    }

    /// Everyone in `present` but you, once each, by name.
    static func othersHere(_ present: [User], me: UserID, name: (User) -> String) -> [User] {
        var seen: Set<UserID> = [me]
        return present
            .filter { seen.insert($0.id).inserted }
            .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    private func heading(_ room: Room, others: [User]) -> some View {
        VStack(spacing: 12) {
            if room.isDirect {
                GroupAvatarView(people: others, size: markSize)
            } else {
                Image(systemName: roomSymbol(for: room))
                    .font(.system(size: markSize * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: markSize, height: markSize)
                    .background(.fill.tertiary, in: .circle)
                    .accessibilityHidden(true)
            }
            Text(workspace.name(of: room))
                .font(.title2.bold())
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
