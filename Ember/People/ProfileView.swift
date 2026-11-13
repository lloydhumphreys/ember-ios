import PhotosUI
import SwiftUI
import EmberSDK

/// Your profile: your picture, to choose another or remove, then your name, bio, email address and
/// a new password, with your current password while you have one. A new picture is saved as soon
/// as it's picked; the rest when Done is tapped.
struct ProfileView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var model = ProfileModel()
    @State private var picked: PhotosPickerItem?
    @FocusState private var focus: ProfileModel.Field?
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 96

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        CancelButton { dismiss() }
                            .disabled(model.isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.isSaving {
                            ProgressView()
                        } else {
                            ConfirmButton("Done") {
                                Task { if await model.save() { dismiss() } }
                            }
                            .disabled(model.loading != .loaded || model.isChangingPicture)
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.isBusy || model.hasChanges)
        .task {
            model.attach(workspace)
            await model.load()
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await model.changePicture(data)
            }
        }
        .onChange(of: model.failedField) { _, field in
            if let field { focus = field }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loading {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") {
                    Task { await model.load() }
                }
                .prominentButtonStyle()
            }
        case .loaded:
            form
        }
    }

    private var form: some View {
        Form {
            if let failure = model.failure {
                Section {
                    Text(failure)
                        .foregroundStyle(.red)
                }
            }
            Section {
                AvatarView(userID: workspace.me.id, name: model.profile?.name ?? workspace.me.name, size: avatarSize)
                    .overlay {
                        if model.isChangingPicture {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            // On its own, above the card, so the card has its rounded corners and no line on top.
            .listSectionSpacing(.compact)
            Section {
                PhotosPicker(selection: $picked, matching: .images, preferredItemEncoding: .current) {
                    Text("Choose Photo")
                }
                .disabled(model.isBusy)
                if model.hasAvatar {
                    Button("Remove Photo", role: .destructive) {
                        Task { await model.removePicture() }
                    }
                    .disabled(model.isBusy)
                }
            }
            Section {
                TextField("Name", text: $model.name)
                    .textContentType(.name)
                    .focused($focus, equals: .name)
                TextField("Bio", text: $model.bio, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .focused($focus, equals: .bio)
            }
            Section {
                TextField("Email Address", text: $model.emailAddress)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .emailAddress)
            }
            Section {
                SecureField("New Password", text: $model.newPassword)
                    .textContentType(.newPassword)
                    .focused($focus, equals: .password)
                if model.hasPassword {
                    SecureField("Current Password", text: $model.currentPassword)
                        .textContentType(.password)
                        .focused($focus, equals: .currentPassword)
                }
            }
        }
        .disabled(model.isSaving)
        .onChange(of: [model.name, model.bio, model.emailAddress, model.newPassword, model.currentPassword]) {
            model.clearFailure()
        }
    }
}
