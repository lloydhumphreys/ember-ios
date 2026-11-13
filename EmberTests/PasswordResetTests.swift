import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// Resetting a forgotten password in the app, over EmberTesting's mock transport.
@MainActor
@Suite struct PasswordResetTests {
    let origin = URL(string: "https://ember.test")!
    let transport = MockHTTPTransport()
    let defaults: UserDefaults

    init() {
        let suite = "EmberTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    /// A controller showing sign-in for `origin`.
    private func signedOut(turnstile: Bool = false, codes: Bool = true) async throws -> SessionController {
        transport.stub("GET", "/api/bootstrap", json: Self.bootstrap(turnstile: turnstile, codes: codes))
        let client = EmberClient.mock(origin: origin, transport: transport)
        let session = SessionController(
            makeClient: { _ in client }, defaults: defaults,
            network: NetworkStatus(source: MockNetworkPath()), clock: ManualClock(),
            leftOnDevice: LeftOnDevice(stores: []))
        await session.start()
        try await session.useServer(origin.absoluteString)
        return session
    }

    // MARK: Which way "Forgot Password?" goes

    @Test func aServerThatEmailsCodesWithoutTurnstileResetsInTheApp() throws {
        let client = EmberClient.mock(origin: origin)
        #expect(SignInView.passwordReset(client: client, bootstrap: try Self.decoded(turnstile: false, codes: true), email: "") == .inApp)
    }

    @Test func aServerAskingForTurnstileStillResetsOnTheWeb() throws {
        let client = EmberClient.mock(origin: origin)
        let bootstrap = try Self.decoded(turnstile: true, codes: true)
        #expect(SignInView.passwordReset(client: client, bootstrap: bootstrap, email: "ada@example.com")
            == .web(URL(string: "https://ember.test/passwords/new?email_address=ada%40example.com")!))
    }

    @Test func aServerThatCannotSendEmailOffersNoReset() throws {
        let client = EmberClient.mock(origin: origin)
        #expect(SignInView.passwordReset(client: client, bootstrap: try Self.decoded(turnstile: false, codes: false), email: "") == nil)
        #expect(SignInView.passwordReset(client: client, bootstrap: try Self.decoded(turnstile: true, codes: false), email: "") == nil)
    }

    // MARK: The two requests

    @Test func askingForACodeSendsTheAddress() async throws {
        transport.stub("POST", "/api/password_resets", status: 202, json: "{}")
        let session = try await signedOut()

        try await session.askForPasswordReset(emailAddress: "ada@example.com")

        let asked = transport.requests("POST", "/api/password_resets")
        #expect(asked.count == 1)
        #expect(Self.fields(of: asked.first) == ["emailAddress": "ada@example.com"])
        #expect(session.phase.isSignedOut)
    }

    @Test func aNewPasswordThatSignsInCarriesOnAsSigningInDoes() async throws {
        transport.stub("PUT", "/api/password_resets", status: 201, json: Fixtures.meJSON())
        let session = try await signedOut()

        let signedIn = try await session.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "a new password")

