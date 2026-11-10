import SwiftUI
import EmberSDK
import EmberRichText

/// Picks the screen for the session's phase. Every signed-in screen hangs off the `Workspace`
/// put in the environment here, so none of them handles a missing one.
struct RootView: View {
    @Environment(SessionController.self) private var session
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        content
            .opensSafeLinks(origin: origin)
            .preferredColorScheme(appearance.colorScheme)
            .task { await session.start() }
    }

    /// The server a relative link is on, once there is one.
    private var origin: URL? {
        switch session.phase {
        case .signedOut(let client, _): client.origin
        case .signedIn(let workspace): workspace.client.origin
        case .launching, .needsServer, .unreachable: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .launching:
            LaunchView()
        case .needsServer:
            ServerView()
        case .signedOut(let client, let bootstrap):
            SignInView(client: client, bootstrap: bootstrap)
                .id(client.origin)
        case .signedIn(let workspace):
            SignedInView(workspace: workspace)
                // A new sign-in rebuilds every tab rather than reusing the last one's state.
                .id(ObjectIdentifier(workspace))
        case .unreachable(let origin, let message):
            UnreachableView(origin: origin, message: message)
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

    var body: some View {
        HomeView()
            .environment(workspace)
            .onAppear { if scenePhase != .background { workspace.start() } }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: workspace.start()
                case .background: workspace.stop()
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
            .buttonStyle(.glassProminent)
            Button("Change Server") {
                session.forgetServer()
            }
        }
        .background(Color(.systemBackground))
    }
}
