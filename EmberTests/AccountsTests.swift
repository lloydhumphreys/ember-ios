import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// `Accounts` on a device of its own: a `defaults` suite, cookie vaults in memory, and stand-in
/// servers that answer from whichever session cookie each request carries, as the real one does.
@MainActor
@Suite struct AccountsTests {
    @Test func aFirstLaunchIsOneAccountThatAsksForAServer() async throws {
        let device = Device(Server.one())
        let accounts = device.launch()
        let slot = try #require(accounts.current)

        #expect(accounts.slots.map(\.id) == [slot.id])
        #expect(device.defaults.stringArray(forKey: Accounts.listKey) == [slot.id])
        #expect(device.onScreen === slot.stores)
        await slot.session.start()
        #expect(slot.session.phase.isNeedsServer)
        #expect(!accounts.canLeave)
    }

    @Test func addingAnAccountKeepsTheFirstSignedInAndSwitchesToTheNewOne() async throws {
        let one = Server.one(), two = Server.two()
        let device = Device(one, two)
        let accounts = device.launch()
        let first = try #require(accounts.current)
        try await signIn(first, on: one, as: Person.ada)

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        #expect(accounts.current === first)
        #expect(accounts.slots.map(\.id) == [first.id])
        // The same person's ID on another server is another account.
        try await signIn(added, on: two, as: Person.ada)

        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [first.id, added.id])
        #expect(accounts.current === added)
        #expect(device.onScreen === added.stores)
        #expect(first.workspace?.client.origin.host == "one.example")
        #expect(added.workspace?.client.origin.host == "two.example")
        #expect(first.profile?.workspaceName == "Fernwood")
        #expect(added.profile?.workspaceName == "Juniper")
        #expect(device.defaults.stringArray(forKey: Accounts.listKey) == [first.id, added.id])
        #expect(device.defaults.string(forKey: Accounts.currentKey) == added.id)
        #expect(one.liveTokens.count == 1)
        #expect(two.liveTokens.count == 1)

