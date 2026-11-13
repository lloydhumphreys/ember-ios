import Foundation
import Observation
import EmberSDK

/// Which server, and whether anyone's signed in to it: one account's, of the ones `Accounts` holds.
///
/// The server's origin is remembered in `defaults`, under `keys`. Whether the session is still good
/// is the session cookie the client keeps, so a launch asks the server's bootstrap; who it was for
/// is remembered only so what they left can be emptied when it isn't.
@MainActor @Observable final class SessionController {
    enum Phase {
        case launching
        /// No server chosen yet.
        case needsServer
        case signedOut(client: EmberClient, bootstrap: Bootstrap)
        case signedIn(Workspace)
        /// A chosen server didn't answer.
        case unreachable(origin: URL, message: String)
    }

    /// Where the chosen server's origin is kept in `defaults`.
    nonisolated static let originKey = "serverOrigin"
    /// Where who's signed in is kept in `defaults`, so what they left can be emptied when their
    /// session ends while the app isn't running.
    nonisolated static let accountKey = "signedInAccount"

    /// Someone signed in to a server: all that's kept of them in `defaults`.
    struct SignedInAccount: Equatable {
        let origin: URL
        let userID: UserID
    }

    /// Where one account's server and who's signed in to it are kept in `defaults`.
    struct Keys: Equatable {
        let origin: String
        let account: String

        /// Where the app kept them before it held more than one account.
        static let unshared = Keys(origin: SessionController.originKey, account: SessionController.accountKey)

        /// The account `id`'s.
        static func account(_ id: String) -> Keys {
            Keys(origin: "account.\(id).serverOrigin", account: "account.\(id).signedInAccount")
        }
    }

    private(set) var phase: Phase = .launching

    /// Why `.signedOut` is showing, for sign-in to say: the person asked, or their session ended.
    /// Kept here rather than read from the client, since the client that finds the server again
    /// after it was unreachable, or at launch, is a new one that never saw the session end.
    private(set) var signOutReason: SignOutReason?

    @ObservationIgnored private let makeClient: @MainActor (URL) -> EmberClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let keys: Keys
    @ObservationIgnored private var hasStarted = false
    /// Bumped by everything that changes `phase`, and read again when its answer arrives: an
    /// answer whose generation has moved on (Change Server tapped while a bootstrap was out, a
    /// second sign-out) is dropped rather than overwriting what's on screen now.
    @ObservationIgnored private var generation = 0
    /// The next try at an unreachable server, waiting on `clock` or the network coming back.
    @ObservationIgnored private var retrying: Task<Void, Never>?
    /// How many tries in a row have found the server unreachable.
    @ObservationIgnored private var unreachableAttempts = 0
    /// Whether this account is off screen, so an unreachable server isn't asked again.
    @ObservationIgnored private var paused = false
    @ObservationIgnored private let clock: any Clock<Duration>
    /// What's emptied when someone signs out, the server ends their session, or the server is
    /// forgotten.
    @ObservationIgnored private let leftOnDevice: LeftOnDevice
    /// Why the last sign-out happened, until sign-in shows: carried past a bootstrap that finds the
    /// server unreachable, whose retry asks with a new client.
    @ObservationIgnored private var lastSignOut: SignOutReason?

    /// Told of each workspace as someone signs in, or is found signed in.
    @ObservationIgnored var onSignedIn: (@MainActor (Workspace) -> Void)?

    /// Whether the device is online, for every screen to read.
    let network: NetworkStatus

    /// `makeClient`, `defaults`, `network`, `clock` and `leftOnDevice` are parameters so tests can
    /// pass EmberTesting's mock client, a network they switch by hand, a clock they move by hand and
    /// stores they can look into.
    init(
        makeClient: @escaping @MainActor (URL) -> EmberClient = { EmberClient(origin: $0) },
        defaults: UserDefaults = .standard,
        keys: Keys = .unshared,
        network: NetworkStatus? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        leftOnDevice: LeftOnDevice? = nil
    ) {
        self.makeClient = makeClient
        self.defaults = defaults
        self.keys = keys
        self.network = network ?? NetworkStatus()
        self.clock = clock
        self.leftOnDevice = leftOnDevice ?? .standard
    }

