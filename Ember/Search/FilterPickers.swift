import EmberSDK
import SwiftUI

/// The directory and the rooms in the orders the pickers list them, worked out once each time the
/// directory or the sidebar changes rather than each time a view asks.
@MainActor final class PickerLists {
    static var shared: PickerLists { AccountStores.current.pickerLists }

    /// How many times each list has been worked out, which a test reads.
    private(set) var peopleBuilds = 0
    private(set) var directBuilds = 0
    private(set) var roomBuilds = 0

    private var peopleSource: [UserID: DirectoryUser]?
    private var sortedPeople: [DirectoryUser] = []
    private var directSource: (people: [UserID: DirectoryUser], me: UserID)?
    private var directPeople: [DirectoryUser] = []
    private var roomSource: [SidebarRoom]?
    private var sortedRooms: [RoomChoice] = []

    /// A room as the Room picker lists it.
    struct RoomChoice: Identifiable {
        let room: Room
        let name: String
        var id: RoomID { room.id }
    }

    /// Everyone in the directory by name, as Search's Person picker lists them: those still here
    /// first, then those who've been deactivated or suspended, whose messages stay to be found. Not
    /// anyone banned, whose messages were deleted with them, as the web leaves them out.
    func people(_ directory: [UserID: DirectoryUser]) -> [DirectoryUser] {
        if peopleSource == directory { return sortedPeople }
        peopleSource = directory
        sortedPeople = Self.byName(directory.values.filter { $0.status != .banned })
        peopleBuilds += 1
        return sortedPeople
    }

    /// Everyone New Message can start a DM with, in the order the server lists them.
    func direct(_ directory: [UserID: DirectoryUser], me: UserID) -> [DirectoryUser] {
        if let directSource, directSource.me == me, directSource.people == directory { return directPeople }
        directSource = (directory, me)
        directPeople = RoomList.peopleMatching(Array(directory.values), me: me, name: "")
        directBuilds += 1
        return directPeople
    }

    /// Shared rooms in sidebar order, then DMs latest first, each with its name.
    func rooms(in workspace: Workspace) -> [RoomChoice] {
        let rooms = workspace.rooms
        if roomSource == rooms { return sortedRooms }
        roomSource = rooms
        sortedRooms = (workspace.sharedRooms + workspace.directRooms).map {
            RoomChoice(room: $0.room, name: workspace.name(of: $0.room))
        }
        roomBuilds += 1
        return sortedRooms
    }

    /// Forgets the lists, as after signing out.
    func removeAll() {
        peopleSource = nil
        sortedPeople = []
        directSource = nil
        directPeople = []
        roomSource = nil
        sortedRooms = []
    }

    nonisolated static func byName(_ people: some Sequence<DirectoryUser>) -> [DirectoryUser] {
        people.sorted { a, b in
            let aActive = a.status == .active
            if aActive != (b.status == .active) { return aActive }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }

    /// Those whose name has `typed` in it, ignoring case and accents, in the order given.
    nonisolated static func matching<Item>(_ items: [Item], _ typed: String, name: (Item) -> String) -> [Item] {
        let sought = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sought.isEmpty else { return items }
        return items.filter { name($0).localizedStandardContains(sought) }
    }
}

/// Search's Person filter: the directory, searchable, built only once it's opened.
struct PersonFilterPicker: View {
    @Binding var selection: UserID?

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 32

    var body: some View {
        let people = PickerLists.shared.people(workspace.people)
        let shown = PickerLists.matching(people, typed) { $0.name }
        NavigationStack {
            List {
                if typed.isEmpty {
                    choice(isSelected: selection == nil, id: nil) {
                        Text("Anyone")
                    }
                }
                ForEach(shown) { person in
                    choice(isSelected: selection == person.id, id: person.id) {
                        HStack(spacing: 12) {
                            AvatarView(userID: person.id, name: person.name, size: avatarSize)
                            Text(person.name)
                                .foregroundStyle(person.status == .active ? .primary : .secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty, !typed.isEmpty {
                    ContentUnavailableView.search(text: typed)
                }
            }
            .navigationTitle("Person")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $typed, placement: .navigationBarDrawer(displayMode: .always))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
            }
        }
    }

    private func choice(isSelected: Bool, id: UserID?, @ViewBuilder label: () -> some View) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            FilterChoiceLabel(isSelected: isSelected, label: label())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Search's Room filter: every room you're in, searchable, built only once it's opened.
struct RoomFilterPicker: View {
    @Binding var selection: RoomID?

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        let rooms = PickerLists.shared.rooms(in: workspace)
        let shown = PickerLists.matching(rooms, typed) { $0.name }
        NavigationStack {
            List {
                if typed.isEmpty {
                    choice(isSelected: selection == nil, id: nil) {
                        Text("Any")
                    }
                }
                ForEach(shown) { choice in
                    self.choice(isSelected: selection == choice.id, id: choice.id) {
                        Label(choice.name, systemImage: roomSymbol(for: choice.room))
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty, !typed.isEmpty {
                    ContentUnavailableView.search(text: typed)
                }
            }
            .navigationTitle("Room")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $typed, placement: .navigationBarDrawer(displayMode: .always))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
            }
        }
    }

    private func choice(isSelected: Bool, id: RoomID?, @ViewBuilder label: () -> some View) -> some View {
        Button {
            selection = id
            dismiss()
        } label: {
            FilterChoiceLabel(isSelected: isSelected, label: label())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A picker row: its label, and a check when it's the one chosen.
private struct FilterChoiceLabel<Content: View>: View {
    let isSelected: Bool
    let label: Content

    var body: some View {
        HStack {
            label
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }
}
