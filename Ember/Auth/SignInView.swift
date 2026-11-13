import SwiftUI
import EmberSDK

/// Signing in to the chosen server: an email address and password, or just a name where the
/// server allows guests, with the server's host and a way back to choose another.
///
/// A server that hasn't been set up has no one to sign in as, and setting it up happens in the
/// browser, so that case gets a link there instead of the form.
///
/// A sign-in link can be pasted instead, for this server or another, and a forgotten password reset
/// here, where the server emails codes and doesn't ask for Turnstile's check, which an app can't
/// make; otherwise on the web.
struct SignInView: View {
    let client: EmberClient
    let bootstrap: Bootstrap

    @Environment(SessionController.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var submission: Submission
    @FocusState private var field: Field?
    /// The sign-in link being pasted, only until it's used or put away: its id lets anyone in.
    @State private var link = ""
    @State private var isAskingForLink = false
    @State private var isResettingPassword = false
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

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
        .alert("Use a Sign-In Link", isPresented: $isAskingForLink) {
            TextField("Sign-in link", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { link = "" }
            Button("Sign In", action: useLink)
        }
        .sheet(isPresented: $isResettingPassword) {
            NavigationStack {
                PasswordResetView(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) { address in
                    // The password changed, but this person signs in another way: back to sign in.
                    email = address
                    password = ""
                    isResettingPassword = false
                    field = .password
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isResettingPassword = false }
                    }
                }
            }
            .environment(session)
            .preferredColorScheme(appearance.colorScheme)
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

            if !isGuest {
                switch Self.passwordReset(client: client, bootstrap: bootstrap, email: email) {
                case .inApp:
                    Button("Forgot Password?") { isResettingPassword = true }
                        .font(.footnote)
                        .disabled(submission.isWorking)
                        .padding(.top, 12)
                case .web(let url):
                    Link("Forgot Password?", destination: url)
                        .font(.footnote)
                        .disabled(submission.isWorking)
                        .padding(.top, 12)
                case nil:
                    EmptyView()
                }

                Button("Use a Sign-In Link") {
                    link = ""
                    isAskingForLink = true
                }
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

    /// Where "Forgot Password?" goes.
    enum PasswordReset: Equatable {
        /// `PasswordResetView`, in the app.
        case inApp
        /// The web's page, as `passwordResetURL` makes it.
        case web(URL)
    }

    /// Resetting in the app on a server that emails codes without asking for Turnstile's check; the
    /// web page on one that asks for it, which only a browser can make; nil on one that can't send
    /// email at all, which has nothing to offer.
    static func passwordReset(client: EmberClient, bootstrap: Bootstrap, email: String) -> PasswordReset? {
        guard let url = passwordResetURL(client: client, bootstrap: bootstrap, email: email) else { return nil }
        return bootstrap.turnstileSiteKey == nil ? .inApp : .web(url)
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

    /// Signs in with the pasted link, on whichever server it's for. The field is emptied first,
    /// whether or not the link works.
    private func useLink() {
        let typed = link
        link = ""
        guard !submission.isWorking, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submission.begin()
        Task {
            do {
                try await session.signIn(linkText: typed)
                submission.finish()
            } catch {
                submission.fail((error as? EmberError)?.message ?? error.localizedDescription)
            }
        }
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
