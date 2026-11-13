import SwiftUI
import EmberSDK

/// The first screen: which Ember server to use. A sign-in link pasted in place of its address
/// signs in there too.
///
/// What's typed is only ever in this view's state: it isn't remembered, restored or autocorrected,
/// so a link's id goes when the field is cleared.
struct ServerView: View {
    @Environment(SessionController.self) private var session
    @State private var address = ""
    @State private var submission = Submission.idle
    @FocusState private var isFocused: Bool

    private var canContinue: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !submission.isWorking
    }

    /// Correcting the address is what clears the complaint about it. It's done as the field
    /// writes rather than by watching the string, which a burst of input changes several times
    /// a frame.
    private var correcting: Binding<String> {
        Binding(
            get: { address },
            set: { address = $0; submission.clearFailure() })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                EmberMark()
                    .padding(.top, 48)
                    .padding(.bottom, 20)

                Text("Connect to Ember")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)

                form
                    .padding(.horizontal, 24)

                if let error = submission.failure {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity)
        }
        // Scrolling reaches what the largest text sizes or the keyboard push off screen. It
        // bounces even when everything fits, so dragging down always takes the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .announcesWhenShown(submission.failure)
        .onAppear { isFocused = true }
    }

    private var form: some View {
        VStack(spacing: 0) {
            TextField("Server address", text: correcting)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($isFocused)
                .onSubmit(submit)
                .padding(.vertical, 12)

            Button(action: submit) {
                Group {
                    if submission.isWorking {
                        ProgressView()
                    } else {
                        Text("Continue").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentFill)
            .disabled(!canContinue)
            .padding(.top, 14)
        }
        .textFieldStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
    }

    private func submit() {
        guard canContinue else { return }
        submission.begin()
        let typed = address
        // A sign-in link's id lets anyone in, so it's gone from the field once it's been used,
        // whether or not it worked.
        if Self.isSignInLink(typed) { address = "" }
        Task {
            do {
                try await session.useServer(typed)
                submission.finish()
            } catch {
                submission.fail((error as? EmberError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Whether `typed` is a sign-in link, which `SessionController.useServer` signs in with rather
    /// than only choosing its server.
    static func isSignInLink(_ typed: String) -> Bool {
        SignInLink(typed) != nil
    }
}
