import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// `SessionController` over EmberTesting's mock transport, with a throwaway `UserDefaults` suite
/// standing in for the remembered server.
@MainActor
@Suite struct SessionControllerTests {
    let origin = URL(string: "https://ember.test")!
    let transport = MockHTTPTransport()
    let defaults: UserDefaults

    init() {
        let suite = "EmberTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    let clock = ManualClock()
    let path = MockNetworkPath()

    fileprivate let emptied = EmptiedStores()

    private func controller(storingServer: Bool = true) -> SessionController {
        if storingServer { defaults.set(origin.absoluteString, forKey: SessionController.originKey) }
        let client = EmberClient.mock(origin: origin, transport: transport)
        return SessionController(makeClient: { _ in client }, defaults: defaults,
                                 network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
    }

    /// A controller whose every server answers its bootstrap from `answeredFrom`, as URLSession
    /// reports a redirect it followed.
    private func controller(redirectedTo answeredFrom: String, storing stored: String? = nil) -> SessionController {
        if let stored { defaults.set(stored, forKey: SessionController.originKey) }
        let transport = Redirecting(to: answeredFrom, json: Self.bootstrap(signedIn: false))
        return SessionController(
            makeClient: { EmberClient(origin: $0, environment: .mock(transport: transport, cookies: EphemeralCookieStorage())) },
            defaults: defaults, network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
    }

    @Test func noServerStoredNeedsOne() async {
        let session = controller(storingServer: false)
        await session.start()
        #expect(session.phase.isNeedsServer)
    }

    @Test func aBootstrapWithSomeoneIsSignedIn() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: true))
        let session = controller()
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        #expect(workspace.me.name == "Ada Lovelace")
        #expect(workspace.account.name == "Analytical")
    }

    @Test func aRefusedSignInThrowsAndStaysSignedOut() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        transport.stub("POST", "/api/session", status: 401, json: #"{"error":"Incorrect email or password. Please try again."}"#)
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedOut)

