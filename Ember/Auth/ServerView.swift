import SwiftUI
import EmberSDK

/// The first screen: which Ember server to use.
struct ServerView: View {
    @Environment(SessionController.self) private var session
    @State private var address = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    private var canContinue: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    /// Correcting the address is what clears the complaint about it. It's done as the field
    /// writes rather than by watching the string, which a burst of input changes several times
    /// a frame.
    private var correcting: Binding<String> {
        Binding(
            get: { address },
            set: { address = $0; if error != nil { error = nil } })
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

                if let error {
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
                    if isWorking {
                        ProgressView()
                    } else {
                        Text("Continue").font(.body.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
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
        isWorking = true
        error = nil
        Task {
            do {
                try await session.useServer(address)
            } catch {
                self.error = (error as? EmberError)?.message ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
