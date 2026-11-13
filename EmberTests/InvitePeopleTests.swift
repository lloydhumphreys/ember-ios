import Foundation
import Testing
import SwiftUI
import UIKit
import EmberSDK
import EmberTesting
@testable import Ember

/// Invite People: the addresses read from what's typed, inviting, sending again and revoking, and
/// the links, which never show in a description. Nothing here touches the network.
@MainActor
@Suite struct InvitePeopleTests {
    static let fakeLink = "https://ember.test/join/invitation#token=fake-token-for-tests"
    static let otherFakeLink = "https://ember.test/join/invitation#token=fake-new-token-for-tests"

    // MARK: Reading addresses

    @Test func addressesAreApartByCommasSpacesAndNewLines() {
        let typed = "ann@example.com, bob@example.com\ncarl@example.com  dee@example.com;eve@example.com\n\n"
        let addresses = InviteModel.addresses(in: typed)
        #expect(addresses.valid == ["ann@example.com", "bob@example.com", "carl@example.com", "dee@example.com", "eve@example.com"])
        #expect(addresses.junk.isEmpty)
    }

    @Test func eachAddressIsKeptOnceWhateverItsCaseAsFirstWritten() {
        let addresses = InviteModel.addresses(in: "Ann@Example.com ann@example.com, ANN@EXAMPLE.COM bob@example.com")
        #expect(addresses.valid == ["Ann@Example.com", "bob@example.com"])
    }

    @Test func namesFromAMailAppAreLeftOut() {
        let addresses = InviteModel.addresses(in: #"Ann Smith <ann@example.com>, "Jones, Bob" <bob@example.com>"#)
        #expect(addresses.valid == ["ann@example.com", "bob@example.com"])
        #expect(addresses.junk.isEmpty)
    }

    @Test func whatIsntAnAddressIsJunk() {
        let addresses = InviteModel.addresses(in: "ann@example.com bob, @example.com carl@ dee@localhost eve@-x.example.com fay@@example.com")
        #expect(addresses.valid == ["ann@example.com"])
        #expect(addresses.junk == ["bob", "@example.com", "carl@", "dee@localhost", "eve@-x.example.com", "fay@@example.com"])
    }

    @Test func sendWaitsForAnAddress() {
        let model = InviteModel()
        model.attach(EmberClient.mock())
        #expect(!model.canSend)
        model.text = "  ,  bob \n"
        #expect(!model.canSend)
        model.text = "bob ann@example.com"
        #expect(model.canSend)
    }

    @Test(.timeLimit(.minutes(1)))
    func junkIsRefusedBeforeAskingTheServerAndTheTextStays() async {
        let transport = MockHTTPTransport()
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        model.text = "ann@example.com bob"
        await model.send()
        #expect(model.failure == "This isn’t an email address: bob")
        #expect(model.text == "ann@example.com bob")
        #expect(transport.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func twentyAreSentAtMostAndDuplicatesDontCount() async throws {
        let transport = MockHTTPTransport()
        transport.stub("POST", "/api/invitations", json: #"{"outcomes":[]}"#)
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))

        let tooMany = (1 ... 21).map { "person\($0)@example.com" }.joined(separator: ", ")
        model.text = tooMany
        await model.send()
        #expect(model.failure == "Invite at most 20 email addresses at once")
        #expect(model.text == tooMany)
        #expect(transport.requests.isEmpty)

        // Twenty, one of them twice in other capitals.
        model.text = (1 ... 20).map { "person\($0)@example.com" }.joined(separator: " ") + " PERSON1@example.com"
        await model.send()
        #expect(model.failure == nil)
        let body = try #require(transport.lastBody("POST", "/api/invitations"))
        #expect((body["emailAddresses"] as? [String])?.count == 20)
    }

    // MARK: Inviting