        accounts.select(first)
        #expect(accounts.current === first)
        #expect(device.onScreen === first.stores)
        #expect(device.defaults.string(forKey: Accounts.currentKey) == first.id)
    }

    @Test func cancellingAnAddLeavesNothingOfIt() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let first = try #require(accounts.current)
        try await signIn(first, on: one, as: Person.ada)

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        await added.session.start()
        try await added.session.useServer(one.origin.absoluteString)
        #expect(!device.keys(of: added.id).isEmpty)

        accounts.cancelAdding()
        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [first.id])
        #expect(accounts.current === first)
        #expect(device.onScreen === first.stores)
        #expect(device.keys(of: added.id).isEmpty)
        #expect(device.vault(added.id).read() == nil)
        #expect(first.workspace?.me.id == Person.ada.me.id)
    }

    @Test func twoPeopleOnOneServerKeepTheirOwnCookiesAcrossALaunch() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)

        #expect(ada.workspace?.me.id == Person.ada.me.id)
        #expect(grace.workspace?.me.id == Person.grace.me.id)
        let adaToken = try #require(device.token(of: ada.id))
        let graceToken = try #require(device.token(of: grace.id))
        #expect(adaToken != graceToken)
        #expect(one.person(with: adaToken) == Person.ada.me.id)
        #expect(one.person(with: graceToken) == Person.grace.me.id)
        // Grace signed in without Ada's cookie, so Ada's session was never touched.
        #expect(one.transport.requests("POST", "/api/session").map(Server.token(in:)) == [nil, nil])

        let relaunched = device.launch()
        #expect(relaunched.slots.map(\.id) == [ada.id, grace.id])
        #expect(relaunched.current?.id == grace.id)
        for slot in relaunched.slots { await slot.session.start() }
        #expect(relaunched.slots[0].workspace?.me.id == Person.ada.me.id)
        #expect(relaunched.slots[1].workspace?.me.id == Person.grace.me.id)
        #expect(relaunched.slots[0].profile?.name == Person.ada.me.name)
        #expect(one.ended.isEmpty)
    }

    @Test func signingInAgainAsAnAccountAlreadyHereGoesToIt() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let first = try #require(accounts.current)
        try await signIn(first, on: one, as: Person.ada)
        let draft = DraftKey(server: one.origin.absoluteString, user: Person.ada.me.id, room: "room-general")
        first.stores.drafts.set(Draft(text: "Half a thought"), for: draft)
        let unsent = try device.saveUnsent(on: one, for: Person.ada)
        let kept = try #require(device.token(of: first.id))

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        try await signIn(added, on: one, as: Person.ada)

        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [first.id])
        #expect(accounts.current === first)
        // Only the second session ends on the server; the first stays as it was.
        #expect(await eventually { one.ended.count == 1 })
        #expect(!one.ended.contains(kept))
        #expect(one.person(with: kept) == Person.ada.me.id)
        #expect(device.token(of: first.id) == kept)
        #expect(await eventually { device.keys(of: added.id).isEmpty && device.vault(added.id).read() == nil })
        #expect(first.workspace?.me.id == Person.ada.me.id)
        #expect(first.stores.drafts.draft(for: draft).text == "Half a thought")
        #expect(try !device.unsent.messages(for: unsent).isEmpty)
        #expect(device.defaults.stringArray(forKey: Accounts.listKey) == [first.id])
    }

    @Test func addingAnAccountWithASignInLinkSignsInOnItsServer() async throws {
        let one = Server.one(), two = Server.two()
        let device = Device(one, two)
        let accounts = device.launch()
        let first = try #require(accounts.current)
        try await signIn(first, on: one, as: Person.ada)

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        await added.session.start()
        try await added.session.useServer(two.link(for: Person.grace))

        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [first.id, added.id])
        #expect(accounts.current === added)
        #expect(added.workspace?.client.origin.host == "two.example")
        #expect(added.workspace?.me.id == Person.grace.me.id)
        #expect(first.workspace?.me.id == Person.ada.me.id)
    }

    @Test func aSignInLinkForAnAccountAlreadyHereGoesToIt() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let first = try #require(accounts.current)
        try await signIn(first, on: one, as: Person.ada)
        let kept = try #require(device.token(of: first.id))

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        await added.session.start()
        try await added.session.useServer(one.link(for: Person.ada))

        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [first.id])
        #expect(accounts.current === first)
        // Only the link's session ends on the server, as when signing in again with a password.
        #expect(await eventually { one.ended.count == 1 })
        #expect(!one.ended.contains(kept))
        #expect(device.token(of: first.id) == kept)
        // Its keys go before its session ends on the server, and its cookies after.
        #expect(await eventually { device.keys(of: added.id).isEmpty && device.vault(added.id).read() == nil })
    }

    @Test func signingInOnAnAccountWhoseSessionEndedAsAnotherAccountGoesToThatOne() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)

        await grace.session.signOut()
        #expect(grace.session.phase.isSignedOut)
        try await grace.session.signIn(emailAddress: Person.ada.email, password: Person.password)

        #expect(accounts.slots.map(\.id) == [ada.id])
        #expect(accounts.current === ada)
        #expect(await eventually { device.keys(of: grace.id).isEmpty })
        #expect(ada.workspace?.me.id == Person.ada.me.id)
    }

    @Test func signingInAgainAsAnAccountWhoseSessionEndedOffScreenGivesItTheNewSession() async throws {
        let one = Server.one()
        let device = Device(one)
        let launched = device.launch()
        let first = try #require(launched.current)
        try await signIn(first, on: one, as: Person.ada)
        launched.beginAdding()
        let second = try #require(launched.adding)
        try await signIn(second, on: one, as: Person.grace)
        let unsent = try device.saveUnsent(on: one, for: Person.ada)
        // The server ends Ada's session while her account is off screen.
        let old = try #require(device.token(of: first.id))
        one.end(old)

        let accounts = device.launch()
        let ada = try #require(accounts.slots.first { $0.id == first.id })
        let grace = try #require(accounts.current)
        #expect(grace.id == second.id)
        await grace.session.start()
        let draft = DraftKey(server: one.origin.absoluteString, user: Person.ada.me.id, room: "room-general")
        ada.stores.drafts.set(Draft(text: "Half a thought"), for: draft)

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        await added.session.start()
        try await added.session.useServer(one.origin.absoluteString)
        try await added.session.signIn(emailAddress: Person.ada.email, password: Person.password)
        let fresh = try #require(one.liveTokens.first { one.person(with: $0) == Person.ada.me.id })

        #expect(accounts.adding == nil)
        #expect(accounts.slots.map(\.id) == [ada.id, grace.id])
        #expect(accounts.current === ada)
        #expect(await eventually { ada.workspace?.me.id == Person.ada.me.id })
        #expect(device.token(of: ada.id) == fresh)
        #expect(one.person(with: fresh) == Person.ada.me.id)
        #expect(!one.ended.contains(fresh))
        #expect(ada.stores.drafts.draft(for: draft).text == "Half a thought")
        #expect(try !device.unsent.messages(for: unsent).isEmpty)
        #expect(await eventually { device.keys(of: added.id).isEmpty })
        #expect(device.vault(added.id).read() == nil)
        #expect(device.defaults.stringArray(forKey: Accounts.listKey) == [ada.id, grace.id])
    }

    @Test func signingInAgainAsAnAccountShowingSignInGivesItTheNewSession() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)
        accounts.select(ada)
        // The server says Ada's session is gone: her account shows sign-in, still in the list.
        await ada.session.signOut()
        #expect(ada.session.phase.isSignedOut)
        accounts.select(grace)

        accounts.beginAdding()
        let added = try #require(accounts.adding)
        await added.session.start()
        try await added.session.useServer(one.origin.absoluteString)
        try await added.session.signIn(emailAddress: Person.ada.email, password: Person.password)
        let fresh = try #require(one.liveTokens.first { one.person(with: $0) == Person.ada.me.id })

        #expect(accounts.slots.map(\.id) == [ada.id, grace.id])
        #expect(accounts.current === ada)
        #expect(await eventually { ada.workspace?.me.id == Person.ada.me.id })
        #expect(device.token(of: ada.id) == fresh)
        #expect(await eventually { device.keys(of: added.id).isEmpty })
    }

    @Test func signingOutOfOneAccountLeavesTheOthersAlone() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)

        let adaDraft = DraftKey(server: one.origin.absoluteString, user: Person.ada.me.id, room: "room-general")
        let graceDraft = DraftKey(server: one.origin.absoluteString, user: Person.grace.me.id, room: "room-general")
        ada.stores.drafts.set(Draft(text: "Ada’s"), for: adaDraft)
        grace.stores.drafts.set(Draft(text: "Grace’s"), for: graceDraft)
        let adaUnsent = try device.saveUnsent(on: one, for: Person.ada)
        let graceUnsent = try device.saveUnsent(on: one, for: Person.grace)
        let adaToken = try #require(device.token(of: ada.id))
        let graceToken = try #require(device.token(of: grace.id))
        #expect(accounts.current === grace)

        await accounts.signOut()

        #expect(accounts.slots.map(\.id) == [ada.id])
        #expect(accounts.current === ada)
        #expect(device.onScreen === ada.stores)
        #expect(device.defaults.stringArray(forKey: Accounts.listKey) == [ada.id])
        // Ada's account, on the same server, is as it was.
        #expect(ada.workspace?.me.id == Person.ada.me.id)
        #expect(device.token(of: ada.id) == adaToken)
        #expect(one.person(with: adaToken) == Person.ada.me.id)
        #expect(ada.stores.drafts.draft(for: adaDraft).text == "Ada’s")
        #expect(try !device.unsent.messages(for: adaUnsent).isEmpty)
        // Grace's is gone, here and on the server.
        #expect(one.ended == [graceToken])
        #expect(device.vault(grace.id).read() == nil)
        #expect(device.keys(of: grace.id).isEmpty)
        #expect(grace.stores.drafts.drafts.isEmpty)
        await accounts.unsentRemovals.settled()
        #expect(try device.unsent.messages(for: graceUnsent).isEmpty)
        #expect(device.defaults.data(forKey: UnsentRemovals.key) == nil)
    }

    @Test func unsentMessagesThatCouldntBeRemovedAreRemovedAtTheNextLaunch() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        let adaUnsent = try device.saveUnsent(on: one, for: Person.ada)
        device.unsent.failsRemovals = true

        await accounts.signOut()
        await accounts.unsentRemovals.settled()
        #expect(try !device.unsent.messages(for: adaUnsent).isEmpty)
        #expect(accounts.unsentRemovals.owed.map(\.userID) == [Person.ada.me.id])

        device.unsent.failsRemovals = false
        let relaunched = device.launch()
        await relaunched.unsentRemovals.settled()
        #expect(try device.unsent.messages(for: adaUnsent).isEmpty)
        #expect(relaunched.unsentRemovals.owed.isEmpty)
        #expect(device.defaults.data(forKey: UnsentRemovals.key) == nil)
    }

    @Test func aRemovalOwedWhenTheAccountSignsInAgainIsntTriedOnWhatItLeavesSince() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        _ = try device.saveUnsent(on: one, for: Person.ada)
        device.unsent.failsRemovals = true
        await accounts.signOut()
        await accounts.unsentRemovals.settled()
        #expect(accounts.unsentRemovals.owed.map(\.userID) == [Person.ada.me.id])

        try await ada.session.signIn(emailAddress: Person.ada.email, password: Person.password)
        #expect(ada.workspace?.me.id == Person.ada.me.id)
        await accounts.unsentRemovals.settled()
        #expect(accounts.unsentRemovals.owed.isEmpty)
        let unsent = try device.saveUnsent(on: one, for: Person.ada)
        let written = try device.unsent.messages(for: unsent)

        device.unsent.failsRemovals = false
        accounts.unsentRemovals.retry()
        await accounts.unsentRemovals.settled()
        #expect(try device.unsent.messages(for: unsent) == written)
        #expect(accounts.unsentRemovals.owed.isEmpty)
        #expect(device.defaults.data(forKey: UnsentRemovals.key) == nil)

        // Nor at the next launch, found signed in.
        let relaunched = device.launch()
        await relaunched.unsentRemovals.settled()
        #expect(try device.unsent.messages(for: unsent) == written)
    }

    @Test func aRemovalOwedIsFinishedWhenTheAccountSignsInAgain() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        let before = try device.saveUnsent(on: one, for: Person.ada)
        device.unsent.failsRemovals = true
        await accounts.signOut()
        await accounts.unsentRemovals.settled()

        device.unsent.failsRemovals = false
        try await ada.session.signIn(emailAddress: Person.ada.email, password: Person.password)
        await accounts.unsentRemovals.settled()
        #expect(try device.unsent.messages(for: before).isEmpty)
        #expect(accounts.unsentRemovals.owed.isEmpty)
    }

    @Test func signingOutOfTheOnlyAccountShowsSignInForItsServer() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let slot = try #require(accounts.current)
        try await signIn(slot, on: one, as: Person.ada)
        #expect(slot.profile != nil)

        await accounts.signOut()

        #expect(accounts.slots.map(\.id) == [slot.id])
        #expect(accounts.current === slot)
        #expect(slot.session.phase.isSignedOut)
        #expect(slot.profile == nil)
        #expect(device.defaults.data(forKey: Accounts.profileKey(slot.id)) == nil)
        #expect(device.vault(slot.id).read() == nil)
        #expect(one.liveTokens.isEmpty)
        #expect(!accounts.canLeave)
    }

    @Test func signingOutGoesBackToTheAccountUsedLast() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)
        accounts.beginAdding()
        let alan = try #require(accounts.adding)
        try await signIn(alan, on: one, as: Person.alan)

        accounts.select(ada)
        await accounts.signOut()

        #expect(accounts.current === alan)
        #expect(accounts.slots.map(\.id) == [grace.id, alan.id])
    }

    @Test func anAccountWhoseSessionEndedCanBeLeftForTheOneBefore() async throws {
        let one = Server.one()
        let device = Device(one)
        let accounts = device.launch()
        let ada = try #require(accounts.current)
        try await signIn(ada, on: one, as: Person.ada)
        accounts.beginAdding()
        let grace = try #require(accounts.adding)
        try await signIn(grace, on: one, as: Person.grace)
        #expect(!accounts.canLeave)

        await grace.session.signOut()
        #expect(accounts.canLeave)
        await accounts.leave()

        #expect(accounts.slots.map(\.id) == [ada.id])
        #expect(accounts.current === ada)
        #expect(device.keys(of: grace.id).isEmpty)
        #expect(ada.workspace?.me.id == Person.ada.me.id)
    }

    /// Synchronous throughout, so no other test runs while every store's `shared` is this one's.
    @Test func switchingPutsTheAccountsOwnStoresBehindEveryShared() throws {
        let device = Device(Server.one())
        device.defaults.set(["a", "b"], forKey: Accounts.listKey)
        device.defaults.set("b", forKey: Accounts.currentKey)
        let before = AccountStores.current
        defer { AccountStores.current = before }

        let accounts = device.launch(sharingStores: true)
        let a = try #require(accounts.slots.first)
        let b = try #require(accounts.slots.last)
        #expect(accounts.current === b)
        #expect(AccountStores.current === b.stores)
        #expect(Drafts.shared === b.stores.drafts)

        accounts.select(a)
        #expect(AccountStores.current === a.stores)
        #expect(Drafts.shared === a.stores.drafts)
        #expect(PickerLists.shared === a.stores.pickerLists)
        #expect(MessageFolds.shared === a.stores.folds)
        #expect(a.stores !== b.stores)
    }

    @Test func anAccountSignedInBeforeUpdatingIsTheFirstAccountStillSignedIn() async throws {
        let one = Server.one()
        let device = Device(one)
        let root = URL.temporaryDirectory.appending(path: "EmberTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = AccountStores.Folders(support: root.appending(path: "Support"), caches: root.appending(path: "Caches"))
        device.legacyFolders = legacy
        device.folders = { id in
            AccountStores.Folders(support: root.appending(path: "Support/Accounts/\(id)"), caches: root.appending(path: "Caches/Accounts/\(id)"))
        }

        // As TestFlight build 4 left it: the server and who's signed in under the keys it used, the
        // session cookie in the shared cookie store, a draft and a downloaded file in the shared folders.
        let token = one.startSession(for: Person.ada)
        device.defaults.set(one.origin.absoluteString, forKey: SessionController.originKey)
        device.defaults.set(["origin": one.origin.absoluteString, "userID": Person.ada.me.id.rawValue], forKey: SessionController.accountKey)
        device.legacyCookies.setCookies(Server.cookies(token, for: one.origin), for: one.origin, mainDocumentURL: nil)
        let elsewhere = URL(string: "https://elsewhere.example")!
        device.legacyCookies.setCookies(Server.cookies("not-ours", for: elsewhere), for: elsewhere, mainDocumentURL: nil)
        let draft = DraftKey(server: one.origin.absoluteString, user: Person.ada.me.id, room: "room-general")
        let drafts = Drafts(file: legacy.drafts)
        drafts.set(Draft(text: "Half a thought"), for: draft)
        drafts.save()
        try FileManager.default.createDirectory(at: legacy.files, withIntermediateDirectories: true)
        try Data("minutes".utf8).write(to: legacy.files.appending(path: "minutes.txt"))

        let accounts = device.launch()
        let slot = try #require(accounts.current)
        #expect(accounts.slots.map(\.id) == [slot.id])
        #expect(device.defaults.string(forKey: SessionController.originKey) == nil)
        #expect(device.defaults.object(forKey: SessionController.accountKey) == nil)
        #expect(device.legacyCookies.cookies(for: one.origin)?.isEmpty ?? true)
        #expect(device.legacyCookies.cookies(for: elsewhere)?.count == 1)
        #expect(device.token(of: slot.id) == token)
        #expect(slot.stores.drafts.draft(for: draft).text == "Half a thought")
        #expect(!FileManager.default.fileExists(atPath: try #require(legacy.drafts).path))
        #expect(FileManager.default.fileExists(atPath: slot.stores.folders.files.appending(path: "minutes.txt").path))

        await slot.session.start()
        #expect(slot.workspace?.me.id == Person.ada.me.id)
        #expect(one.transport.requests("GET", "/api/bootstrap").last.flatMap(Server.token(in:)) == token)
        #expect(slot.stores.drafts.draft(for: draft).text == "Half a thought")
        #expect(slot.profile?.workspaceName == "Fernwood")

        // Once moved, it isn't moved again.
        let relaunched = device.launch()
        #expect(relaunched.slots.map(\.id) == [slot.id])
    }

    @Test func aProfileIsKeptAsJSONWithItsPersonsIDAsAString() throws {
        let profile = Accounts.Profile(
            origin: URL(string: "https://ember.test")!, userID: "user_ada", name: "Ada Lovelace",
            workspaceName: "Ember", avatarPath: "/users/user_ada/avatar")
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? NSDictionary
        #expect(written == [
            "origin": "https://ember.test", "userID": "user_ada", "name": "Ada Lovelace",
            "workspaceName": "Ember", "avatarPath": "/users/user_ada/avatar",
        ] as NSDictionary)
        let stored = #"{"origin":"https://ember.test","userID":"user_grace","name":"Grace Hopper","workspaceName":"Ember"}"#
        #expect(try JSONDecoder().decode(Accounts.Profile.self, from: Data(stored.utf8)) == Accounts.Profile(
            origin: URL(string: "https://ember.test")!, userID: "user_grace", name: "Grace Hopper",
            workspaceName: "Ember", avatarPath: nil))
    }

    @Test func whatsLeftOfAnAccountNoLongerListedIsErasedAtLaunch() throws {
        let device = Device(Server.one())
        device.defaults.set(["kept"], forKey: Accounts.listKey)
        for id in ["kept", "orphan"] {
            device.defaults.set("https://one.example", forKey: SessionController.Keys.account(id).origin)
            device.defaults.set(Data(), forKey: Accounts.profileKey(id))
            device.vault(id).write(Data("[]".utf8))
        }

        let accounts = device.launch()

        #expect(accounts.slots.map(\.id) == ["kept"])
        #expect(device.vault("orphan").read() == nil)
        #expect(device.keys(of: "orphan").isEmpty)
        #expect(device.vault("kept").read() != nil)
        #expect(device.keys(of: "kept").count == 2)
    }

    @Test func eachAccountsCookiesAreAKeychainItemOfTheirOwn() throws {
        let service = "EmberTests \(UUID().uuidString)"
        defer {
            for account in KeychainCookieVault.accounts(service: service) {
                try? KeychainCookieVault(account: account, service: service).erase()
            }
        }
        let origin = URL(string: "https://one.example")!
        KeychainCookieStorage(account: "ada", service: service).setCookies(Server.cookies("a", for: origin), for: origin, mainDocumentURL: nil)
        KeychainCookieStorage(account: "grace", service: service).setCookies(Server.cookies("g", for: origin), for: origin, mainDocumentURL: nil)

        #expect(Set(KeychainCookieVault.accounts(service: service)) == ["ada", "grace"])
        let ada = KeychainCookieStorage(account: "ada", service: service)
        #expect(ada.cookies(for: origin)?.map(\.value) == ["a"])
        #expect(KeychainCookieStorage(account: "grace", service: service).cookies(for: origin)?.map(\.value) == ["g"])

        ada.eraseAll()
        #expect(KeychainCookieVault.accounts(service: service) == ["grace"])
        #expect(KeychainCookieStorage(account: "ada", service: service).cookies?.isEmpty ?? true)
        #expect(KeychainCookieStorage(account: "grace", service: service).cookies(for: origin)?.map(\.value) == ["g"])
    }

    /// Chooses `server` and signs in as `person` on `slot`, as the sign-in screens do.
    private func signIn(_ slot: Accounts.Slot, on server: Server, as person: Person) async throws {
        await slot.session.start()
        try await slot.session.useServer(server.origin.absoluteString)
        try await slot.session.signIn(emailAddress: person.email, password: Person.password)
        #expect(slot.workspace?.me.id == person.me.id)
    }
}

