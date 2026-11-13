import SwiftUI
import EmberSDK

/// New room: its name, whether it's private, and for a private room who's in it besides you, then Create,
/// which makes it and opens it.
struct NewRoomView: View {
    /// Called with the room once it's made.
    let onCreated: (RoomID) -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RoomDraft()
    /// Who a closed room can have in it, once loaded.
    @State private var people: [User]?
    /// Why `people` didn't load.
    @State private var peopleError: String?
    @State private var submission = Submission.idle

    var body: some View {
        NavigationStack {
            Form {
                if let error = submission.failure ?? (draft.isClosed ? peopleError : nil) {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                RoomFormSections(
                    draft: $draft,
                    people: people,
                    locked: [workspace.me.id],
                    reload: peopleError != nil ? { Task { await loadPeople() } } : nil,
                    focusesName: true
                )
            }
            .disabled(submission.isWorking)
            .onChange(of: draft) { submission.clearFailure() }
            .navigationTitle("New Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(submission.isWorking)
        .task { await loadPeople() }
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
                ConfirmButton("Create") {
                    create()
                }
                .disabled(!draft.hasValidName || (draft.isClosed && people == nil))
            }
        }
    }

    private func loadPeople() async {
        guard people == nil else { return }
        peopleError = nil
        do {
            people = try await workspace.client.newRoomForm().people
        } catch {
            peopleError = error.localizedDescription
        }
    }

    private func create() {
        guard draft.hasValidName, submission.begin() else { return }
        let newRoom = draft.newRoom(people: (people ?? []).map(\.id))
        Task {
            do {
                let room = try await workspace.createRoom(newRoom)
                onCreated(room.id)
            } catch {
                submission.fail(error.localizedDescription)
            }
        }
    }
}
