import Foundation
import Observation
import EmberSDK

/// Every account on this device, each entirely its own: its own session cookies in the Keychain, its
/// own `URLSession` and realtime connection, its own drafts, caches and place, and its own server
/// and sign-in in `defaults`. Two people on one server never share a cookie.
///
/// One account is on screen at a time. The others keep their workspace in memory but stopped: no
/// socket, no requests, until they're switched to.
@MainActor @Observable final class Accounts {
    /// One account: its session, cookies and stores.
    @MainActor @Observable final class Slot: Identifiable {
        let id: String
        let session: SessionController
        @ObservationIgnored let cookies: KeychainCookieStorage
        @ObservationIgnored let stores: AccountStores
        /// Who it is, kept for the menu while it's off screen.
        fileprivate(set) var profile: Profile?
        /// A client for the profile's server, for the menu's avatar while it's off screen.
        @ObservationIgnored private var menuClient: EmberClient?

        fileprivate init(id: String, session: SessionController, cookies: KeychainCookieStorage, stores: AccountStores, profile: Profile?) {
            self.id = id
            self.session = session
            self.cookies = cookies
            self.stores = stores
            self.profile = profile
        }

        var workspace: Workspace? {
            if case .signedIn(let workspace) = session.phase { workspace } else { nil }
        }

        /// Who's signed in, now or when last seen.
        var signedIn: SessionController.SignedInAccount? {
            if let workspace { return SessionController.SignedInAccount(origin: workspace.client.origin, userID: workspace.me.id) }
            if let profile { return SessionController.SignedInAccount(origin: profile.origin, userID: profile.userID) }
            return session.storedAccount
        }

        /// The profile as the workspace has it now, if it's signed in.
        var liveProfile: Profile? { workspace.map(Profile.init) ?? profile }

        /// A client with this account's cookies, for its avatar.
        var client: EmberClient? {
            if let workspace { return workspace.client }
            guard let origin = profile?.origin else { return nil }
            if let menuClient, menuClient.origin == origin { return menuClient }
            let client = session.client(for: origin)
            menuClient = client
            return client
        }
    }

    /// What the menu shows of an account that isn't on screen.
    struct Profile: Codable, Equatable {
        var origin: URL
        var userID: UserID
        var name: String
        var workspaceName: String
        var avatarPath: String?

        init(origin: URL, userID: UserID, name: String, workspaceName: String, avatarPath: String?) {
            self.origin = origin
            self.userID = userID
            self.name = name
            self.workspaceName = workspaceName
            self.avatarPath = avatarPath
        }

        @MainActor init(_ workspace: Workspace) {
            self.init(
                origin: workspace.client.origin,
                userID: workspace.me.id,
                name: workspace.name(ofUserID: workspace.me.id) ?? workspace.me.name,
                workspaceName: workspace.account.name,
                avatarPath: workspace.avatarPath(for: workspace.me.id))
        }
    }

    /// Where the accounts are kept in `defaults`, in order.
    static let listKey = "accounts.list"
    /// Where the account on screen is kept in `defaults`.
    static let currentKey = "accounts.current"
    static func profileKey(_ id: String) -> String { "account.\(id).profile" }

    /// Every account, in the order they were added.
    private(set) var slots: [Slot] = []
    /// The account on screen; nil only before `start`.
    private(set) var current: Slot?
    /// An account being signed in to over the current one, until it is.
    private(set) var adding: Slot?

    /// Whether the device is online, for every account's screens.
    let network: NetworkStatus

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let legacyCookies: HTTPCookieStorage
    @ObservationIgnored private let makeCookies: @MainActor (String) -> KeychainCookieStorage
    @ObservationIgnored private let keptCookies: @MainActor () -> [String]
    @ObservationIgnored private let makeClient: @MainActor (URL, HTTPCookieStorage) -> EmberClient
    @ObservationIgnored private let folders: @MainActor (String) -> AccountStores.Folders?
    @ObservationIgnored private let legacyFolders: AccountStores.Folders?
    @ObservationIgnored private let unsent: any UnsentMessageStore
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let putOnScreen: @MainActor (AccountStores) -> Void
    @ObservationIgnored private var hasStarted = false
    /// The accounts switched to, most recent last, for where signing out of one goes.
    @ObservationIgnored private var recent: [String] = []

