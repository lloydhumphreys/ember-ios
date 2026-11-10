import SwiftUI
import EmberSDK

/// Signing in to the chosen server: an email address and password, or just a name where the
/// server allows guests, with the server's host and a way back to choose another.
///
/// A server that hasn't been set up has no one to sign in as, and setting it up happens in the
/// browser, so that case gets a link there instead of the form.
struct SignInView: View {
    let client: EmberClient
    let bootstrap: Bootstrap

    @Environment(SessionController.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field { case email, password, name }

    init(client: EmberClient, bootstrap: Bootstrap) {
        self.client = client
        self.bootstrap = bootstrap
    }

    private var isGuest: Bool { bootstrap.guestSignIn }
    private var needsSetup: Bool { bootstrap.setup == .pending }

    private var canSubmit: Bool {
        guard !isWorking, !needsSetup else { return false }
        if isGuest { return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private var title: String {
        let account = bootstrap.account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return account.isEmpty || needsSetup ? "Sign In" : "Sign In to \(account)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmberMark()
                    .padding(.top, 48)
                    .padding(.bottom, 20)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                Group {
                    if needsSetup {
                        setup
                    } else {
                        form
                    }
                }
                .padding(.horizontal, 24)

                footer
            }
            .frame(maxWidth: .infinity)
        }
        // Scrolling reaches what the largest text sizes or the keyboard push off screen. It
        // bounces even when everything fits, so dragging down always takes the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .onAppear {
            if !needsSetup { field = isGuest ? .name : .email }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 0) {
            if isGuest {
                TextField("Name", text: correcting($name))
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.go)
                    .focused($field, equals: .name)
                    .onSubmit(submit)
                    .padding(.vertical, 12)
            } else {
                TextField("Email", text: correcting($email))
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($field, equals: .email)
                    .onSubmit { field = .password }
                    .padding(.vertical, 12)

                // Two plain fields stacked on a card read as one; the hairline makes them two.
                Divider()

                SecureField("Password", text: correcting($password))
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($field, equals: .password)
                    .onSubmit(submit)
                    .padding(.vertical, 12)
            }

            Button(action: submit) {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text("Sign In").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .padding(.top, 14)
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
    }

    /// Correcting what failed is what clears the complaint about it. It's done as the field
    /// writes rather than by watching the string, which a burst of input changes several times
    /// a frame.
    private func correcting(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { text.wrappedValue = $0; clearError() })
    }

    @ViewBuilder
    private var setup: some View {
        VStack(spacing: 16) {
            Text("This server hasn’t been set up yet.")
                .font(.body)
                .multilineTextAlignment(.center)
            if let url = client.url("/first_run") {
                Link("Set Up in Safari", destination: url)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 14) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Text(ServerAddress.display(client.origin))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { session.forgetServer() }
                    .disabled(isWorking)
            }
            .font(.footnote)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
    }

    private func clearError() {
        if error != nil { error = nil }
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        let isGuest = isGuest
        Task {
            do {
                if isGuest {
                    try await session.signIn(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    try await session.signIn(
                        emailAddress: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                }
            } catch {
                self.error = (error as? EmberError)?.message ?? error.localizedDescription
                if !isGuest { field = .password }
            }
            isWorking = false
        }
    }
}