        #expect(signedIn)
        let reset = transport.requests("PUT", "/api/password_resets")
        #expect(Self.fields(of: reset.first) == ["emailAddress": "ada@example.com", "code": "12345678", "password": "a new password"])
        guard case .signedIn(let workspace) = session.phase else {
            Issue.record("Expected signed in, got \(session.phase)")
            return
        }
        #expect(workspace.me.id == Fixtures.me.id)
        #expect(session.storedAccount == .init(origin: origin, userID: Fixtures.me.id))
        workspace.shutdown()
    }

    @Test func aNewPasswordForSomeoneWhoSignsInAnotherWayGoesBackToSignIn() async throws {
        transport.stub("PUT", "/api/password_resets", json: #"{"user":null}"#)
        let session = try await signedOut()

        let signedIn = try await session.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "a new password")

        #expect(!signedIn)
        #expect(session.phase.isSignedOut)
        #expect(session.storedAccount == nil)
    }

    // MARK: Refusals

    @Test func aWrongCodeIsAgainstTheCodeField() async throws {
        transport.stub("PUT", "/api/password_resets", status: 422, json: #"{"error":"That code doesn’t work.","field":"code"}"#)
        let session = try await signedOut()

        let failure = await refusal(fields: [.emailAddress, .code, .password]) {
            try await session.resetPassword(emailAddress: "ada@example.com", code: "00000000", newPassword: "a new password")
        }
        #expect(failure == PasswordResetFailure(field: .code, message: "That code doesn’t work."))
        #expect(failure?.message(for: .code) == "That code doesn’t work.")
        #expect(failure?.message(for: nil) == nil)
        #expect(session.phase.isSignedOut)
    }

    @Test func aPasswordTooShortIsAgainstThePasswordField() async throws {
        transport.stub("PUT", "/api/password_resets", status: 422, json: #"{"error":"Use at least 8 characters.","field":"password"}"#)
        let session = try await signedOut()

        let failure = await refusal(fields: [.emailAddress, .code, .password]) {
            try await session.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "short")
        }
        #expect(failure == PasswordResetFailure(field: .password, message: "Use at least 8 characters."))
    }

    @Test func aBadAddressIsAgainstTheEmailField() async throws {
        transport.stub("POST", "/api/password_resets", status: 422, json: #"{"error":"Enter an email address.","field":"emailAddress"}"#)
        let session = try await signedOut()

        let failure = await refusal(fields: [.emailAddress]) {
            try await session.askForPasswordReset(emailAddress: "ada")
        }
        #expect(failure == PasswordResetFailure(field: .emailAddress, message: "Enter an email address."))
    }

    @Test func tooManyTriesAndNoEmailAreAboutTheWholeForm() async throws {
        let session = try await signedOut()

        transport.stub("POST", "/api/password_resets", status: 429, json: #"{"error":"Too many codes asked for. Try again later."}"#)
        let limited = await refusal(fields: [.emailAddress]) { try await session.askForPasswordReset(emailAddress: "ada@example.com") }
        #expect(limited == PasswordResetFailure(field: nil, message: "Too many codes asked for. Try again later."))

        transport.stub("POST", "/api/password_resets", status: 503, json: #"{"error":"Ember can’t email codes right now."}"#)
        let unsendable = await refusal(fields: [.emailAddress]) { try await session.askForPasswordReset(emailAddress: "ada@example.com") }
        #expect(unsendable == PasswordResetFailure(field: nil, message: "Ember can’t email codes right now."))

        transport.stub("PUT", "/api/password_resets", status: 429, json: #"{"error":"Too many tries. Ask for another code."}"#)
        let tries = await refusal(fields: [.emailAddress, .code, .password]) {
            try await session.resetPassword(emailAddress: "ada@example.com", code: "12345678", newPassword: "a new password")
        }
        #expect(tries == PasswordResetFailure(field: nil, message: "Too many tries. Ask for another code."))
    }

    @Test func aFieldNotOnTheScreenIsAboutTheWholeForm() {
        let turnstile = EmberError(status: 422, message: "Couldn’t check you’re not a robot.", field: "turnstile")
        #expect(PasswordResetFailure(turnstile, fields: [.emailAddress]).field == nil)
        let code = EmberError(status: 422, message: "That code doesn’t work.", field: "code")
        #expect(PasswordResetFailure(code, fields: [.emailAddress]).field == nil)
    }

    @Test func aCodeKeepsOnlyItsDigits() {
        #expect(PasswordResetView.code("1234 5678") == "12345678")
        #expect(PasswordResetView.code(" 12-34\n") == "1234")
        #expect(PasswordResetView.code("١٢٣") == "")
    }

    // MARK: Helpers

    /// What `work` was refused with, as a screen with `fields` shows it.
    private func refusal(fields: Set<PasswordResetField>, _ work: () async throws -> some Any) async -> PasswordResetFailure? {
        do {
            _ = try await work()
            Issue.record("Expected a refusal")
            return nil
        } catch {
            return PasswordResetFailure(error, fields: fields)
        }
    }

    private static func fields(of request: URLRequest?) -> [String: String]? {
        guard let body = request?.httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: String]
    }

    private static func decoded(turnstile: Bool, codes: Bool) throws -> Bootstrap {
        try EmberJSON.decoder().decode(Bootstrap.self, from: Data(bootstrap(turnstile: turnstile, codes: codes).utf8))
    }

    nonisolated private static func bootstrap(turnstile: Bool, codes: Bool) -> String {
        """
        {"setup":"complete","guestSignIn":false,"signInWithMemberful":false,\
        "turnstileSiteKey":\(turnstile ? #""0x4AAA""# : "null"),\
        "passwordResetCodes":\(codes),"account":{"name":"Analytical"},"version":"test","user":null}
        """
    }
}

private extension SessionController.Phase {
    var isSignedOut: Bool { if case .signedOut = self { true } else { false } }
}
