import SwiftUI
import EmberSDK

/// The room's title in its bar, which opens the room's details.
struct RoomInfoButton<Label: View>: View {
    let roomID: RoomID
    let present: [User]
    @ViewBuilder let label: Label

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: { label }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShowing) {
                RoomInfoView(roomID: roomID, present: present)
            }
    }
}

/// A room's details: its mark and name, how much of it reaches you, whether it's starred, and who's
/// in it: for a group DM its members, for a shared room whoever else has it open.
struct RoomInfoView: View {
    let roomID: RoomID
    /// Who has the room open now, as its socket last said.
    let present: [User]

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
            // The SDK has no list of a shared room's members, but knows who has it open.
            if !room.isDirect {
                let here = Self.othersHere(present, me: workspace.me.id) { workspace.name(of: $0) }
                if !here.isEmpty {
                    Section("Here Now") {
                        ForEach(here) { person in row(person) }
                    }
                }
            }
        }
    }

    private func row(_ person: User) -> some View {
        HStack(spacing: 12) {
            AvatarView(userID: person.id, name: workspace.name(of: person), size: faceSize)
            Text(workspace.name(of: person))
        }
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
