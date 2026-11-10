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
    /// In the order they were picked, which is the order the server is sent.
    @State private var picked: [UserID] = []
    @State private var isStarting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("New Message")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $typed, placement: .navigationBarDrawer(displayMode: .always))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(isStarting)
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
                .buttonStyle(.glassProminent)
            }
        } else if workspace.people.isEmpty, workspace.directoryStatus == .loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let options = matches.filter { !picked.contains($0.id) }
            List {
                if let error {
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
            .disabled(isStarting)
            .overlay {
                if options.isEmpty, picked.isEmpty, !sought.isEmpty {
                    ContentUnavailableView.search(text: sought)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var sought: String { RoomList.soughtName(typed) }

    private var matches: [DirectoryUser] {
        RoomList.peopleMatching(Array(workspace.people.values), me: workspace.me.id, name: sought)
    }

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    private func personRow(_ person: DirectoryUser, isPicked: Bool) -> some View {
        Button {
            error = nil
            if isPicked {
                picked.removeAll { $0 == person.id }
            } else {
                picked.append(person.id)
            }
        } label: {
            HStack(spacing: 12) {
                AvatarView(userID: person.id, name: person.name, size: avatarSize)
                HStack(spacing: 4) {
                    Text(person.name)
                        .lineLimit(1)
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
            Button(role: .cancel) {
                dismiss()
            }
            .disabled(isStarting)
        }
        ToolbarItem(placement: .confirmationAction) {
            if isStarting {
                ProgressView()
            } else {
                Button("Start", role: .confirm) {
                    start()
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    private func start() {
        guard !picked.isEmpty, !isStarting else { return }
        isStarting = true
        error = nil
        Task {
            do {
                let room = try await workspace.startDirect(with: picked)
                onStarted(room.id)
            } catch {
                self.error = error.localizedDescription
                isStarting = false
            }
        }
    }
}