/// Someone who can sign in to the stand-in servers.
private struct Person: Sendable {
    let email: String
    let me: Me

    static let password = "not a real password"
    static let ada = Person(email: "ada@example.com", me: Fixtures.me)
    static let grace = Person(email: "grace@example.com", me: Me(id: "user_grace", name: "Grace Hopper", administrator: false))
    static let alan = Person(email: "alan@example.com", me: Me(id: "user_alan", name: "Alan Turing", administrator: false))
}

/// A stand-in Ember server that knows who each session token belongs to, as the real one does:
/// signing in starts a session and sets its cookie, the bootstrap names whoever the request's
/// cookie belongs to, and signing out ends only the session it's sent.
private final class Server: @unchecked Sendable {
    let origin: URL
    let transport = MockHTTPTransport()
    private let workspace: String
    private let people: [String: Person]
    private let lock = NSLock()
    private var sessions: [String: Person] = [:]
    private var endedTokens: [String] = []
    private var links: [String: Person] = [:]

    static func one() -> Server { Server("one.example", workspace: "Fernwood", people: [.ada, .grace, .alan]) }
    static func two() -> Server { Server("two.example", workspace: "Juniper", people: [.ada, .grace]) }

    init(_ host: String, workspace: String, people: [Person]) {
        origin = URL(string: "https://\(host)")!
        self.workspace = workspace
        self.people = Dictionary(uniqueKeysWithValues: people.map { ($0.email, $0) })
        transport.stub("GET", "/api/bootstrap") { [unowned self] request in
            (200, self.bootstrap(for: Self.token(in: request).flatMap(self.session(with:))))
        }
        transport.stub("POST", "/api/session", answer: { [unowned self] request in
            guard let body = request.httpBody,
                  let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let email = fields["emailAddress"] as? String, let person = self.people[email],
                  fields["password"] as? String == Person.password
            else { return .init(status: 401, json: #"{"error":"Incorrect email or password. Please try again."}"#) }
            let token = self.startSession(for: person)
            return .init(json: Fixtures.meJSON(person.me), headers: ["Set-Cookie": Self.setCookie(token)])
        })
        transport.stub("POST", "/api/session/transfers", answer: { [unowned self] request in
            guard let body = request.httpBody,
                  let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = fields["transferId"] as? String,
                  let person = self.lock.withLock({ self.links.removeValue(forKey: id) })
            else { return .init(status: 400, json: "") }
            let token = self.startSession(for: person)
            return .init(status: 201, json: Fixtures.meJSON(person.me), headers: ["Set-Cookie": Self.setCookie(token)])
        })
        transport.stub("DELETE", "/api/session") { [unowned self] request in
            if let token = Self.token(in: request) { self.end(token) }
            return (204, "{}")
        }
    }

    /// Starts a session for `person`, answering its token.
    @discardableResult
    func startSession(for person: Person) -> String {
        let token = UUID().uuidString
        lock.withLock { sessions[token] = person }
        return token
    }

    /// A sign-in link for `person`, good once, as the web shows one.
    func link(for person: Person) -> String {
        let id = "tr_\(UUID().uuidString)"
        lock.withLock { links[id] = person }
        return "\(origin.absoluteString)/session/transfers#token=\(id)"
    }

    /// Whose session `token` is, while it lasts.
    func person(with token: String) -> UserID? {
        session(with: token)?.me.id
    }

    var liveTokens: [String] { lock.withLock { Array(sessions.keys) } }
    var ended: [String] { lock.withLock { endedTokens } }

    private func session(with token: String) -> Person? {
        lock.withLock { sessions[token] }
    }

    /// Ends the session `token` is for, as signing out or the server ending it does.
    func end(_ token: String) {
        lock.withLock {
            if sessions.removeValue(forKey: token) != nil { endedTokens.append(token) }
        }
    }

    private func bootstrap(for person: Person?) -> String {
        let user = person.map { #"{"id":"\#($0.me.id)","name":"\#($0.me.name)","administrator":false}"# } ?? "null"
        return """
        {"setup":"complete","guestSignIn":false,"signInWithMemberful":false,"turnstileSiteKey":null,\
        "passwordResetCodes":false,"account":{"name":"\(workspace)"},"version":"test","user":\(user)}
        """
    }

    static func setCookie(_ token: String) -> String {
        "session_token=\(token); Path=/; Secure; HttpOnly"
    }

    /// The session cookie for `token`, as the server sets it.
    static func cookies(_ token: String, for origin: URL) -> [HTTPCookie] {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie(token)], for: origin)
    }

    /// The session token a request carries, if any.
    static func token(in request: URLRequest) -> String? {
        for pair in (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "session_token" { return String(parts[1]) }
        }
        return nil
    }
}

/// One device's storage, kept across launches of the app: its `defaults`, each account's cookie
/// vault, the cookie store and folders the app used before it held more than one account, and
/// unsent messages.
@MainActor private final class Device {
    let defaults: UserDefaults
    let servers: [Server]
    let legacyCookies = EphemeralCookieStorage()
    let unsent = MemoryUnsentMessageStore()
    let path = MockNetworkPath()
    let clock = ManualClock()
    var folders: @MainActor (String) -> AccountStores.Folders? = { _ in nil }
    var legacyFolders: AccountStores.Folders?
    /// The stores the latest launch put on screen.
    private(set) var onScreen: AccountStores?
    private var vaults: [String: MemoryCookieVault] = [:]
    private let suite = "EmberTests.\(UUID().uuidString)"