    /// The remembered server's origin, if there is one.
    var storedOrigin: URL? {
        defaults.string(forKey: keys.origin).flatMap(URL.init(string:))
    }

    /// Who was signed in when last seen, until they sign out or the server is forgotten.
    var storedAccount: SignedInAccount? {
        guard let stored = defaults.dictionary(forKey: keys.account) as? [String: String],
              let origin = stored["origin"].flatMap(URL.init(string:)), let userID = stored["userID"]
        else { return nil }
        return SignedInAccount(origin: origin, userID: UserID(userID))
    }

    private func remember(_ account: SignedInAccount?) {
        if let account {
            defaults.set(["origin": account.origin.absoluteString, "userID": account.userID.rawValue], forKey: keys.account)
        } else {
            defaults.removeObject(forKey: keys.account)
        }
    }

    /// A client for `origin` with this account's cookies.
    func client(for origin: URL) -> EmberClient {
        makeClient(origin)
    }

    /// Once, from RootView's `.task`: a second call, as a view coming back would make, does nothing.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let current = nextGeneration()
        guard let origin = storedOrigin else {
            phase = .needsServer
            return
        }
        await connect(to: makeClient(origin), generation: current)
    }

    /// From `.unreachable`: asks the same server again. It's also asked by itself, sooner as the
    /// network comes back and later the longer it stays away, without leaving the screen.
    func retry() async {
        guard case .unreachable(let origin, _) = phase else { return }
        retrying?.cancel()
        let current = nextGeneration()
        // Out of `.unreachable` at once, so a second tap finds nothing to retry.
        phase = .launching
        await connect(to: makeClient(origin), generation: current)
    }

    /// Throws an `EmberError` for an address that isn't one, plain http to a public host, or a
    /// server that doesn't answer like Ember. On success, remembers the server where it answered
    /// from, after any redirect, and moves to `.signedOut` or `.signedIn`.
    ///
    /// A sign-in link typed in place of an address is its server and a sign-in at once, as
    /// `signIn(link:)` uses it.
    func useServer(_ typed: String) async throws {
        if let link = SignInLink(typed) {
            try await signIn(link: link)
            return
        }
        guard let origin = ServerAddress.origin(from: typed) else {
            throw EmberError(status: 0, message: "That isn’t a server address.", field: "address")
        }
        try Self.requireHTTPS(origin)
        let current = nextGeneration()
        stopRetrying()
        lastSignOut = nil
        guard let (client, bootstrap) = try await check(origin, generation: current) else { return }
        defaults.set(client.origin.absoluteString, forKey: keys.origin)
        enter(client, bootstrap)
    }

    /// `typed` as a sign-in link, signed in with as `signIn(link:)` does; an `EmberError` with field
    /// `"link"` when it isn't one.
    func signIn(linkText typed: String) async throws {
        guard let link = SignInLink(typed) else {
            throw EmberError(status: 0, message: "That isn’t a sign-in link.", field: "link")
        }
        try await signIn(link: link)
    }

    /// Signs in with a sign-in link, on its server: the one on screen, or another, checked as
    /// `useServer` checks one. Nothing changes until it works, so a link that doesn't leaves the
    /// screen it was pasted on as it was, with the error to show there. Once it works, the link's
    /// server is this account's, and one it replaces is let go as Change Server lets it go.
    ///
    /// The link's id is sent and nowhere else: it isn't kept here or in `defaults`.
    func signIn(link: SignInLink) async throws {
        switch phase {
        case .needsServer, .signedOut: break
        case .launching, .signedIn, .unreachable: return
        }
        try Self.requireHTTPS(link.origin)
        let current = nextGeneration()
        stopRetrying()
        let replacing = phase.origin
        let client: EmberClient
        let bootstrap: Bootstrap
        if case .signedOut(let shown, let shownBootstrap) = phase, shown.origin == link.origin {
            (client, bootstrap) = (shown, shownBootstrap)
        } else {
            guard let checked = try await check(link.origin, generation: current) else { return }
            (client, bootstrap) = checked
        }
        let me = try await answer(bootstrap) { try await client.signIn(transferID: link.transferID) }
        guard current == generation else { return }
        if let replacing, replacing != client.origin {
            leftOnDevice.empty(for: replacing, userID: nil)
            makeClient(replacing).forgetCookies()
        }
        lastSignOut = nil
        defaults.set(client.origin.absoluteString, forKey: keys.origin)
        signedIn(client, me: me, account: bootstrap.account)
    }

    /// Back to `.needsServer`, forgetting the remembered one, everything left from it on the device,
    /// and the session cookie, whether or not the server could be reached to say so.
    func forgetServer() {
        nextGeneration()
        stopRetrying()
        var account = storedAccount
        if case .signedIn(let workspace) = phase {
            end(workspace)
            account = SignedInAccount(origin: workspace.client.origin, userID: workspace.me.id)
        }
        let origin = phase.origin ?? storedOrigin
        if let account {
            leftOnDevice.empty(for: account.origin, userID: account.userID)
            makeClient(account.origin).forgetCookies()
        }
        if let origin, origin != account?.origin {
            leftOnDevice.empty(for: origin, userID: nil)
            makeClient(origin).forgetCookies()
        }
        remember(nil)
        defaults.removeObject(forKey: keys.origin)
        lastSignOut = nil
        signOutReason = nil
        phase = .needsServer
    }

    func signIn(emailAddress: String, password: String) async throws {
        guard case .signedOut(let client, let bootstrap) = phase else { return }
        let current = nextGeneration()
        let me = try await answer(bootstrap) {
            try await client.signIn(emailAddress: emailAddress, password: password)
        }
        guard current == generation else { return }
        signedIn(client, me: me, account: bootstrap.account)
    }

    func signIn(name: String) async throws {
        guard case .signedOut(let client, let bootstrap) = phase else { return }
        let current = nextGeneration()
        let me = try await answer(bootstrap) { try await client.signIn(name: name) }
        guard current == generation else { return }
        signedIn(client, me: me, account: bootstrap.account)
    }

    /// Asks the server on screen to email a code for a new password to `emailAddress`. It answers
    /// the same whether or not anyone has it.
    func askForPasswordReset(emailAddress: String) async throws {
        guard case .signedOut(let client, _) = phase else { return }
        try await Self.readably { try await client.askForPasswordReset(emailAddress: emailAddress) }
    }

    /// Gives whoever has `emailAddress` `newPassword`, with the code they were emailed. True when
    /// that signed them in, as signing in with a password does; false when the password changed but
    /// they sign in another way, and must do that next.
    @discardableResult
    func resetPassword(emailAddress: String, code: String, newPassword: String) async throws -> Bool {
        guard case .signedOut(let client, let bootstrap) = phase else { return false }
        let current = nextGeneration()
        let me = try await Self.readably {
            try await client.resetPassword(emailAddress: emailAddress, code: code, newPassword: newPassword)
        }
        guard current == generation, let me else { return false }
        signedIn(client, me: me, account: bootstrap.account)
        return true
    }

    /// Ends the session on the server and here, then shows sign-in for the same server. Also what
    /// happens when the server says the session's gone. A second call while one is on its way
    /// finds the phase already `.launching` and does nothing.
    func signOut() async {
        guard case .signedIn(let workspace) = phase else { return }
        let current = nextGeneration()
        end(workspace)
        let client = workspace.client
        leftOnDevice.empty(for: client.origin, userID: workspace.me.id)
        remember(nil)
        phase = .launching
        await client.signOut()
        guard current == generation else { return }
        lastSignOut = client.signOutReason
        await connect(to: client, generation: current)
    }

    /// Lets this account go, as it's removed from the device: the session is ended on the server,
    /// which ends only this one, and nothing here is remembered any more. `emptying` empties what
    /// the person left, as signing out does; a second sign-in as someone another account already
    /// is leaves it, since it's theirs there too.
    func leave(emptying: Bool) async {
        nextGeneration()
        stopRetrying()
        var account = storedAccount
        var client: EmberClient?
        if case .signedIn(let workspace) = phase {
            end(workspace)
            client = workspace.client
            account = SignedInAccount(origin: workspace.client.origin, userID: workspace.me.id)
        }
        if emptying, let account {
            leftOnDevice.empty(for: account.origin, userID: account.userID)
        }
        remember(nil)
        defaults.removeObject(forKey: keys.origin)
        lastSignOut = nil
        signOutReason = nil
        phase = .launching
        await client?.signOut()
    }

    /// Asks the server again with the cookies kept now, as when another sign-in has handed this
    /// account a fresh session. Already signed in, it stays as it is.
    func reconnect(to origin: URL) async {
        if case .signedIn = phase { return }
        hasStarted = true
        let current = nextGeneration()
        stopRetrying()
        lastSignOut = nil
        defaults.set(origin.absoluteString, forKey: keys.origin)
        phase = .launching
        await connect(to: makeClient(origin), generation: current)
    }

    /// Ends whatever this session was doing for good, as when an account being added is cancelled.
    func close() {
        nextGeneration()
        stopRetrying()
        if case .signedIn(let workspace) = phase { end(workspace) }
        phase = .launching
    }

    /// Off screen, an unreachable server isn't asked again until `resume`.
    func pause() {
        paused = true
        stopRetrying()
    }

    /// Back on screen: an unreachable server is asked again at once.
    func resume() {
        paused = false
        if case .unreachable = phase {
            Task { await retry() }
        }
    }

    // MARK: Private

    @discardableResult
    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    /// A workspace done with for good: nothing it was loading lands afterwards, and its
    /// revoked-session callback can't start another sign-out.
    private func end(_ workspace: Workspace) {
        workspace.onSignedOut = nil
        workspace.shutdown()
    }

    /// Fetches the bootstrap and moves to what it says, unless something else has changed the
    /// phase since `generation` was taken.
    private func connect(to client: EmberClient, generation current: Int) async {
        do {
            let check = try await client.checkServer()
            guard current == generation else { return }
            var client = client
            if check.origin != client.origin {
                // The server has moved since it was chosen: it's remembered where it is now.
                client = makeClient(check.origin)
                defaults.set(client.origin.absoluteString, forKey: keys.origin)
            }
            enter(client, check.bootstrap)
        } catch {
            guard current == generation else { return }
            phase = .unreachable(origin: client.origin, message: Self.message(for: error))
            retryLater()
        }
    }

    /// Asks again after a wait that doubles each time, or at once when the network comes back.
    /// While it's out, the unreachable screen stays as it is.
    private func retryLater() {
        retrying?.cancel()
        guard !paused else { return }
        let attempt = unreachableAttempts
        unreachableAttempts += 1
        retrying = Task { [weak self, clock, network] in
            await Retrying.wait(attempt: attempt, clock: clock, network: network)
            guard !Task.isCancelled, let self, case .unreachable(let origin, _) = self.phase else { return }
            let current = self.nextGeneration()
            await self.connect(to: self.makeClient(origin), generation: current)
        }
    }

    private func stopRetrying() {
        retrying?.cancel()
        retrying = nil
        unreachableAttempts = 0
    }

    /// Signed in when the bootstrap names someone, as it does while the session cookie is good.
    /// Whoever was remembered as signed in, when the bootstrap names nobody or someone else, had
    /// their session end while the app wasn't watching: what they left is emptied first, and
    /// sign-in says the session ended.
    private func enter(_ client: EmberClient, _ bootstrap: Bootstrap) {
        stopRetrying()
        var reason = lastSignOut ?? client.signOutReason
        lastSignOut = nil
        if let gone = storedAccount, gone.userID != bootstrap.user?.id {
            leftOnDevice.empty(for: gone.origin, userID: gone.userID)
            remember(nil)
            reason = reason ?? .sessionEnded
        }
        if let me = bootstrap.user {
            signedIn(client, me: me, account: bootstrap.account)
        } else {
            signOutReason = reason
            phase = .signedOut(client: client, bootstrap: bootstrap)
        }
    }

    private func signedIn(_ client: EmberClient, me: Me, account: Account) {
        remember(SignedInAccount(origin: client.origin, userID: me.id))
        lastSignOut = nil
        signOutReason = nil
        let workspace = Workspace(client: client, me: me, account: account)
        // Set here rather than by a view, so no workspace exists without it: a revoked session
        // always comes back to sign-in.
        workspace.onSignedOut = { [weak self] in
            Task { await self?.signOut() }
        }
        phase = .signedIn(workspace)
        onSignedIn?(workspace)
    }

    /// A sign-in's answer, with what the server refused as an `EmberError`. Anything else means it
    /// answered in a way the SDK can't read: on a Memberful workspace, the 202 that starts
    /// connecting a Memberful account in the browser, which the app can't do.
    private func answer(_ bootstrap: Bootstrap, _ signIn: () async throws -> Me) async throws -> Me {
        do {
            return try await signIn()
        } catch let error as EmberError {
            throw error
        } catch {
            throw EmberError(
                status: 0,
                message: bootstrap.signInWithMemberful
                    ? "Signing in with Memberful isn’t available in the app."
                    : "Something went wrong. Try again.")
        }
    }

    /// `work`'s answer, with anything that isn't an `EmberError` made one there's a message for.
    private static func readably<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as EmberError {
            throw error
        } catch {
            throw EmberError(status: 0, message: "Something went wrong. Try again.")
        }
    }

    /// The system wouldn't send plain http to a public host, so asking would only fail as unreachable.
    private static func requireHTTPS(_ origin: URL) throws {
        guard !ServerAddress.needsHTTPS(origin) else {
            throw EmberError(status: 0, message: "Use https:// for \(ServerAddress.display(origin)).", field: "address")
        }
    }

    /// A client for the server at `origin`, where it answered from after any redirect, and its
    /// bootstrap; nil when `generation` has moved on by the time it answers. Throws an `EmberError`
    /// for a server that doesn't answer, or doesn't answer like Ember.
    private func check(_ origin: URL, generation current: Int) async throws -> (EmberClient, Bootstrap)? {
        var client = makeClient(origin)
        do {
            let check = try await client.checkServer()
            guard current == generation else { return nil }
            if check.origin != client.origin { client = makeClient(check.origin) }
            return (client, check.bootstrap)
        } catch {
            // Nobody's waiting on a stale answer, so there's no error to show either.
            guard current == generation else { return nil }
            if let error = error as? EmberError, error.isUnreachable {
                throw EmberError(status: 0, message: "Couldn’t reach \(ServerAddress.display(origin)).", field: "address")
            }
            // It answered, but not with a bootstrap: a web page, a 404, some other API.
            let status = (error as? EmberError)?.status ?? 0
            throw EmberError(status: status, message: "\(ServerAddress.display(origin)) isn’t an Ember server.", field: "address")
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? EmberError)?.message ?? error.localizedDescription
    }
}

extension SessionController.Phase {
    /// The server on screen, once one has been chosen.
    @MainActor var origin: URL? {
        switch self {
        case .signedOut(let client, _): client.origin
        case .signedIn(let workspace): workspace.client.origin
        case .unreachable(let origin, _): origin
        case .launching, .needsServer: nil
        }
    }
}
