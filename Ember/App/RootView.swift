import SwiftUI
import EmberSDK
import EmberRichText

/// The account on screen, and the sheet that adds another over it. Switching accounts makes the
/// whole of the new one's screens afresh, so nothing of the last one's is left on screen.
struct RootView: View {
    @Environment(Accounts.self) private var accounts
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        Group {
            if let slot = accounts.current {
                AccountScreen(session: slot.session)
                    .id(slot.id)
            } else {
                LaunchView()
            }
        }
        .sheet(item: adding) { slot in
            AddAccountView(session: slot.session)
                .environment(accounts)
                .environment(accounts.network)
                .preferredColorScheme(appearance.colorScheme)
        }
        .environment(accounts.network)
        .preferredColorScheme(appearance.colorScheme)
        .task { accounts.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accounts.unsentRemovals.retry() }
        }
    }

    /// The account being added; swiping the sheet away cancels it.
    private var adding: Binding<Accounts.Slot?> {
        Binding(
            get: { accounts.adding },
            set: { if $0 == nil { accounts.cancelAdding() } })
    }
}

/// Picks the screen for one account's phase. Every signed-in screen hangs off the `Workspace` put
/// in the environment here, so none of them handles a missing one.
private struct AccountScreen: View {
    let session: SessionController
    @Environment(Accounts.self) private var accounts

    var body: some View {
        content
            .opensSafeLinks(origin: session.phase.linkOrigin)
            .environment(session)
            .task { await session.start() }
    }

    @ViewBuilder
    private var content: some View {
        if case .signedIn(let workspace) = session.phase {
            SignedInView(workspace: workspace)
                // A new sign-in rebuilds every tab rather than reusing the last one's state.
                .id(ObjectIdentifier(workspace))
        } else if accounts.canLeave {
            // Another account is signed in: this one's sign-in can be left for it.
            NavigationStack {
                SignInFlow(session: session)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { Task { await accounts.leave() } }
                        }
                    }
            }
        } else {
            SignInFlow(session: session)
        }
    }
}

/// Another account's server and sign-in, over the account on screen, which stays signed in.
private struct AddAccountView: View {
    let session: SessionController
    @Environment(Accounts.self) private var accounts

    var body: some View {
        NavigationStack {
            SignInFlow(session: session)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { accounts.cancelAdding() }
                    }
                }
        }
        .opensSafeLinks(origin: session.phase.linkOrigin)
        .environment(session)
        .task { await session.start() }
    }
}

/// Choosing a server and signing in to it, for whichever account `session` is.
private struct SignInFlow: View {
    let session: SessionController

    var body: some View {
        switch session.phase {
        case .launching, .signedIn:
            LaunchView()
        case .needsServer:
            ServerView()
        case .signedOut(let client, let bootstrap):
            SignInView(client: client, bootstrap: bootstrap, reason: session.signOutReason)
                .id(client.origin)
        case .unreachable(let origin, let message):
            UnreachableView(origin: origin, message: message)
        }
    }
}

extension SessionController.Phase {
    /// The server a relative link is on, once there is one.
    @MainActor var linkOrigin: URL? {
        switch self {
        case .signedOut(let client, _): client.origin
        case .signedIn(let workspace): workspace.client.origin
        case .launching, .needsServer, .unreachable: nil
        }
    }
}

/// Where a tapped link goes, anywhere in the app: a link in a message, a card or a link preview, or a
/// file. Messages, cards and files are written by other people and bots, so only what `LinkPolicy`
/// opens reaches the system, and anything else does nothing.
enum LinkOpening {
    /// What to hand the system for `url`, or nil to drop it. A server-relative address, which message
    /// links already resolve before they get here, is resolved against `origin` first, as they are.
    static func destination(_ url: URL, origin: URL?) -> URL? {
        var resolved = url.absoluteURL
        if resolved.scheme == nil {
            guard let origin, let absolute = URL(string: url.relativeString, relativeTo: origin)?.absoluteURL else { return nil }
            resolved = absolute
        }
        return LinkPolicy.opens(resolved) ? resolved : nil
    }
}

/// The app's one `OpenURLAction`. `hand` stands in for the system in tests.
struct SafeLinks: ViewModifier {
    let origin: URL?
    var hand: (@MainActor (URL) -> Void)?

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard let destination = LinkOpening.destination(url, origin: origin) else { return .discarded }
            if let hand {
                hand(destination)
                return .handled
            }
            return .systemAction(destination)
        })
    }
}

extension View {
    func opensSafeLinks(origin: URL?) -> some View {
        modifier(SafeLinks(origin: origin))
    }
}

/// Home, with the workspace's socket open while the app is in front and closed in the
/// background.
private struct SignedInView: View {
    let workspace: Workspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(NetworkStatus.self) private var network

    var body: some View {
        HomeView()
            .environment(workspace)
            .task {
                await SidebarPhase.keepTrying(workspace, clock: ContinuousClock(), network: network)
            }
            .onAppear { if scenePhase != .background { workspace.start() } }
            // Switched to another account: this one's socket closes until it's back.
            .onDisappear { workspace.stop() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: workspace.start()
                case .background:
                    // What rooms hold unsent goes to disk with the time the system gives to finish,
                    // for a few seconds at most, so the time is always handed back.
                    let end = workspace.client.backgroundTime.begin("Saving unsent messages")
                    let flush = Task { try await workspace.flushUnsent() }
                    let limit = Task {
                        try await Task.sleep(for: .seconds(5))
                        flush.cancel()
                    }
                    Task {
                        _ = await flush.result
                        limit.cancel()
                        end()
                    }
                    workspace.stop()
                // Inactive is Control Centre or a call coming in: not worth reconnecting over.
                default: break
                }
            }
    }
}

private struct LaunchView: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
    }
}

private struct UnreachableView: View {
    let origin: URL
    let message: String
    @Environment(SessionController.self) private var session

    var body: some View {
        ContentUnavailableView {
            Label(ServerAddress.display(origin), systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await session.retry() }
            }
            .prominentButtonStyle()
            Button("Change Server") {
                session.forgetServer()
            }
        }
        .background(Color(.systemBackground))
    }
}
