import SwiftUI
import EmberSDK

/// Someone: their avatar, name and bio, their email address for an administrator, and Message, to
/// open your DM with them. Administrators can ban anyone else, or unban someone banned.
///
/// Push it on a navigation stack, or present `PersonSheet` for it on a stack of its own. A sheet
/// it's in should set `dismissesSheet`, so Message closes the sheet before the DM opens behind it.
struct PersonView: View {
    let userID: UserID

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.dismissesSheet) private var dismissesSheet
    @State private var model: PersonModel
    @State private var isConfirmingBan = false
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 96

    init(userID: UserID) {
        self.userID = userID
        _model = State(initialValue: PersonModel(userID: userID))
    }

    var body: some View {
        List {
            if let failure = model.failure {
                Section {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            Section {
                heading
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if model.isBanned {
                Section {
                    Text("Banned")
                }
            }
            if let emailAddress = model.emailAddress {
                Section {
                    LabeledContent("Email Address") {
                        Text(emailAddress)
                            .textSelection(.enabled)
                    }
                }
            }
            if model.canMessage {
                Section {
                    Button("Message", systemImage: "message") {
                        Task { await message() }
                    }
                }
            }
            if model.canBan {
                Section {
                    Button("Ban", role: .destructive) { isConfirmingBan = true }
                        .confirmationDialog("Ban \(model.name)?", isPresented: $isConfirmingBan, titleVisibility: .visible) {
                            Button("Ban", role: .destructive) {
                                Task { await model.ban() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("They’ll be signed out, their messages will be deleted, and their IP addresses will be blocked.")
                        }
                }
            }
            if model.canUnban {
                Section {
                    Button("Unban") {
                        Task { await model.unban() }
                    }
                }
            }
        }
        .disabled(model.isWorking)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.attach(workspace)
            await model.load()
        }
    }

    private var heading: some View {
        VStack(spacing: 8) {
            AvatarView(userID: userID, name: model.name, size: avatarSize)
                .bannedMark(model.isBanned, size: avatarSize)
            HStack(spacing: 4) {
                Text(model.name)
                if workspace.isAssistant(userID) { AssistantMark() }
            }
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            if let bio = model.person?.bio, !bio.isEmpty {
                Text(bio)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Opens the DM through the tab's room links, closing the sheet this is in first.
    private func message() async {
        guard let roomID = await model.startDirect() else { return }
        let url = workspace.client.origin.appending(path: "rooms").appending(path: roomID.rawValue)
        dismissesSheet?()
        openURL(url)
    }
}

/// `PersonView` as a sheet: on a stack of its own, with Done.
struct PersonSheet: View {
    let userID: UserID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PersonView(userID: userID)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .environment(\.dismissesSheet, dismiss)
    }
}

/// Someone to show.
struct PersonChoice: Identifiable, Hashable {
    let userID: UserID
    var id: UserID { userID }
}

/// Shows someone in a sheet, for rows that can't hold one each, as the timeline's can't.
@MainActor @Observable
final class PersonPresenter {
    var shown: PersonChoice?

    func show(_ userID: UserID) {
        shown = PersonChoice(userID: userID)
    }
}

extension EnvironmentValues {
    /// What shows someone when their face or name is tapped in a message. Nil where nothing does.
    @Entry var personPresenter: PersonPresenter? = nil
    /// Closes the sheet a view is in, for an action that goes on to open something behind it.
    @Entry var dismissesSheet: DismissAction? = nil
}

private struct PresentsPeople: ViewModifier {
    @State private var presenter = PersonPresenter()

    func body(content: Content) -> some View {
        @Bindable var presenter = presenter
        content
            .environment(\.personPresenter, presenter)
            .sheet(item: $presenter.shown) { choice in
                PersonSheet(userID: choice.userID)
            }
    }
}

extension View {
    /// Shows whoever a message's face or name is tapped for, in a sheet over this view.
    func presentsPeople() -> some View {
        modifier(PresentsPeople())
    }
}
