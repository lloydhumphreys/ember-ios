import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// Signing in with a pasted sign-in link, on the server screen and the sign-in screen, over
/// EmberTesting's mock transport: one stand-in server for each host.
@MainActor
@Suite struct SignInLinkTests {
    let one = URL(string: "https://one.example")!
    let two = URL(string: "https://two.example")!
    let transports = ["one.example": MockHTTPTransport(), "two.example": MockHTTPTransport()]
    let defaults: UserDefaults
    fileprivate let emptied = Emptied()

    nonisolated static let id = "tr_7f3a.Q-9_z"

    init() {
        let suite = "EmberTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for transport in transports.values {
            transport.stub("GET", "/api/bootstrap", json: Self.bootstrap)
        }
    }

    private func transport(_ origin: URL) -> MockHTTPTransport { transports[origin.host()!]! }

    private func controller() -> SessionController {
        let transports = transports
        let cookies = EphemeralCookieStorage()
        return SessionController(
            makeClient: { origin in
                EmberClient.mock(origin: origin, transport: transports[origin.host() ?? ""] ?? MockHTTPTransport(), cookies: cookies)
            },
            defaults: defaults, network: NetworkStatus(source: MockNetworkPath()), clock: ManualClock(),
            leftOnDevice: emptied.stores)
    }

    /// `origin`'s transfers sign in as `Fixtures.me` with `Self.id`, and answer anything else as the
    /// server answers a link that doesn't work: an empty 400.
    private func acceptLinks(on origin: URL) {
        transport(origin).stub("POST", "/api/session/transfers") { request in
            Self.transferID(in: request) == Self.id ? (201, Fixtures.meJSON()) : (400, "")
        }
    }

    private func link(_ origin: URL, id: String = Self.id) -> String {
        "\(origin.absoluteString)/session/transfers#token=\(id)"
    }

    @Test func aLinkOnTheServerScreenChoosesItsServerAndSignsIn() async throws {
        acceptLinks(on: two)
        let session = controller()
        await session.start()
        #expect(ServerView.isSignInLink(link(two)))
        #expect(!ServerView.isSignInLink("two.example"))

        try await session.useServer("  \(link(two))\n")

        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        #expect(workspace.client.origin == two)
        #expect(workspace.me.id == Fixtures.me.id)
        let transfers = transport(two).requests("POST", "/api/session/transfers")
        #expect(transfers.map(Self.transferID(in:)) == [Self.id])
        #expect(transport(two).requests("GET", "/api/bootstrap").count == 1)
        #expect(defaults.string(forKey: SessionController.originKey) == two.absoluteString)
        #expect(session.storedAccount == .init(origin: two, userID: Fixtures.me.id))
        workspace.shutdown()
    }

    @Test func aLinkForAnotherServerFromSignInSwitchesToItAndSignsIn() async throws {
        acceptLinks(on: two)
        let session = controller()
        await session.start()
        try await session.useServer(one.absoluteString)
        #expect(session.phase.origin == one)

        try await session.signIn(linkText: link(two))

        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        #expect(workspace.client.origin == two)
        #expect(transport(two).requests("POST", "/api/session/transfers").count == 1)
        #expect(transport(one).requests("POST", "/api/session/transfers").isEmpty)
        #expect(defaults.string(forKey: SessionController.originKey) == two.absoluteString)
        // The server it was on is let go, as Change Server lets it go.
        #expect(emptied.origins == [one])
        workspace.shutdown()
    }

    @Test func aLinkForTheServerOnScreenSignsInThereWithoutAskingItAgain() async throws {
        acceptLinks(on: one)
        let session = controller()
        await session.start()
        try await session.useServer(one.absoluteString)

        try await session.signIn(linkText: link(one))

        #expect(session.phase.workspace?.client.origin == one)
        #expect(transport(one).requests("GET", "/api/bootstrap").count == 1)
        #expect(emptied.origins.isEmpty)
        session.phase.workspace?.shutdown()
    }

    @Test func aLinkThatDoesNotWorkSaysSoAndLeavesTheScreenAsItWas() async throws {
        acceptLinks(on: one)
        acceptLinks(on: two)
        let session = controller()
        await session.start()
        try await session.useServer(one.absoluteString)

        let error = await #expect(throws: EmberError.self) {
            try await session.signIn(linkText: link(two, id: "spent"))
        }
        #expect(error?.message == "This sign-in link doesn’t work. It may have expired.")
        #expect(session.phase.origin == one)
        #expect(defaults.string(forKey: SessionController.originKey) == one.absoluteString)
        #expect(emptied.origins.isEmpty)

        let fromServerScreen = controller()
        fromServerScreen.forgetServer()
        let again = await #expect(throws: EmberError.self) {
            try await fromServerScreen.useServer(link(one, id: "spent"))
        }
        #expect(again?.message == "This sign-in link doesn’t work. It may have expired.")
        #expect(fromServerScreen.phase.origin == nil)
    }

    @Test func pastingSomethingElseIsNotALink() async throws {
        let session = controller()
        await session.start()
        try await session.useServer(one.absoluteString)

        for text in ["", "one.example", "\(one.absoluteString)/session/transfers", "ftp://one.example/session/transfers#token=\(Self.id)"] {
            let error = await #expect(throws: EmberError.self) { try await session.signIn(linkText: text) }
            #expect(error?.message == "That isn’t a sign-in link.")
        }
        #expect(transport(one).requests("POST", "/api/session/transfers").isEmpty)
    }

    @Test func aLinkOverPlainHTTPToAPublicHostIsRefusedBeforeAsking() async throws {
        let session = controller()
        await session.start()
        let error = await #expect(throws: EmberError.self) {
            try await session.useServer("http://two.example/session/transfers#token=\(Self.id)")
        }
        #expect(error?.message == "Use https:// for two.example.")
        #expect(transport(two).requests.isEmpty)
    }

    @Test func theLinksIDIsKeptNowhere() async throws {
        acceptLinks(on: two)
        let session = controller()
        await session.start()
        try await session.useServer(link(two))
        #expect(session.phase.workspace != nil)

        let kept = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        #expect(!kept.contains(Self.id))
        #expect(!String(describing: SignInLink(link(two))!).contains(Self.id))
        session.phase.workspace?.shutdown()
    }

    // MARK: Helpers

    /// The `transferId` a request carries.
    nonisolated static func transferID(in request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return fields["transferId"] as? String
    }

    nonisolated static let bootstrap = """
        {"setup":"complete","guestSignIn":false,"signInWithMemberful":false,"turnstileSiteKey":null,\
        "passwordResetCodes":true,"account":{"name":"Analytical"},"version":"test","user":null}
        """
}

/// Which servers' stores were emptied of no one in particular, as letting a server go empties them.
@MainActor private final class Emptied {
    private(set) var origins: [URL] = []
    private let names = LeftOnDevice.standard.stores.map(\.name)

    var stores: LeftOnDevice {
        LeftOnDevice(stores: names.prefix(1).map { name in
            LeftOnDevice.Store(name: name) { [weak self] origin, userID in
                if userID == nil { self?.origins.append(origin) }
            }
        })
    }
}

private extension SessionController.Phase {
    var workspace: Workspace? { if case .signedIn(let workspace) = self { workspace } else { nil } }
}
