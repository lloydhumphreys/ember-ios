import SwiftUI
import EmberSDK

/// A form field on the password reset screens, named as `EmberError.field` names it.
enum PasswordResetField: String, Hashable {
    case emailAddress, code, password
}

/// A refusal on the password reset screens: against the field the server named, when that field is
/// on the screen, and under the form otherwise, as a 429, a 503 or no answer at all are.
struct PasswordResetFailure: Equatable {
    var field: PasswordResetField?
    var message: String

    /// `error` on a screen with `fields`.
    init(_ error: any Error, fields: Set<PasswordResetField>) {
        let ember = error as? EmberError
        message = ember?.message ?? error.localizedDescription
        field = ember?.field.flatMap(PasswordResetField.init(rawValue:)).flatMap { fields.contains($0) ? $0 : nil }
    }

    init(field: PasswordResetField?, message: String) {
        self.field = field
        self.message = message
    }

    /// The message to show against `field`, or under the form for nil.
    func message(for field: PasswordResetField?) -> String? {
        self.field == field ? message : nil
    }
}

/// The address as it's sent: without the spaces around it.
private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Resetting a forgotten password in the app, on a server that emails codes and doesn't ask for
/// Turnstile's check: an email address to email a code to, then the code with a new password.
/// Someone who already has a code goes straight on to giving it.
///
/// A new password that signs in carries on as signing in does, taking this screen away with
/// sign-in's; one that doesn't hands the address to `onPasswordChanged`, to sign in with.
struct PasswordResetView: View {
    let onPasswordChanged: (String) -> Void

    @Environment(SessionController.self) private var session
    @State private var email: String
    @State private var isWorking = false
    @State private var failure: PasswordResetFailure?
    /// The address a code was asked for, or is held for, which the code step is for.
    @State private var asked: String?
    @FocusState private var isFocused: Bool

    init(email: String, onPasswordChanged: @escaping (String) -> Void) {
        _email = State(initialValue: email)
        self.onPasswordChanged = onPasswordChanged
    }

    private var canSend: Bool { !trimmed(email).isEmpty && !isWorking }

    /// A code as it's typed or pasted, kept to its digits, so one pasted with spaces in it works.
    static func code(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmberMark()
                    .padding(.top, 48)
                    .padding(.bottom, 20)

                Text("Reset Password")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                form
                    .padding(.horizontal, 24)

                if let message = failure?.message(for: nil) {
                    FormFailure(message: message)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .announcesWhenShown(failure?.message)
        .onAppear { isFocused = true }
        .navigationDestination(item: $asked) { address in
            NewPasswordView(email: address, onPasswordChanged: onPasswordChanged)
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            TextField("Email", text: Binding(
                get: { email },
                set: { new in
                    guard new != email else { return }
                    email = new
                    failure = nil
                }))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.vertical, 12)

            if let message = failure?.message(for: .emailAddress) {
                FieldFailure(message: message)
            }

            ProminentButton("Send Code", isWorking: isWorking, action: send)
                .disabled(!canSend)
                .padding(.top, 14)

            Button("Enter Code") {
                failure = nil
                asked = trimmed(email)
            }
            .font(.footnote)
            .disabled(trimmed(email).isEmpty || isWorking)
            .padding(.top, 12)
        }
        .authCard()
    }

    private func send() {
        guard canSend else { return }
        let address = trimmed(email)
        isWorking = true
        failure = nil
        Task {
            do {
                try await session.askForPasswordReset(emailAddress: address)
                asked = address
            } catch {
                failure = PasswordResetFailure(error, fields: [.emailAddress])
                isFocused = true
            }
            isWorking = false
        }
    }
}

/// The code emailed to `email`, with a new password.
private struct NewPasswordView: View {
    let email: String
    let onPasswordChanged: (String) -> Void

    @Environment(SessionController.self) private var session
    @State private var code = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var isAskingAgain = false
    /// Whether another code was just sent, which the button says until it can be asked for again.
    @State private var sentAgain = false
    @State private var failure: PasswordResetFailure?
    @FocusState private var field: PasswordResetField?