        await #expect(throws: EmberError.self) {
            try await session.signIn(emailAddress: "ada@example.com", password: "wrong")
        }
        #expect(session.phase.isSignedOut)
    }

    @Test func signingOutReturnsToSignIn() async {
        let signedOut = Flag()
        transport.stub("GET", "/api/bootstrap") { _ in
            (200, Self.bootstrap(signedIn: !signedOut.isSet))
        }
        transport.stub("DELETE", "/api/session") { _ in
            signedOut.set()
            return (204, "{}")
        }
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedIn)

        await session.signOut()
        #expect(session.phase.isSignedOut)
        #expect(transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/session" })
    }

    @Test func aServerThatDoesNotAnswerIsUnreachable() async {
        transport.stub("GET", "/api/bootstrap") { _ in throw URLError(.cannotConnectToHost) }
        let session = controller()
        await session.start()
        guard case .unreachable(let unreachable, _) = session.phase else {
            Issue.record("Expected unreachable, got \(session.phase)")
            return
        }
        #expect(unreachable == origin)
    }

    @Test func choosingAServerRemembersIt() async throws {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        let session = controller(storingServer: false)
        await session.start()
        try await session.useServer("ember.test")
        #expect(session.phase.isSignedOut)
        #expect(defaults.string(forKey: SessionController.originKey) == origin.absoluteString)

        session.forgetServer()
        #expect(session.phase.isNeedsServer)
        #expect(defaults.string(forKey: SessionController.originKey) == nil)
    }

    // MARK: Late answers
    //
    // Each holds a request at the transport, does something else while it's out, then lets it
    // through, so the late answer always lands second.

    @Test func forgettingTheServerDuringLaunchKeepsItForgotten() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: true))
        let gate = transport.hold("GET", "/api/bootstrap")
        let session = controller()
        let launch = Task { await session.start() }
        await gate.waitForRequest()

        session.forgetServer()
        gate.release()
        await launch.value

        #expect(session.phase.isNeedsServer)
        #expect(defaults.string(forKey: SessionController.originKey) == nil)
    }

    @Test func aServerAnsweringAfterChangeServerIsNotRemembered() async throws {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        let session = controller(storingServer: false)
        await session.start()
        let gate = transport.hold("GET", "/api/bootstrap")
        let choosing = Task { try await session.useServer("ember.test") }
        await gate.waitForRequest()

        session.forgetServer()
        gate.release()
        try await choosing.value

        #expect(session.phase.isNeedsServer)
        #expect(defaults.string(forKey: SessionController.originKey) == nil)
    }

    @Test func retryingTwiceAsksOnce() async {
        transport.stub("GET", "/api/bootstrap") { _ in throw URLError(.cannotConnectToHost) }
        let session = controller()
        await session.start()
        guard case .unreachable = session.phase else {
            Issue.record("Expected unreachable, got \(session.phase)")
            return
        }

        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        let gate = transport.hold("GET", "/api/bootstrap")
        let first = Task { await session.retry() }
        await gate.waitForRequest()

        await session.retry()
        gate.release()
        await first.value

        #expect(session.phase.isSignedOut)
        // The launch's, then the first retry's: the second tap sent nothing.
        #expect(transport.requests("GET", "/api/bootstrap").count == 2)
    }

    // MARK: Trying again by itself

    @Test func anUnreachableServerIsAskedAgainAfterWaitsThatDouble() async {
        let down = Switch(true)
        transport.stub("GET", "/api/bootstrap") { _ in
            if down.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Self.bootstrap(signedIn: false))
        }
        let session = controller()
        await session.start()
        #expect(await eventually { clock.sleeperCount == 1 })

        clock.advance(by: .seconds(2))
        #expect(await eventually { transport.requests("GET", "/api/bootstrap").count == 2 })
        #expect(await eventually { clock.sleeperCount == 1 })
        guard case .unreachable = session.phase else {
            Issue.record("Expected unreachable between tries, got \(session.phase)")
            return
        }

        down.set(false)
        clock.advance(by: .seconds(2))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(transport.requests("GET", "/api/bootstrap").count == 2)
        clock.advance(by: .seconds(2))
        #expect(await eventually { session.phase.isSignedOut })
        #expect(transport.requests("GET", "/api/bootstrap").count == 3)
    }

    @Test func anUnreachableServerIsAskedAgainAsSoonAsTheNetworkComesBack() async {
        let down = Switch(true)
        transport.stub("GET", "/api/bootstrap") { _ in
            if down.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Self.bootstrap(signedIn: false))
        }
        let session = controller()
        path.set(available: false)
        #expect(await eventually { !session.network.isOnline })
        await session.start()
        #expect(await eventually { clock.sleeperCount == 1 })

        down.set(false)
        path.set(available: true)
        #expect(await eventually { session.phase.isSignedOut })
        #expect(transport.requests("GET", "/api/bootstrap").count == 2)
    }

    @Test func anUnreachableServerOffScreenIsAskedAgainOnlyOnceItsBack() async {
        let down = Switch(true)
        transport.stub("GET", "/api/bootstrap") { _ in
            if down.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Self.bootstrap(signedIn: false))
        }
        let session = controller()
        await session.start()
        #expect(await eventually { clock.sleeperCount == 1 })

        session.pause()
        #expect(await eventually { clock.sleeperCount == 0 })
        down.set(false)
        path.set(available: false)
        path.set(available: true)
        clock.advance(by: .seconds(120))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(transport.requests("GET", "/api/bootstrap").count == 1)
        guard case .unreachable = session.phase else {
            Issue.record("Expected unreachable, got \(session.phase)")
            return
        }

        session.resume()
        #expect(await eventually { session.phase.isSignedOut })
        #expect(transport.requests("GET", "/api/bootstrap").count == 2)
    }

    @Test func changingServerStopsTryingTheOldOne() async {
        transport.stub("GET", "/api/bootstrap") { _ in throw URLError(.notConnectedToInternet) }
        let session = controller()
        await session.start()
        #expect(await eventually { clock.sleeperCount == 1 })

        session.forgetServer()
        #expect(await eventually { clock.sleeperCount == 0 })
        clock.advance(by: .seconds(120))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.phase.isNeedsServer)
        #expect(transport.requests("GET", "/api/bootstrap").count == 1)
    }

    @Test func aSecondSignOutWhileOneIsOutDoesNothing() async {
        let signedOut = Flag()
        transport.stub("GET", "/api/bootstrap") { _ in
            (200, Self.bootstrap(signedIn: !signedOut.isSet))
        }
        transport.stub("DELETE", "/api/session") { _ in
            signedOut.set()
            return (204, "{}")
        }
        let session = controller()
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        let gate = transport.hold("DELETE", "/api/session")
        let first = Task { await session.signOut() }
        await gate.waitForRequest()

        // What a revoked session's `onSignedOut` would do; signing out has already cleared it.
        #expect(workspace.onSignedOut == nil)
        await session.signOut()
        gate.release()
        await first.value

        #expect(session.phase.isSignedOut)
        #expect(transport.requests("DELETE", "/api/session").count == 1)
        #expect(transport.requests("GET", "/api/bootstrap").count == 2)
    }

    @Test func aSignInAnsweringAfterChangeServerIsDropped() async throws {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        transport.stub("POST", "/api/session", status: 201, json: Fixtures.meJSON())
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedOut)
        let gate = transport.hold("POST", "/api/session")
        let signingIn = Task { try await session.signIn(emailAddress: "ada@example.com", password: "test") }
        await gate.waitForRequest()

        session.forgetServer()
        gate.release()
        try await signingIn.value

        #expect(session.phase.isNeedsServer)
    }

    // MARK: Where the server is

    @Test func aServerThatRedirectsIsRememberedWhereItAnswered() async throws {
        let session = controller(redirectedTo: "https://chat.ember.test")
        await session.start()
        try await session.useServer("ember.test")
        #expect(session.phase.isSignedOut)
        #expect(session.phase.origin == URL(string: "https://chat.ember.test")!)
        #expect(defaults.string(forKey: SessionController.originKey) == "https://chat.ember.test")
    }

    @Test func aRememberedServerThatHasMovedIsRememberedWhereItIsNow() async {
        let session = controller(redirectedTo: "https://chat.ember.test", storing: "https://ember.test")
        await session.start()
        #expect(session.phase.isSignedOut)
        #expect(session.phase.origin == URL(string: "https://chat.ember.test")!)
        #expect(defaults.string(forKey: SessionController.originKey) == "https://chat.ember.test")
    }

    @Test func aPublicServerOverPlainHTTPIsTurnedAwayWithoutAskingIt() async {
        let session = controller(storingServer: false)
        await session.start()
        await #expect {
            try await session.useServer("http://example.com")
        } throws: { error in
            (error as? EmberError)?.message == "Use https:// for example.com."
        }
        #expect(session.phase.isNeedsServer)
        #expect(transport.requests.isEmpty)
        #expect(defaults.string(forKey: SessionController.originKey) == nil)
    }

    // MARK: What's left on the device

    @Test func signingOutEmptiesEveryStoreAndSaysNothingOnSignIn() async {
        let signedOut = Flag()
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: !signedOut.isSet)) }
        transport.stub("DELETE", "/api/session") { _ in
            signedOut.set()
            return (204, "{}")
        }
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedIn)
        #expect(emptied.log.isEmpty)

        await session.signOut()
        #expect(session.phase.isSignedOut)
        #expect(emptied.everyStoreEmptied(once: origin))
        guard case .signedOut(let client, _) = session.phase else { return }
        #expect(client.signOutReason == .userInitiated)
        #expect(session.signOutReason == .userInitiated)
        #expect(SignInView.signedOutMessage(session.signOutReason) == nil)
    }

    @Test func aSessionTheServerEndsEmptiesEveryStoreAndSaysSoUntilTheNextSignIn() async throws {
        let ended = Flag()
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: !ended.isSet)) }
        transport.stub("GET", "/api/me") { _ in
            ended.set()
            return (401, #"{"error":"Not signed in."}"#)
        }
        transport.stub("DELETE", "/api/session", status: 204, json: "{}")
        transport.stub("POST", "/api/session", status: 201, json: Fixtures.meJSON())
        let session = controller()
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }

        _ = try? await workspace.client.me()
        #expect(await eventually { session.phase.isSignedOut })
        #expect(emptied.everyStoreEmptied(once: origin))
        guard case .signedOut(let client, _) = session.phase else { return }
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")

        try await session.signIn(emailAddress: "ada@example.com", password: "test")
        #expect(client.signOutReason == nil)
        #expect(session.signOutReason == nil)
        if case .signedIn(let workspace) = session.phase { workspace.shutdown() }
    }

    @Test func forgettingTheServerEmptiesEveryStore() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        let session = controller()
        await session.start()
        session.forgetServer()
        #expect(session.phase.isNeedsServer)
        #expect(emptied.everyStoreEmptied(once: origin, userID: nil))
    }

    // MARK: Who was signed in

    private func remember(_ userID: UserID) {
        defaults.set(["origin": origin.absoluteString, "userID": userID.rawValue], forKey: SessionController.accountKey)
    }

    @Test func signingInRemembersWhoAndSigningOutForgetsThem() async throws {
        let signedIn = Switch(false)
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: signedIn.isOn)) }
        transport.stub("POST", "/api/session") { _ in
            signedIn.set(true)
            return (201, Fixtures.meJSON())
        }
        transport.stub("DELETE", "/api/session", status: 204, json: "{}")
        let session = controller()
        await session.start()
        #expect(session.storedAccount == nil)

        try await session.signIn(emailAddress: "ada@example.com", password: "test")
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        #expect(session.storedAccount == .init(origin: origin, userID: workspace.me.id))
        #expect(defaults.dictionary(forKey: SessionController.accountKey) as? [String: String] == ["origin": "https://ember.test", "userID": "user_ada"])

        signedIn.set(false)
        await session.signOut()
        #expect(session.storedAccount == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionARoomSocketFindsEndedSaysSoOnSignIn() async {
        let ended = Switch(false)
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: !ended.isOn)) }
        transport.stub("DELETE", "/api/session", status: 204, json: "{}")
        let connector = MockSocketConnector()
        connector.onConnect { connection in
            guard connection.request.url?.path != "/api/socket" else { return }
            ended.set(true)
            connection.serverCloses(code: 4003) // revoked: the session is gone
        }
        defaults.set(origin.absoluteString, forKey: SessionController.originKey)
        let client = EmberClient.mock(origin: origin, transport: transport, connector: connector)
        let session = SessionController(makeClient: { _ in client }, defaults: defaults,
                                        network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }

        workspace.start()
        workspace.session(for: "room-general").start()
        #expect(await eventually { session.phase.isSignedOut })
        #expect(emptied.everyStoreEmptied(once: origin))
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionThatEndedWhileTheAppWasClosedIsEmptiedOnLaunch() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: false))
        remember("u1")
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedOut)
        #expect(emptied.everyStoreEmptied(once: origin, userID: "u1"))
        #expect(session.storedAccount == nil)
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")
    }

    /// What a server stopped and started again fresh does to an open room: both connections drop,
    /// their retries find nobody there, then the server is back and refuses each upgrade 401, the
    /// live connection's check of `/api/me` is refused too, and the bootstrap names nobody. Every
    /// client is a new one, as the app's are.
    @Test(.timeLimit(.minutes(1)))
    func aServerThatRestartsAndForgetsTheSessionSaysItEndedOnSignIn() async {
        let restarted = Switch(false)
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: !restarted.isOn)) }
        transport.stub("GET", "/api/me") { _ in
            restarted.isOn ? (401, #"{"error":"Not signed in"}"#) : (200, Fixtures.meJSON())
        }
        transport.stub("DELETE", "/api/session", status: 204, json: "{}")
        let connector = MockSocketConnector()
        let tries = Tally()
        connector.onConnect { connection in
            // Two that drop as the server goes, four that find nothing there, then the new server.
            if tries.next() > 6 { restarted.set(true) }
            connection.serverCloses(httpStatus: restarted.isOn ? 401 : nil)
        }
        defaults.set(origin.absoluteString, forKey: SessionController.originKey)
        let cookies = EphemeralCookieStorage()
        // The SDK's waits between tries, short enough for every retry to run here.
        let timing = EmberTiming(backoffBase: .milliseconds(1), backoffMax: .milliseconds(5))
        let session = SessionController(
            makeClient: { EmberClient.mock(origin: $0, transport: transport, connector: connector, cookies: cookies, timing: timing) },
            defaults: defaults, network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }

        workspace.start()
        workspace.session(for: "room-general").start()
        #expect(await eventually { session.phase.isSignedOut })
        #expect(emptied.everyStoreEmptied(once: origin))
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")
    }

    /// The server ends the session, then can't be reached for the bootstrap that follows: the retry
    /// that finds it again asks with a new client, which never saw the session end.
    @Test(.timeLimit(.minutes(1)))
    func aSessionThatEndsJustAsTheServerGoesSaysSoOnceItAnswers() async {
        let ended = Switch(false)
        let down = Switch(false)
        transport.stub("GET", "/api/bootstrap") { _ in
            if down.isOn { throw URLError(.cannotConnectToHost) }
            return (200, Self.bootstrap(signedIn: !ended.isOn))
        }
        transport.stub("GET", "/api/me") { _ in
            ended.set(true)
            down.set(true)
            return (401, #"{"error":"Not signed in"}"#)
        }
        transport.stub("DELETE", "/api/session") { _ in throw URLError(.cannotConnectToHost) }
        defaults.set(origin.absoluteString, forKey: SessionController.originKey)
        let cookies = EphemeralCookieStorage()
        let session = SessionController(
            makeClient: { EmberClient.mock(origin: $0, transport: transport, cookies: cookies) },
            defaults: defaults, network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
        await session.start()
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }

        _ = try? await workspace.client.me()
        #expect(await eventually { clock.sleeperCount == 1 })
        guard case .unreachable = session.phase else {
            Issue.record("Expected unreachable, got \(session.phase)")
            return
        }
        down.set(false)
        clock.advance(by: .seconds(2))
        #expect(await eventually { session.phase.isSignedOut })
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")
    }

    /// Launched while the server was down, then it's back without the session: the remembered
    /// person's session ended while the app was away.
    @Test(.timeLimit(.minutes(1)))
    func aServerBackWithoutTheSessionAfterLaunchingUnreachableSaysItEnded() async {
        let down = Switch(true)
        transport.stub("GET", "/api/bootstrap") { _ in
            if down.isOn { throw URLError(.cannotConnectToHost) }
            return (200, Self.bootstrap(signedIn: false))
        }
        remember("u1")
        defaults.set(origin.absoluteString, forKey: SessionController.originKey)
        let cookies = EphemeralCookieStorage()
        let session = SessionController(
            makeClient: { EmberClient.mock(origin: $0, transport: transport, cookies: cookies) },
            defaults: defaults, network: NetworkStatus(source: path), clock: clock, leftOnDevice: emptied.stores)
        await session.start()
        #expect(await eventually { clock.sleeperCount == 1 })

        down.set(false)
        clock.advance(by: .seconds(2))
        #expect(await eventually { session.phase.isSignedOut })
        #expect(emptied.everyStoreEmptied(once: origin, userID: "u1"))
        #expect(SignInView.signedOutMessage(session.signOutReason) == "Your session ended. Sign in again.")
    }

    @Test(.timeLimit(.minutes(1)))
    func signingOutWhenAskedSaysNothingOnSignIn() async {
        let signedOut = Switch(false)
        transport.stub("GET", "/api/bootstrap") { _ in (200, Self.bootstrap(signedIn: !signedOut.isOn)) }
        transport.stub("DELETE", "/api/session") { _ in
            signedOut.set(true)
            return (204, "{}")
        }
        remember("u1")
        let session = controller()
        await session.start()
        await session.signOut()
        #expect(session.phase.isSignedOut)
        #expect(session.signOutReason == .userInitiated)
        #expect(SignInView.signedOutMessage(session.signOutReason) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func someoneElseSignedInOnLaunchEmptiesWhatTheLastPersonLeft() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: true))
        remember("u2")
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedIn)
        #expect(emptied.everyStoreEmptied(once: origin, userID: "u2"))
        #expect(session.storedAccount == .init(origin: origin, userID: "u1"))
        if case .signedIn(let workspace) = session.phase { workspace.shutdown() }
    }

    @Test(.timeLimit(.minutes(1)))
    func theSamePersonStillSignedInOnLaunchKeepsEverything() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: true))
        remember("u1")
        let session = controller()
        await session.start()
        #expect(session.phase.isSignedIn)
        #expect(emptied.log.isEmpty)
        #expect(session.storedAccount == .init(origin: origin, userID: "u1"))
        if case .signedIn(let workspace) = session.phase { workspace.shutdown() }
    }

    @Test(.timeLimit(.minutes(1)))
    func changingServerWhileItIsUnreachableEmptiesEverythingTheRememberedPersonLeft() async {
        transport.stub("GET", "/api/bootstrap") { _ in throw URLError(.notConnectedToInternet) }
        remember("u1")
        let session = controller()
        await session.start()
        guard case .unreachable = session.phase else {
            Issue.record("Expected unreachable, got \(session.phase)")
            return
        }
        #expect(emptied.log.isEmpty)

        session.forgetServer()
        #expect(session.phase.isNeedsServer)
        #expect(emptied.everyStoreEmptied(once: origin, userID: "u1"))
        #expect(session.storedAccount == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func changingServerWhileSignedInForgetsWhoWasSignedIn() async {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(signedIn: true))
        let session = controller()
        await session.start()
        #expect(session.storedAccount == .init(origin: origin, userID: "u1"))

        session.forgetServer()
        #expect(emptied.everyStoreEmptied(once: origin, userID: "u1"))
        #expect(session.storedAccount == nil)
    }

    @Test func everyStoreLeftOnTheDeviceIsOnTheList() {
        #expect(LeftOnDevice.standard.stores.map(\.name) == [
            "Drafts", "Unsent messages", "Messages and downloaded files", "Pictures in messages", "Pictures on cards",
            "Picture sizes", "Staged thumbnails", "Avatars", "Unfolded messages", "Changes that failed",
            "People and room lists", "Where you were",
        ])
    }

    @Test func theUnsentMessagesStoreForgetsOnlyThatAccountsMessages() async throws {
        let unsent = MemoryUnsentMessageStore()
        let message = UnsentMessage(clientMessageId: "c1", body: "Hello", plainText: "Hello", createdAt: .now)
        let mine = UnsentMessageKey(server: origin, userID: "u1", roomID: "r1")
        let theirs = UnsentMessageKey(server: origin, userID: "u2", roomID: "r1")
        let elsewhere = UnsentMessageKey(server: URL(string: "https://ember.testing")!, userID: "u1", roomID: "r1")
        for key in [mine, theirs, elsewhere] { try unsent.save([message], for: key) }
        let store = LeftOnDevice.standard(unsent: unsent, defaults: defaults).stores.first { $0.name == "Unsent messages" }

        store?.empty(origin, nil)
        #expect(unsent.saved.count == 3)
        store?.empty(origin, "u1")
        #expect(await eventually { Set(unsent.saved.keys) == [theirs, elsewhere] })
        #expect(await eventually { defaults.data(forKey: UnsentRemovals.key) == nil })
    }

    @Test func theAppsUnsentMessagesAreInTheSDKsSharedStore() {
        #expect(Accounts(defaults: defaults).unsentRemovals.unsent === FileUnsentMessageStore.shared)
        #expect(EmberClient(origin: origin).unsentStore === FileUnsentMessageStore.shared)
    }

    @Test func aRemovalOfUnsentMessagesThatFailsIsKeptAndTriedAgain() async throws {
        let unsent = MemoryUnsentMessageStore()
        let message = UnsentMessage(clientMessageId: "c1", body: "Hello", plainText: "Hello", createdAt: .now)
        let mine = UnsentMessageKey(server: origin, userID: "u1", roomID: "r1")
        try unsent.save([message], for: mine)
        unsent.failsRemovals = true
        let removals = UnsentRemovals(unsent: unsent, defaults: defaults)

        removals.remove(server: origin, userID: "u1")
        await removals.settled()
        #expect(removals.owed == [.init(server: origin, userID: "u1")])
        #expect(unsent.saved[mine] != nil)
        // Noted where the next launch finds it.
        #expect(UnsentRemovals(unsent: unsent, defaults: defaults).owed == removals.owed)

        removals.retry()
        await removals.settled()
        #expect(removals.owed.count == 1)

        unsent.failsRemovals = false
        removals.retry()
        await removals.settled()
        #expect(removals.owed.isEmpty)
        #expect(unsent.saved.isEmpty)
    }

    /// Nonisolated: the transport's stubs call it from whichever thread it answers on.
    nonisolated private static func bootstrap(signedIn: Bool) -> String {
        let user = signedIn ? #"{"id":"u1","name":"Ada Lovelace","administrator":false}"# : "null"
        return """
        {"setup":"complete","guestSignIn":false,"signInWithMemberful":false,"turnstileSiteKey":null,\
        "passwordResetCodes":false,"account":{"name":"Analytical"},"version":"test","user":\(user)}
        """
    }
}

