import SwiftUI
import EmberSDK

/// Edit room, for whoever can change it: its name, whether it's private, and a private room's members,
/// ticked as they are, then Save. Saving it private without you takes you out of it, which asks first.
struct RoomEditView: View {
    let roomID: RoomID
    let settings: RoomSettings
    /// Called once it's saved, with whether you're no longer in it.
    let onSaved: (_ left: Bool) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RoomDraft
    @State private var submission = Submission.idle
    /// Changes that take you out of the room, waiting to be confirmed.
    @State private var leaving: RoomChanges?

    init(roomID: RoomID, settings: RoomSettings, onSaved: @escaping (_ left: Bool) -> Void) {
        self.roomID = roomID
        self.settings = settings
        self.onSaved = onSaved
        _draft = State(initialValue: RoomDraft(settings: settings))
    }

    private var people: [User] { settings.people.map(\.user) }

    private var changes: RoomChanges? {
        draft.changes(from: RoomDraft(settings: settings), people: people.map(\.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = submission.failure {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                RoomFormSections(draft: $draft, people: people)
            }
            .disabled(submission.isWorking)
            .onChange(of: draft) { submission.clearFailure() }
            .navigationTitle("Edit Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(submission.isWorking || changes != nil)
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
                ConfirmButton("Save") {
                    guard let changes else { return }
                    if RoomDraft.removes(workspace.me.id, with: changes) {
                        leaving = changes
                    } else {
                        save(changes)
                    }
                }
                .disabled(!draft.hasValidName || changes == nil)
                // On Save, so the popover points at what it's confirming.
                .confirmationDialog(
                    "You’ll no longer be in this room.",
                    isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                    titleVisibility: .visible,
                    presenting: leaving
                ) { changes in
                    Button("Save", role: .destructive) { save(changes) }
                }
            }
        }
    }

    private func save(_ changes: RoomChanges) {
        guard submission.begin() else { return }
        Task {
            do {
                try await workspace.changeRoom(roomID, changes)
                submission.finish()
                onSaved(RoomDraft.removes(workspace.me.id, with: changes))
            } catch {
                submission.fail(error.localizedDescription)
            }
        }
    }
}
