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
    @State private var submission: Submission
    @FocusState private var field: Field?

    private enum Field { case email, password, name }

    /// `reason` is why sign-in is showing, as `SessionController.signOutReason` keeps it.
    init(client: EmberClient, bootstrap: Bootstrap, reason: SignOutReason?) {
        self.client = client
        self.bootstrap = bootstrap
        _submission = State(initialValue: Self.signedOutMessage(reason).map(Submission.failed) ?? .idle)
    }

    /// Why sign-in is showing, where the server ended the session rather than the person asking.
    /// It shows where a failed sign-in does, and goes the same way.
    static func signedOutMessage(_ reason: SignOutReason?) -> String? {
        reason == .sessionEnded ? "Your session ended. Sign in again." : nil
    }

    private var isGuest: Bool { bootstrap.guestSignIn }
    private var needsSetup: Bool { bootstrap.setup == .pending }

    private var canSubmit: Bool {
        guard !submission.isWorking, !needsSetup else { return false }
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
                    if submission.isWorking {
                        ProgressView()
                    } else {
                        Text("Sign In").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentFill)
            .disabled(!canSubmit)
            .padding(.top, 14)

            if !isGuest, let url = Self.passwordResetURL(client: client, bootstrap: bootstrap, email: email) {
                Link("Forgot Password?", destination: url)
                    .font(.footnote)
                    .disabled(submission.isWorking)
                    .padding(.top, 12)
            }
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
    }

    /// Correcting what failed is what clears the complaint about it. It's done as the field
    /// writes rather than by watching the string, which a burst of input changes several times
    /// a frame. A field also writes what it already holds, as when it takes focus: that corrects
    /// nothing, so it clears nothing.
    private func correcting(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { new in
                guard new != text.wrappedValue else { return }
                text.wrappedValue = new
                clearError()
            })
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
            if let error = submission.failure {
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
                    .disabled(submission.isWorking)
            }
            .font(.footnote)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .announcesWhenShown(submission.failure)
    }

    /// The web page that emails a code to reset a forgotten password, with the address typed so far,
    /// on a server that can send email; nil on one that can't, which has no such page.
    static func passwordResetURL(client: EmberClient, bootstrap: Bootstrap, email: String) -> URL? {
        guard bootstrap.passwordResetCodes, var components = client.url("/passwords/new").flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }) else { return nil }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            components.percentEncodedQueryItems = [URLQueryItem(
                name: "email_address",
                value: address.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))))]
        }
        return components.url
    }

    private func clearError() {
        submission.clearFailure()
    }

    private func submit() {
        guard canSubmit else { return }
        submission.begin()
        let isGuest = isGuest
        Task {
            do {
                if isGuest {
                    try await session.signIn(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    try await session.signIn(
                        emailAddress: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                }
                submission.finish()
            } catch {
                submission.fail((error as? EmberError)?.message ?? error.localizedDescription)
                if !isGuest { field = .password }
            }
        }
    }
}