    @Test(.timeLimit(.minutes(1)))
    func invitingShowsEachOutcomeAndAddsToPendingInPlace() async throws {
        let transport = MockHTTPTransport()
        let older = Self.invitation("inv_old", "old@example.com", at: "2026-10-01T10:00:00.000Z")
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([older]))
        let emailed = Self.invitation("inv_1", "charles@example.com", at: "2026-10-12T10:00:00.000Z")
        let unsent = Self.invitation("inv_2", "mary@example.com", at: "2026-10-12T10:00:01.000Z", delivery: nil)
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "grace@example.com", "member": true],
            ["emailAddress": "charles@example.com", "invitation": Fixtures.emailInvitationObject(emailed), "link": NSNull()],
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": Self.fakeLink],
        ]]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        #expect(model.loading == .loaded)
        #expect(model.pending.map(\.id) == ["inv_old"])

        model.text = "grace@example.com, charles@example.com mary@example.com"
        await model.send()
        #expect(model.failure == nil)
        #expect(model.text.isEmpty)
        #expect(model.outcomes.map(\.emailAddress) == ["grace@example.com", "charles@example.com", "mary@example.com"])
        #expect(model.outcomes.map(\.kind) == [.member, .invited("inv_1"), .invited("inv_2")])
        // Newest first, without asking for the list again.
        #expect(model.pending.map(\.id) == ["inv_2", "inv_1", "inv_old"])
        #expect(transport.requests("GET", "/api/account").count == 1)
        #expect(model.link(for: "inv_1") == nil)
        #expect(model.link(for: "inv_2")?.revealed == Self.fakeLink)
        // Pending leaves out what's under Invited.
        #expect(model.pendingShown.map(\.id) == ["inv_old"])
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingLeavesOutWhatsInvitedThisVisitByIdOrAddress() async throws {
        let transport = MockHTTPTransport()
        let older = Self.invitation("inv_old", "old@example.com", at: "2026-10-01T10:00:00.000Z")
        // Listed by the server under another id, in other capitals: still invited this visit.
        let listed = Self.invitation("inv_8", "Mary@Example.com", at: "2026-10-11T10:00:00.000Z")
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([listed, older]))
        let unsent = Self.invitation("inv_2", "mary@example.com", at: "2026-10-12T10:00:01.000Z", delivery: nil)
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "grace@example.com", "member": true],
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": NSNull()],
        ]]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        model.text = "grace@example.com mary@example.com"
        await model.send()
        await model.reload()
        #expect(model.pending.map(\.id).contains("inv_8"))
        #expect(model.pendingShown.map(\.id) == ["inv_old"])
        // Someone already a member leaves nothing out.
        #expect(InviteModel.pendingShown([older], outcomes: model.outcomes.filter { $0.kind == .member }) == [older])
    }

    @Test(.timeLimit(.minutes(1)))
    func invitingAPendingAddressAgainReplacesItsRow() async throws {
        let transport = MockHTTPTransport()
        let first = Self.invitation("inv_1", "Mary@Example.com", at: "2026-10-01T10:00:00.000Z")
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([first]))
        let again = Self.invitation("inv_9", "mary@example.com", at: "2026-10-12T10:00:00.000Z")
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(again), "link": NSNull()],
        ]]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        model.text = "mary@example.com"
        await model.send()
        #expect(model.pending.map(\.id) == ["inv_9"])
    }

    @Test(.timeLimit(.minutes(1)))
    func refusalsShowTheServersMessageAndKeepWhatWasTyped() async {
        let cases: [(Int, String)] = [
            (403, "Only administrators can invite people"),
            (422, "Each must be an email address, such as ann@example.com"),
            (429, "Too many requests. Try again in a minute."),
        ]
        for (status, message) in cases {
            let transport = MockHTTPTransport()
            transport.stub("POST", "/api/invitations", status: status, json: Fixtures.errorJSON(message))
            let model = InviteModel()
            model.attach(EmberClient.mock(transport: transport))
            model.text = "ann@example.com, bob@example.com"
            await model.send()
            #expect(model.failure == message)
            #expect(model.text == "ann@example.com, bob@example.com")
            #expect(!model.isSending)
            #expect(model.outcomes.isEmpty)
            model.clearFailure()
            #expect(model.failure == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func offlineSaysSoAndKeepsWhatWasTyped() async {
        let transport = MockHTTPTransport()
        transport.failEverything()
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        guard case .failed(let message) = model.loading else {
            Issue.record("Expected the list to fail, got \(model.loading)")
            return
        }
        #expect(!message.isEmpty)
        model.text = "ann@example.com"
        await model.send()
        #expect(model.failure?.isEmpty == false)
        #expect(model.text == "ann@example.com")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedRefreshKeepsTheListShown() async {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([Self.invitation("inv_1", "ann@example.com")]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        transport.reset()
        transport.failEverything()
        await model.reload()
        #expect(model.loading == .loaded)
        #expect(model.pending.map(\.id) == ["inv_1"])
        #expect(model.failure != nil)
    }

    // MARK: Sending again and revoking

    @Test(.timeLimit(.minutes(1)))
    func resendingReplacesTheRowAndSurfacesItsNewLink() async throws {
        let transport = MockHTTPTransport()
        let older = Self.invitation("inv_1", "ann@example.com", at: "2026-10-01T10:00:00.000Z", delivery: .refused("Mailbox full"))
        let other = Self.invitation("inv_2", "bob@example.com", at: "2026-10-05T10:00:00.000Z")
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([other, older]))
        let resent = Self.invitation("inv_1", "ann@example.com", at: "2026-10-12T10:00:00.000Z", delivery: nil)
        transport.stub("POST", "/api/invitations/inv_1/resend", json: Self.json([
            "invitation": Fixtures.emailInvitationObject(resent), "link": Self.otherFakeLink,
        ]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        #expect(InviteModel.wasRefused(try #require(model.invitation("inv_1"))))

        #expect(await model.resend("inv_1") == "inv_1")
        #expect(model.failure == nil)
        #expect(model.pending.map(\.id) == ["inv_1", "inv_2"])
        #expect(model.pending.first == resent)
        #expect(!InviteModel.wasRefused(try #require(model.invitation("inv_1"))))
        #expect(model.link(for: "inv_1")?.revealed == Self.otherFakeLink)
        #expect(!model.isWorking(on: "inv_1"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aResendThatIsEmailedDropsTheOldLink() async {
        let transport = MockHTTPTransport()
        let unsent = Self.invitation("inv_2", "mary@example.com", delivery: nil)
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": Self.fakeLink],
        ]]))
        transport.stub("POST", "/api/invitations/inv_2/resend", json: Self.json([
            "invitation": Fixtures.emailInvitationObject(Self.invitation("inv_2", "mary@example.com")), "link": NSNull(),
        ]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        model.text = "mary@example.com"
        await model.send()
        #expect(model.link(for: "inv_2") != nil)
        await model.resend("inv_2")
        #expect(model.link(for: "inv_2") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedResendSaysWhyAndKeepsTheRow() async {
        let transport = MockHTTPTransport()
        let invitation = Self.invitation("inv_1", "ann@example.com")
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([invitation]))
        transport.stub("POST", "/api/invitations/inv_1/resend", status: 429, json: Fixtures.errorJSON("Too many requests. Try again in a minute."))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        // Nothing was sent, so no checkmark.
        #expect(await model.resend("inv_1") == nil)
        #expect(model.failure == "Too many requests. Try again in a minute.")
        #expect(model.pending == [invitation])
    }

    @Test(.timeLimit(.minutes(1)))
    func revokingTakesTheRowAwayAtOnceAndPutsItBackIfRefused() async {
        let transport = MockHTTPTransport()
        let invitations = [
            Self.invitation("inv_3", "carl@example.com", at: "2026-10-03T10:00:00.000Z"),
            Self.invitation("inv_2", "bob@example.com", at: "2026-10-02T10:00:00.000Z"),
            Self.invitation("inv_1", "ann@example.com", at: "2026-10-01T10:00:00.000Z"),
        ]
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON(invitations))
        transport.stub("DELETE", "/api/invitations/inv_2", status: 403, json: Fixtures.errorJSON("Only administrators can invite people"))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()

        let gate = transport.hold("DELETE", "/api/invitations/inv_2")
        let revoking = Task { await model.revoke("inv_2") }
        await gate.waitForRequest()
        #expect(model.pending.map(\.id) == ["inv_3", "inv_1"])
        #expect(model.isWorking(on: "inv_2"))
        // A refresh meanwhile doesn't bring it back early.
        await model.reload()
        #expect(model.pending.map(\.id) == ["inv_3", "inv_1"])
        gate.release()
        await revoking.value
        #expect(model.pending.map(\.id) == ["inv_3", "inv_2", "inv_1"])
        #expect(model.failure == "Only administrators can invite people")
        #expect(!model.isWorking(on: "inv_2"))
    }

    @Test(.timeLimit(.minutes(1)))
    func revokingRemovesTheRowAndItsLink() async {
        let transport = MockHTTPTransport()
        let unsent = Self.invitation("inv_2", "mary@example.com", delivery: nil)
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": Self.fakeLink],
        ]]))
        transport.stub("DELETE", "/api/invitations/inv_2", status: 204, json: "")
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        model.text = "mary@example.com"
        await model.send()
        await model.revoke("inv_2")
        #expect(model.pending.isEmpty)
        #expect(model.link(for: "inv_2") == nil)
        #expect(model.failure == nil)
        #expect(transport.requests("DELETE", "/api/invitations/inv_2").count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func anInvitationAlreadyGoneStaysGone() async {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([Self.invitation("inv_1", "ann@example.com")]))
        transport.stub("DELETE", "/api/invitations/inv_1", status: 404, json: Fixtures.errorJSON("Not found"))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        await model.reload()
        await model.revoke("inv_1")
        #expect(model.pending.isEmpty)
        #expect(model.failure == nil)
    }

    // MARK: Links are secrets

    @Test(.timeLimit(.minutes(1)))
    func aLinkNeverShowsInADescription() async throws {
        let transport = MockHTTPTransport()
        let unsent = Self.invitation("inv_2", "mary@example.com", delivery: nil)
        transport.stub("POST", "/api/invitations", json: Self.json(["outcomes": [
            ["emailAddress": "mary@example.com", "invitation": Fixtures.emailInvitationObject(unsent), "link": Self.fakeLink],
        ]]))
        let model = InviteModel()
        model.attach(EmberClient.mock(transport: transport))
        model.text = "mary@example.com"
        await model.send()
        let link = try #require(model.link(for: "inv_2"))

        var dumped = ""
        dump(model, to: &dumped)
        var dumpedOutcomes = ""
        dump(model.outcomes, to: &dumpedOutcomes)
        let descriptions = [
            String(describing: model), String(reflecting: model), dumped,
            String(describing: model.outcomes), String(reflecting: model.outcomes), dumpedOutcomes,
            String(describing: model.pending), String(describing: link), String(reflecting: link),
            "\(link)",
        ]
        for description in descriptions {
            #expect(!description.contains("fake-token"))
            #expect(!description.contains("ember.test/join"))
        }
    }

    @Test func aCopiedLinkStaysOnThisDeviceAndExpires() throws {
        let link = Secret(Self.fakeLink)
        let items = InviteModel.pasteboardItems(for: link)
        #expect(items.count == 1)
        #expect(items[0]["public.url"] as? URL == URL(string: Self.fakeLink))
        #expect(items[0]["public.utf8-plain-text"] as? String == Self.fakeLink)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let options = InviteModel.pasteboardOptions(now: now)
        #expect(options[.localOnly] as? Bool == true)
        let expiry = try #require(options[.expirationDate] as? Date)
        #expect(expiry > now)
        #expect(expiry <= now.addingTimeInterval(60 * 60))
    }

    // MARK: On screen

    @Test(.timeLimit(.minutes(1)))
    func theScreenLoadsThePendingInvitationsWhenItOpens() async throws {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/account", json: Fixtures.accountInvitationsJSON([Self.invitation("inv_1", "ann@example.com", delivery: .refused("Mailbox full"))]))
        let workspace = Workspace(client: EmberClient.mock(transport: transport), me: Fixtures.me, account: Fixtures.account)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: InvitePeopleView().environment(workspace))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        while transport.requests("GET", "/api/account").isEmpty {
            window.layoutIfNeeded()
            await Task.yield()
        }
        window.layoutIfNeeded()
    }

    // MARK: Helpers

    static func invitation(
        _ id: InvitationID, _ emailAddress: String, at created: String = "2026-10-12T10:00:00.000Z",
        delivery: EmailInvitation.Delivery? = .sent
    ) -> EmailInvitation {
        let createdAt = try! Date(created, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        return EmailInvitation(
            id: id, emailAddress: emailAddress, invitedBy: Fixtures.me.name,
            createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(7 * 24 * 60 * 60), delivery: delivery
        )
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