    private static let fields: Set<PasswordResetField> = [.emailAddress, .code, .password]

    private var canReset: Bool { !code.isEmpty && !password.isEmpty && !isWorking && !isAskingAgain }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmberMark()
                    .padding(.top, 48)
                    .padding(.bottom, 20)

                Text("Check Your Email")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                form
                    .padding(.horizontal, 24)

                if let message = failure?.message(for: nil) {
                    FormFailure(message: message)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .announcesWhenShown(failure?.message)
        .task {
            // Once the push has finished: focus asked for as it slides in is dropped.
            try? await Task.sleep(for: FocusTiming.afterPresenting)
            if field == nil { field = .code }
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            // Shown so AutoFill saves the new password for this address, and so it's plain which
            // address the code went to. It's changed by going back.
            TextField("Email", text: .constant(email))
                .textContentType(.username)
                .disabled(true)
                .padding(.vertical, 12)

            if let message = failure?.message(for: .emailAddress) {
                FieldFailure(message: message)
            }

            Divider()

            TextField("Code", text: correcting($code, digitsOnly: true))
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($field, equals: .code)
                .padding(.vertical, 12)

            if let message = failure?.message(for: .code) {
                FieldFailure(message: message)
            }

            Divider()

            SecureField("New Password", text: correcting($password))
                .textContentType(.newPassword)
                .submitLabel(.go)
                .focused($field, equals: .password)
                .onSubmit(reset)
                .padding(.vertical, 12)

            if let message = failure?.message(for: .password) {
                FieldFailure(message: message)
            }

            ProminentButton("Reset Password", isWorking: isWorking, action: reset)
                .disabled(!canReset)
                .padding(.top, 14)

            Button(sentAgain ? "Code Sent" : "Send Another Code", action: askAgain)
                .font(.footnote)
                .disabled(isWorking || isAskingAgain || sentAgain)
                .padding(.top, 12)
        }
        .authCard()
    }

    /// Correcting a field is what clears the complaint, as on sign-in. The code keeps only its
    /// digits.
    private func correcting(_ text: Binding<String>, digitsOnly: Bool = false) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { new in
                let new = digitsOnly ? PasswordResetView.code(new) : new
                guard new != text.wrappedValue else { return }
                text.wrappedValue = new
                failure = nil
            })
    }

    private func reset() {
        guard canReset else { return }
        isWorking = true
        failure = nil
        let (email, code, password) = (email, code, password)
        Task {
            do {
                if try await !session.resetPassword(emailAddress: email, code: code, newPassword: password) {
                    onPasswordChanged(email)
                }
            } catch {
                let failure = PasswordResetFailure(error, fields: Self.fields)
                self.failure = failure
                switch failure.field {
                case .password: field = .password
                case .code: field = .code
                case .emailAddress, nil: break
                }
            }
            isWorking = false
        }
    }

    private func askAgain() {
        guard !isWorking, !isAskingAgain else { return }
        isAskingAgain = true
        failure = nil
        Task {
            do {
                try await session.askForPasswordReset(emailAddress: email)
                code = ""
                sentAgain = true
                field = .code
            } catch {
                failure = PasswordResetFailure(error, fields: [.emailAddress])
            }
            isAskingAgain = false
            if sentAgain {
                try? await Task.sleep(for: .seconds(30))
                sentAgain = false
            }
        }
    }
}

// MARK: Shared with sign-in's look

/// A message against the field above it, in the card.
private struct FieldFailure: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
    }
}

/// A message about the whole form, under the card, where sign-in shows its own.
private struct FormFailure: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 24)
    }
}

/// The card's full-width prominent button, as sign-in's, with a spinner while it works.
private struct ProminentButton: View {
    let title: String
    let isWorking: Bool
    let action: () -> Void

    init(_ title: String, isWorking: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView()
                } else {
                    Text(title).font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentFill)
        .accessibilityLabel(title)
    }
}

private extension View {
    /// Fields stacked on a rounded card, as on the server and sign-in screens.
    func authCard() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
    }
}
