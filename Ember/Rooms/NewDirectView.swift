import SwiftUI
import EmberSDK

/// New direct message: a search of the people directory, as you type and
/// without asking the server, to pick one or more of, then Start, which
/// opens the DM between them and you, starting it if there isn't one.
struct NewDirectView: View {
    /// Called with the DM's room once it has started.
    let onStarted: (RoomID) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var isSearching = false
    /// In the order they were picked, which is the order the server is sent.
    @State private var picked: [UserID] = []
    @State private var submission = Submission.idle

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Message")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $typed, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(submission.isWorking)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.people.isEmpty, case .failed(let message) = workspace.directoryStatus {
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") {
                    Task { await workspace.reloadDirectory() }
                }
                .prominentButtonStyle()
            }
        } else if workspace.people.isEmpty, workspace.directoryStatus == .loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let options = matches.filter { !picked.contains($0.id) }
            List {
                if let error = submission.failure {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                if !picked.isEmpty {
                    Section {
                        ForEach(picked, id: \.self) { id in
                            if let person = workspace.person(id) {
                                personRow(person, isPicked: true)
                            }
                        }
                    }
                }
                Section {
                    ForEach(options) { personRow($0, isPicked: false) }
                }
            }
            .disabled(submission.isWorking)
            .overlay {
                if options.isEmpty, picked.isEmpty, !sought.isEmpty {
                    ContentUnavailableView.search(text: sought)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var sought: String { RoomList.soughtName(typed) }

    /// The directory is sorted once each time it changes; what's typed only narrows that list.
    private var matches: [DirectoryUser] {
        let everyone = PickerLists.shared.direct(workspace.people, me: workspace.me.id)
        return sought.isEmpty ? everyone : RoomList.peopleMatching(everyone, me: workspace.me.id, name: sought)
    }

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    private func personRow(_ person: DirectoryUser, isPicked: Bool) -> some View {
        Button {
            submission.clearFailure()
            if isPicked {
                picked.removeAll { $0 == person.id }
            } else {
                picked.append(person.id)
                // Ending the search brings back the toolbar, and Start with it; clearing what was
                // typed brings back everyone else to pick from.
                isSearching = false
                typed = ""
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(userID: person.id, name: person.name, size: avatarSize)
                HStack(spacing: 4) {
                    Text(person.name)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            CancelButton {
                dismiss()
            }
            .disabled(submission.isWorking)
        }
        ToolbarItem(placement: .confirmationAction) {
            if submission.isWorking {
                ProgressView()
            } else {
                ConfirmButton("Start") {
                    start()
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    private func start() {
        guard !picked.isEmpty, submission.begin() else { return }
        Task {
            do {
                let room = try await workspace.startDirect(with: picked)
                onStarted(room.id)
            } catch {
                submission.fail(error.localizedDescription)
            }
        }
    }
}
