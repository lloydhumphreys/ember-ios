import SwiftUI
import EmberSDK

/// The fields New Room and Edit Room share: the name, Open or Closed, and for a closed room who's in
/// it, picked on a screen of their own.
struct RoomFormSections: View {
    @Binding var draft: RoomDraft
    /// Who a closed room can have in it, or nil while they load.
    let people: [User]?
    /// People who are in a closed room whatever's picked, ticked and fixed: you, in a new room.
    var locked: Set<UserID> = []
    /// Called when `people` failed to load, to load them again.
    var reload: (() -> Void)?
    /// Whether the name takes the keyboard as the form opens: in a new room, which has none yet.
    var focusesName = false

    @FocusState private var isNameFocused: Bool

    var body: some View {
        Section {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isNameFocused)
                .task {
                    guard focusesName else { return }
                    // Once the sheet is up: focus asked for as it slides in is dropped.
                    try? await Task.sleep(for: FocusTiming.afterPresenting)
                    isNameFocused = true
                }
        }
        Section {
            Picker("Access", selection: $draft.isClosed) {
                Text("Open").tag(false)
                Text("Closed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        if draft.isClosed {
            Section {
                membersRow
            }
        }
    }

    @ViewBuilder
    private var membersRow: some View {
        if let people {
            NavigationLink {
                RoomMembersPicker(people: people, members: $draft.members, locked: locked)
            } label: {
                LabeledContent("Members", value: (draft.members.union(locked).count).formatted())
            }
        } else if let reload {
            Button("Try Again", action: reload)
        } else {
            LabeledContent("Members") { ProgressView() }
        }
    }
}

/// Who's in a closed room: everyone it can have, with a tick on each one in it, searchable by name.
struct RoomMembersPicker: View {
    let people: [User]
    @Binding var members: Set<UserID>
    var locked: Set<UserID> = []

    @Environment(Workspace.self) private var workspace
    @State private var typed = ""
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    var body: some View {
        let shown = RoomPeople.matching(people, typed: typed) { workspace.name(of: $0) }
        List {
            ForEach(shown) { person in row(person) }
        }
        .overlay {
            if shown.isEmpty, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: typed)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $typed, placement: .navigationBarDrawer(displayMode: .always))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    private func row(_ person: User) -> some View {
        let isLocked = locked.contains(person.id)
        let isPicked = isLocked || members.contains(person.id)
        let name = workspace.name(of: person)
        return Button {
            if members.contains(person.id) {
                members.remove(person.id)
            } else {
                members.insert(person.id)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(userID: person.id, name: name, size: avatarSize)
                HStack(spacing: 4) {
                    Text(name)
                    if workspace.isAssistant(person.id) {
                        AssistantMark()
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Spacer(minLength: 0)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// How long a field waits to take the keyboard as its screen opens, so it's asked for once the sheet
/// or push has finished; asked for during it, it's dropped.
enum FocusTiming {
    static let afterPresenting: Duration = .milliseconds(500)
}