    /// Every parameter is there for tests: a `defaults` suite of their own, a cookie store standing
    /// in for the one the app used before it held more than one account, cookie vaults in memory,
    /// EmberTesting's mock client, folders of their own, a network and clock they move by hand, and
    /// somewhere to keep the stores on screen other than every store's `shared`.
    init(
        defaults: UserDefaults = .standard,
        legacyCookies: HTTPCookieStorage = .shared,
        makeCookies: @escaping @MainActor (String) -> KeychainCookieStorage = { KeychainCookieStorage(account: $0) },
        keptCookies: @escaping @MainActor () -> [String] = { KeychainCookieVault.accounts() },
        makeClient: @escaping @MainActor (URL, HTTPCookieStorage) -> EmberClient = { EmberClient(origin: $0, cookies: $1) },
        folders: @escaping @MainActor (String) -> AccountStores.Folders? = { .account($0) },
        legacyFolders: AccountStores.Folders? = .unshared,
        unsent: (any UnsentMessageStore)? = nil,
        network: NetworkStatus? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        putOnScreen: @escaping @MainActor (AccountStores) -> Void = { AccountStores.current = $0 }
    ) {
        self.defaults = defaults
        self.legacyCookies = legacyCookies
        self.makeCookies = makeCookies
        self.keptCookies = keptCookies
        self.makeClient = makeClient
        self.folders = folders
        self.legacyFolders = legacyFolders
        self.unsent = unsent ?? FileUnsentMessageStore()
        self.network = network ?? NetworkStatus()
        self.clock = clock
        self.putOnScreen = putOnScreen
    }

