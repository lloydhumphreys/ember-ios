import SwiftUI
import EmberSDK

/// Invite People, for administrators: email addresses to invite, what came of the last ones sent,
/// and the invitations no one has accepted yet, each to send again or revoke.
struct InvitePeopleView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var model = InviteModel()
    /// The invitation Revoke is asking about.
    @State private var confirmingRevoke: EmailInvitation?
    /// Invitations just sent again, each showing a checkmark for a moment.
    @State private var justResent: Set<InvitationID> = []

    var body: some View {
        NavigationStack {
            List {
                if let failure = model.failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Email Addresses", text: $model.text, axis: .vertical)
                        .lineLimit(1 ... 6)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isSending)
                    Button {
                        Task { await model.send() }
                    } label: {
                        HStack {
                            Text("Send")
                            Spacer(minLength: 0)
                            if model.isSending {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!model.canSend)
                }
                outcomeSections
                pendingSection
            }
            .animation(.default, value: model.pendingShown)
            .animation(.default, value: model.outcomes)
            .navigationTitle("Invite People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isSending)
                }
            }
            .refreshable { await model.reload() }
            .task {
                model.attach(workspace.client)
                await model.reload()
            }
            .onChange(of: model.text) {
                model.clearFailure()
            }
        }
        .interactiveDismissDisabled(model.isSending)
    }

    /// Whether Revoke is asking about `invitation`, so its dialog comes from that row.
    private func isConfirmingRevoke(_ invitation: EmailInvitation) -> Binding<Bool> {
        Binding(
            get: { confirmingRevoke?.id == invitation.id },
            set: { if !$0, confirmingRevoke?.id == invitation.id { confirmingRevoke = nil } }
        )
    }

    // MARK: What came of the last addresses sent

    @ViewBuilder
    private var outcomeSections: some View {
        let invited = model.outcomes.filter { $0.kind != .member }
        let members = model.outcomes.filter { $0.kind == .member }
        if !invited.isEmpty {
            Section("Invited") {
                ForEach(invited) { outcome in
                    if case let .invited(id) = outcome.kind {
                        invitedRow(outcome.emailAddress, id: id)
                    }
                }
            }
        }
        if !members.isEmpty {
            Section("Already Members") {
                ForEach(members) { outcome in
                    Text(outcome.emailAddress)
                }
            }
        }
    }

    private func invitedRow(_ emailAddress: String, id: InvitationID) -> some View {
        let refused = model.invitation(id).map(InviteModel.wasRefused) ?? false
        let link = model.link(for: id)
        return HStack {
            AddressLabel(emailAddress: emailAddress, refused: refused)
            Spacer(minLength: 0)
            if let link {
                InviteLinkShare(link: link)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .contextMenu {
            if let link {
                InviteLinkShare(link: link)
                copyButton(link)
            }
        }
    }

    // MARK: Pending

    @ViewBuilder
    private var pendingSection: some View {
        switch model.loading {
        case .idle, .loading:
            if model.pendingShown.isEmpty {
                Section("Pending") {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else {
                pendingList
            }
        case .failed(let message):
            Section("Pending") {
                Text(message)
                    .foregroundStyle(.red)
                Button("Try Again") {
                    Task { await model.reload() }
                }
            }
        case .loaded:
            if !model.pendingShown.isEmpty {
                pendingList
            }
        }
    }

    private var pendingList: some View {
        Section("Pending") {
            ForEach(model.pendingShown) { invitation in
                pendingRow(invitation)
            }
        }
    }

    private func pendingRow(_ invitation: EmailInvitation) -> some View {
        let busy = model.isWorking(on: invitation.id)
        let link = model.link(for: invitation.id)
        return HStack {
            AddressLabel(emailAddress: invitation.emailAddress, refused: InviteModel.wasRefused(invitation))
            Spacer(minLength: 0)
            if busy {
                ProgressView()
            } else if justResent.contains(invitation.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if let link {
                InviteLinkShare(link: link)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        // Not role .destructive here: a swipe's destructive button takes the row away at once,
        // before Revoke has asked.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                confirmingRevoke = invitation
            } label: {
                Label("Revoke", systemImage: "xmark.circle")
            }
            .tint(.red)
            resendButton(invitation)
        }
        .contextMenu {
            if let link {
                Section {
                    InviteLinkShare(link: link)
                    copyButton(link)
                }
            }
            resendButton(invitation)
            Button(role: .destructive) {
                confirmingRevoke = invitation
            } label: {
                Label("Revoke", systemImage: "xmark.circle")
            }
        }
        .disabled(busy)
        // On the row, as Revoke comes from its swipe or its menu, which are gone by the time it asks.
        .confirmationDialog("Revoke Invitation", isPresented: isConfirmingRevoke(invitation), titleVisibility: .hidden) {
            Button("Revoke Invitation", role: .destructive) {
                Task { await model.revoke(invitation.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func resendButton(_ invitation: EmailInvitation) -> some View {
        Button {
            Task { await resend(invitation.id) }
        } label: {
            Label("Resend", systemImage: "paperplane")
        }
        .tint(.blue)
    }

    /// Sends `id` again, then shows a checkmark on its row for a moment, and says so to VoiceOver.
    private func resend(_ id: InvitationID) async {
        guard let sent = await model.resend(id) else { return }
        justResent.insert(sent)
        AccessibilityNotification.Announcement("Invitation Resent").post()
        try? await Task.sleep(for: .seconds(2))
        justResent.remove(sent)
    }

    private func copyButton(_ link: Secret) -> some View {
        Button {
            InviteModel.copy(link)
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
    }
}

/// An invited address, marked when the email provider refused to send it.
private struct AddressLabel: View {
    let emailAddress: String
    let refused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(emailAddress)
            if refused {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityLabel("Not Delivered")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Passes an invitation's link on through the share sheet, which never shows it as text here.
private struct InviteLinkShare: View {
    let link: Secret

    var body: some View {
        if let url = InviteModel.url(of: link) {
            ShareLink(item: url, preview: SharePreview("Invitation")) { label }
        } else {
            ShareLink(item: link.revealed, preview: SharePreview("Invitation")) { label }
        }
    }

    private var label: some View {
        Label("Share Link", systemImage: "square.and.arrow.up")
    }
}
