import SwiftUI
import Observation
import EmberSDK

/// Where the first sidebar is, as Home and Activity show it.
enum SidebarPhase: Equatable {
    case loading
    /// Nothing has loaded yet, and the first load didn't arrive or the server refused the
    /// workspace's connection.
    case failed
    /// The sidebar has loaded. It stays on screen when the connection is refused afterwards, with
    /// the connection indicator showing.
    case loaded

    @MainActor init(_ workspace: Workspace) {
        if workspace.isLoaded {
            self = .loaded
        } else if workspace.loadError != nil || Self.isRefused(workspace) {
            self = .failed
        } else {
            self = .loading
        }
    }

    /// Keeps the workspace trying for as long as it's on screen: the sidebar asked for again while
    /// nothing has loaded, and a refused connection started again, each after a wait that doubles
    /// with every try in a row, or at once when the network comes back. The waits start again from
    /// the shortest once the sidebar has loaded and the connection is open. Returns when cancelled.
    @MainActor static func keepTrying(_ workspace: Workspace, clock: any Clock<Duration>, network: NetworkStatus) async {
        var attempt = 0
        while !Task.isCancelled {
            if needsTrying(workspace) {
                await Retrying.wait(attempt: attempt, clock: clock, network: network)
                guard !Task.isCancelled else { return }
                attempt += 1
                await retry(workspace)
            } else {
                if workspace.isLoaded, workspace.connection == .open { attempt = 0 }
                await nextChange(of: workspace)
            }
        }
    }

    /// Whether there's something to try again: a first sidebar that didn't arrive, or a refused
    /// connection.
    @MainActor static func needsTrying(_ workspace: Workspace) -> Bool {
        isRefused(workspace) || (!workspace.isLoaded && workspace.loadError != nil)
    }

    /// Whether the server refused the workspace's connection: it stays closed until it's started
    /// again. Signing out is handled apart, and goes back to sign-in.
    @MainActor static func isRefused(_ workspace: Workspace) -> Bool {
        guard case .stopped(let reason) = workspace.connection else { return false }
        return reason != .signedOut
    }

    /// What Retry does: the connection started again when it was refused, and the sidebar asked for.
    @MainActor static func retry(_ workspace: Workspace) async {
        if isRefused(workspace) {
            workspace.stop()
            workspace.start()
        }
        await workspace.reload()
    }

    /// Returns once anything `needsTrying` reads has changed, or when cancelled.
    @MainActor private static func nextChange(of workspace: Workspace) async {
        let waiter = ChangeWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                withObservationTracking {
                    _ = workspace.isLoaded
                    _ = workspace.loadError
                    _ = workspace.connection
                } onChange: {
                    Task { @MainActor in waiter.resume() }
                }
                if Task.isCancelled { waiter.resume() }
            }
        } onCancel: {
            Task { @MainActor in waiter.resume() }
        }
    }

    /// One wait for a change, answered once by whichever comes first.
    @MainActor private final class ChangeWaiter {
        var continuation: CheckedContinuation<Void, Never>?

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}

/// A list that needs the sidebar: a spinner until it arrives, and a way to ask again if it fails.
struct SidebarGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(Workspace.self) private var workspace
    @State private var isRetrying = false

    var body: some View {
        switch SidebarPhase(workspace) {
        case .loaded:
            content()
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry") {
                    isRetrying = true
                    Task {
                        await SidebarPhase.retry(workspace)
                        isRetrying = false
                    }
                }
                .disabled(isRetrying)
            }
            // Said as it shows, rather than when the phase changes, so a tab that isn't on screen
            // doesn't say it too.
            .onAppear { AccessibilityNotification.Announcement("Couldn’t Load").post() }
        }
    }
}