/// A stand-in for each of `LeftOnDevice.standard`'s stores, noting each time one is emptied.
@MainActor private final class EmptiedStores {
    private(set) var log: [(name: String, origin: URL, userID: UserID?)] = []
    private let names = LeftOnDevice.standard.stores.map(\.name)

    var stores: LeftOnDevice {
        LeftOnDevice(stores: names.map { name in
            LeftOnDevice.Store(name: name) { [weak self] origin, userID in self?.log.append((name, origin, userID)) }
        })
    }

    /// Whether every store was emptied exactly once, each for `origin` and `userID`.
    func everyStoreEmptied(once origin: URL, userID: UserID? = "u1") -> Bool {
        log.map(\.name) == names && log.allSatisfy { $0.origin == origin && $0.userID == userID }
    }
}

/// Answers every bootstrap from `origin`, as URLSession reports a request it followed a redirect
/// to answer.
private struct Redirecting: HTTPTransport {
    let origin: String
    let json: String

    init(to origin: String, json: String) {
        self.origin = origin
        self.json = json
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? "/"
        let url = URL(string: origin + path)!
        guard path == "/api/bootstrap" else {
            return (Data(#"{"error":"Not found."}"#.utf8), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let headers = ["Content-Type": "application/json"]
        return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }
}

/// Counts socket tries from whichever thread the connector runs its script on.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A switch a stub can flip and another can read, from whichever thread the transport answers on.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private extension SessionController.Phase {
    var isNeedsServer: Bool { if case .needsServer = self { true } else { false } }
    var isSignedOut: Bool { if case .signedOut = self { true } else { false } }
    var isSignedIn: Bool { if case .signedIn = self { true } else { false } }
}
