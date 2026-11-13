import Foundation
import EmberSDK
import os

/// Everything the app keeps on this device from a server while someone is signed in: what they were
/// typing, the messages, pictures and files they saw, and where they were. Signing out, the server
/// ending the session, and forgetting the server each empty all of it, so anything new the app
/// keeps belongs in `standard`.
struct LeftOnDevice {
    /// One thing kept, and how to empty it of what came from the server at an origin, for the
    /// person signed in there when they're known.
    struct Store {
        let name: String
        let empty: @MainActor (_ origin: URL, _ userID: UserID?) -> Void
    }

    var stores: [Store]

    /// Empties every store of what came from `origin`, and of what `userID` left unsent there.
    @MainActor func empty(for origin: URL, userID: UserID?) {
        for store in stores { store.empty(origin, userID) }
    }

    /// What the app keeps for the account on screen, with unsent messages where a room on the
    /// network keeps them.
    @MainActor static var standard: LeftOnDevice {
        standard(stores: .current, removals: UnsentRemovals(unsent: FileUnsentMessageStore.shared))
    }

    /// What the app keeps for the account on screen, with unsent messages in `unsent` and any
    /// removal of them that fails noted in `defaults`.
    @MainActor static func standard(unsent: any UnsentMessageStore, defaults: UserDefaults = .standard) -> LeftOnDevice {
        standard(stores: .current, removals: UnsentRemovals(unsent: unsent, defaults: defaults))
    }

    /// What the app keeps for the account whose stores are `stores`, with unsent messages removed
    /// through `removals`. Unsent messages and places are kept for each person on each server, so
    /// another account's are left alone.
    @MainActor static func standard(stores: AccountStores, removals: UnsentRemovals) -> LeftOnDevice {
        LeftOnDevice(stores: [
            Store(name: "Drafts") { _, _ in stores.drafts.removeAll() },
            Store(name: "Unsent messages") { origin, userID in
                if let userID { removals.remove(server: origin, userID: userID) }
            },
            Store(name: "Messages and downloaded files") { _, _ in stores.documents.reset() },
            Store(name: "Pictures in messages") { _, _ in stores.remoteImages.reset() },
            Store(name: "Pictures on cards") { _, _ in stores.cardImages.reset() },
            Store(name: "Picture sizes") { _, _ in stores.pictureSizes.reset() },
            Store(name: "Staged thumbnails") { _, _ in stores.stagedThumbnails.reset() },
            Store(name: "Avatars") { _, _ in stores.avatars.removeAll() },
            Store(name: "Unfolded messages") { _, _ in stores.folds.removeAll() },
            Store(name: "Changes that failed") { _, _ in stores.sentChanges.removeAll() },
            Store(name: "People and room lists") { _, _ in stores.pickerLists.removeAll() },
            Store(name: "Where you were") { origin, userID in
                if let userID { HomePlaces().forget(origin: origin, userID: userID) }
            },
        ])
    }
}

/// Removes the unsent messages of someone who signed out, through the SDK's writer, so saves still
/// waiting for them are dropped. Each removal is noted in `defaults` until it's done, so one that
/// fails, or that the app quits before, is tried again by `retry()`: at launch and each time the
/// app comes to the front. One owed by someone signed in again is never tried again, as it would
/// take what they've left unsent since.
@MainActor final class UnsentRemovals {
    struct Owed: Codable, Hashable {
        let server: URL
        let userID: UserID
    }

    static let key = "unsentRemovalsOwed"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Ember", category: "UnsentRemovals")

    let unsent: any UnsentMessageStore
    let defaults: UserDefaults
    /// Whether someone is signed in now, so a retry leaves their messages alone.
    var isSignedIn: @MainActor (Owed) -> Bool = { _ in false }
    /// Removals started and not yet finished, so a retry doesn't start a second.
    private var running: Set<Owed> = []

    init(unsent: any UnsentMessageStore, defaults: UserDefaults = .standard) {
        self.unsent = unsent
        self.defaults = defaults
    }

    /// The removals noted and not yet done.
    var owed: [Owed] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Owed].self, from: $0) } ?? []
    }

    /// Notes the removal of `userID`'s unsent messages on `server`, then starts it.
    func remove(server: URL, userID: UserID) {
        let removal = Owed(server: server, userID: userID)
        if !owed.contains(removal) { save(owed + [removal]) }
        start(removal)
    }

    /// Starts every removal noted and not done, but for anyone signed in now.
    func retry() {
        for removal in owed where !isSignedIn(removal) { start(removal) }
    }

    /// `userID` signed in on `server`. A removal they're owed is started now, before anything they
    /// type can be saved, and is no longer noted: once it's begun, what's saved is theirs again.
    func signedIn(server: URL, userID: UserID) {
        let removal = Owed(server: server, userID: userID)
        guard owed.contains(removal) else { return }
        save(owed.filter { $0 != removal })
        start(removal)
    }

    /// Waits for the removals started to finish, for tests.
    func settled() async {
        while !running.isEmpty { await Task.yield() }
    }

    private func start(_ removal: Owed) {
        guard running.insert(removal).inserted else { return }
        Task {
            defer { running.remove(removal) }
            do {
                try await unsent.discardUnsent(server: removal.server, userID: removal.userID)
                save(owed.filter { $0 != removal })
            } catch {
                // Kept in `owed`. Only the kind of failure is logged, never the ids.
                let kind = (error as? UnsentStoreError).map { "\($0.kind)" } ?? String(describing: type(of: error))
                Self.log.error("Couldn’t remove an account’s unsent messages: \(kind, privacy: .public)")
            }
        }
    }

    private func save(_ owed: [Owed]) {
        if owed.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(owed) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
