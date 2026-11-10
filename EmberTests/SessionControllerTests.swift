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

    private func controller(storingServer: Bool = true) -> SessionController {
        if storingServer { defaults.set(origin.absoluteString, forKey: SessionController.originKey) }
        let client = EmberClient.mock(origin: origin, transport: transport)
        return SessionController(makeClient: { _ in client }, defaults: defaults)
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

    /// Nonisolated: the transport's stubs call it from whichever thread it answers on.
    nonisolated private static func bootstrap(signedIn: Bool) -> String {
        let user = signedIn ? #"{"id":"u1","name":"Ada Lovelace","administrator":false}"# : "null"
        return """
        {"setup":"complete","guestSignIn":false,"signInWithMemberful":false,"turnstileSiteKey":null,\
        "passwordResetCodes":false,"account":{"name":"Analytical"},"version":"test","user":\(user)}
        """
    }
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