    /// Once, from RootView's `.task`: brings an account signed in before the app held more than one
    /// into the list, and puts the last account on screen back. With none, it's a new one, which
    /// asks for a server.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        adoptUnshared()
        // Before any room can stage a file: copies left by an earlier run are no one's now.
        Staging.sweep()
        slots = (defaults.stringArray(forKey: Self.listKey) ?? []).map(makeSlot)
        if slots.isEmpty {
            slots = [makeSlot(UUID().uuidString)]
            saveList()
        }
        sweep()
        let id = defaults.string(forKey: Self.currentKey)
        show(slots.first { $0.id == id } ?? slots[0])
    }

    /// Puts `slot`'s screens in place of the current account's.
    func select(_ slot: Slot) {
        guard slot !== current, slots.contains(where: { $0 === slot }) else { return }
        show(slot)
    }

    /// Starts signing in to another account, over the current one.
    func beginAdding() {
        guard adding == nil else { return }
        adding = makeSlot(UUID().uuidString)
    }

    /// Lets go of the account being added, and anything it was given.
    func cancelAdding() {
        guard let slot = adding else { return }
        adding = nil
        slot.session.close()
        forget(slot)
    }

    /// Signs out of the current account. With others, it's removed and the one used before it comes
    /// back; alone, it shows sign-in for the same server, as it always has.
    func signOut() async {
        guard let slot = current else { return }
        guard let next = fallback(from: slot) else {
            await slot.session.signOut()
            slot.profile = nil
            defaults.removeObject(forKey: Self.profileKey(slot.id))
            return
        }
        remove(slot)
        show(next)
        await slot.session.leave(emptying: true)
        forget(slot)
    }

    /// Whether the current account, which isn't signed in, can be left for another.
    var canLeave: Bool {
        guard let current, current.workspace == nil else { return false }
        return fallback(from: current) != nil
    }

    /// Goes back from the current account's sign-in, or its unreachable server, to the account used
    /// before it. One that can't reach its server stays, as its session may still be good; one with
    /// no one signed in is removed.
    func leave() async {
        guard let slot = current, slot.workspace == nil, let next = fallback(from: slot) else { return }
        if case .unreachable = slot.session.phase {
            show(next)
            return
        }
        remove(slot)
        show(next)
        await slot.session.leave(emptying: true)
        forget(slot)
    }

    // MARK: Private

    private func makeSlot(_ id: String) -> Slot {
        let cookies = makeCookies(id)
        let stores = AccountStores(folders: folders(id))
        let makeClient = makeClient
        let session = SessionController(
            makeClient: { makeClient($0, cookies) },
            defaults: defaults,
            keys: .account(id),
            network: network,
            clock: clock,
            leftOnDevice: .standard(stores: stores, unsent: unsent))
        let profile = defaults.data(forKey: Self.profileKey(id)).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
        let slot = Slot(id: id, session: session, cookies: cookies, stores: stores, profile: profile)
        session.onSignedIn = { [weak self, weak slot] workspace in
            guard let self, let slot else { return }
            self.signedIn(slot, workspace)
        }
        return slot
    }

    private func show(_ slot: Slot) {
        if let leaving = current, leaving !== slot {
            remember(leaving)
            leaving.session.pause()
        }
        // Before the account's screens are made, so every store they read is its own.
        putOnScreen(slot.stores)
        current = slot
        recent.removeAll { $0 == slot.id }
        recent.append(slot.id)
        defaults.set(slot.id, forKey: Self.currentKey)
        slot.session.resume()
    }

    /// Someone signed in on `slot`, or was found signed in there. A second sign-in as someone another
    /// account already is goes to that account instead, and this one is let go without emptying
    /// what that person left. Otherwise the account being added joins the list and comes on screen.
    private func signedIn(_ slot: Slot, _ workspace: Workspace) {
        let who = SessionController.SignedInAccount(origin: workspace.client.origin, userID: workspace.me.id)
        if let existing = slots.first(where: { $0 !== slot && $0.signedIn == who }) {
            if adding === slot { adding = nil } else { remove(slot) }
            if existing.workspace == nil {
                // Its own session has ended, or it's not been asked yet: the new one is handed to
                // it, drafts and stores and all, rather than asking them to sign in again there.
                let origin = workspace.client.origin
                for cookie in existing.cookies.cookies(for: origin) ?? [] { existing.cookies.deleteCookie(cookie) }
                for cookie in slot.cookies.cookies ?? [] { existing.cookies.setCookie(cookie) }
                slot.session.close()
                forget(slot)
                show(existing)
                Task { await existing.session.reconnect(to: origin) }
                return
            }
            show(existing)
            Task {
                await slot.session.leave(emptying: false)
                self.forget(slot)
            }
            return
        }
        slot.profile = Profile(workspace)
        remember(slot)
        if adding === slot {
            adding = nil
            slots.append(slot)
            saveList()
            show(slot)
        }
    }

    /// Keeps what the menu shows of `slot`, as its workspace has it now.
    private func remember(_ slot: Slot) {
        guard let profile = slot.liveProfile else { return }
        slot.profile = profile
        if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.profileKey(slot.id)) }
    }

    /// The account to show when `slot` goes: the one used most recently before it, or else the first.
    private func fallback(from slot: Slot) -> Slot? {
        for id in recent.reversed() where id != slot.id {
            if let other = slots.first(where: { $0.id == id }) { return other }
        }
        return slots.first { $0 !== slot }
    }

    /// Takes `slot` out of the list.
    private func remove(_ slot: Slot) {
        slots.removeAll { $0 === slot }
        recent.removeAll { $0 == slot.id }
        saveList()
    }

    /// Forgets everything kept for `slot` that its session doesn't: its cookies, profile and folders.
    private func forget(_ slot: Slot) {
        slot.cookies.eraseAll()
        for key in SessionController.Keys.account(slot.id).all + [Self.profileKey(slot.id)] {
            defaults.removeObject(forKey: key)
        }
        slot.stores.deleteFolders()
    }

    private func saveList() {
        defaults.set(slots.map(\.id), forKey: Self.listKey)
    }

    /// An account signed in before the app held more than one, under the keys, cookie store and
    /// folders the app used then, becomes the first account, signed in as it was.
    private func adoptUnshared() {
        guard defaults.stringArray(forKey: Self.listKey) == nil,
              let stored = defaults.string(forKey: SessionController.originKey) else { return }
        let id = UUID().uuidString
        let keys = SessionController.Keys.account(id)
        defaults.set(stored, forKey: keys.origin)
        if let account = defaults.object(forKey: SessionController.accountKey) {
            defaults.set(account, forKey: keys.account)
        }
        if let origin = URL(string: stored) {
            let cookies = makeCookies(id)
            for cookie in legacyCookies.cookies(for: origin) ?? [] {
                cookies.setCookie(cookie)
                legacyCookies.deleteCookie(cookie)
            }
        }
        if let from = legacyFolders, let to = folders(id) {
            Self.move(from.drafts, to: to.drafts)
            Self.move(from.pictureSizes, to: to.pictureSizes)
            Self.move(from.files, to: to.files)
        }
        defaults.removeObject(forKey: SessionController.originKey)
        defaults.removeObject(forKey: SessionController.accountKey)
        defaults.set([id], forKey: Self.listKey)
        defaults.set(id, forKey: Self.currentKey)
    }

    private static func move(_ from: URL?, to: URL?) {
        guard let from, let to, FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    /// Erases what's kept for an account that isn't in the list any more, as one whose adding was
    /// cut short by the app being quit: its cookies, keys and folders.
    private func sweep() {
        let ids = Set(slots.map(\.id))
        for id in keptCookies() where !ids.contains(id) {
            makeCookies(id).eraseAll()
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("account.") {
            let id = key.dropFirst("account.".count).prefix { $0 != "." }
            if !ids.contains(String(id)) { defaults.removeObject(forKey: key) }
        }
    }
}

extension SessionController.Keys {
    /// Every key, to remove them all.
    var all: [String] { [origin, account] }
}