    init(_ servers: Server...) {
        self.servers = servers
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    /// The app launched on this device, its accounts started. `sharingStores` puts each account's
    /// stores behind every store's `shared`, as the app does; otherwise they're kept in `onScreen`.
    func launch(sharingStores: Bool = false) -> Accounts {
        let servers = servers
        let putOnScreen: @MainActor @Sendable (AccountStores) -> Void
        if sharingStores {
            putOnScreen = { AccountStores.current = $0 }
        } else {
            putOnScreen = { [unowned self] in self.onScreen = $0 }
        }
        let accounts = Accounts(
            defaults: defaults,
            legacyCookies: legacyCookies,
            makeCookies: { [unowned self] id in KeychainCookieStorage(vault: self.vault(id)) },
            keptCookies: { [unowned self] in self.vaults.filter { $0.value.read() != nil }.map(\.key) },
            makeClient: { origin, cookies in
                let server = servers.first { $0.origin.host == origin.host }
                return EmberClient.mock(origin: origin, transport: server?.transport ?? MockHTTPTransport(), cookies: cookies)
            },
            folders: folders,
            legacyFolders: legacyFolders,
            unsent: unsent,
            network: NetworkStatus(source: path),
            clock: clock,
            putOnScreen: putOnScreen)
        accounts.start()
        return accounts
    }

    /// Account `id`'s cookie vault, as the Keychain would keep it.
    func vault(_ id: String) -> MemoryCookieVault {
        if let vault = vaults[id] { return vault }
        let vault = MemoryCookieVault()
        vaults[id] = vault
        return vault
    }

    /// The session token kept in account `id`'s vault.
    func token(of id: String) -> String? {
        KeychainCookieStorage(vault: vault(id)).cookies?.first { $0.name == "session_token" }?.value
    }

    /// Every `defaults` key kept for account `id`.
    func keys(of id: String) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("account.\(id).") }
    }

    /// Leaves a message unsent for `person` on `server`, answering where it's kept.
    func saveUnsent(on server: Server, for person: Person) throws -> UnsentMessageKey {
        let key = UnsentMessageKey(server: server.origin, userID: person.me.id, roomID: "room-general")
        try unsent.save([UnsentMessage(clientMessageId: ClientMessageID(UUID().uuidString), body: "Hello", plainText: "Hello", createdAt: .now)], for: key)
        return key
    }
}

private extension SessionController.Phase {
    var isNeedsServer: Bool { if case .needsServer = self { true } else { false } }
    var isSignedOut: Bool { if case .signedOut = self { true } else { false } }
}
