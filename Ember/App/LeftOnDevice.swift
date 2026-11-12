import Foundation
import EmberSDK

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
    @MainActor static var standard: LeftOnDevice { standard(stores: .current, unsent: FileUnsentMessageStore()) }

    /// What the app keeps for the account on screen, with unsent messages in `unsent`.
    @MainActor static func standard(unsent: any UnsentMessageStore) -> LeftOnDevice {
        standard(stores: .current, unsent: unsent)
    }

    /// What the app keeps for the account whose stores are `stores`, with unsent messages in
    /// `unsent`. Unsent messages and places are kept for each person on each server, so another
    /// account's are left alone.
    @MainActor static func standard(stores: AccountStores, unsent: any UnsentMessageStore) -> LeftOnDevice {
        LeftOnDevice(stores: [
            Store(name: "Drafts") { _, _ in stores.drafts.removeAll() },
            Store(name: "Unsent messages") { origin, userID in
                if let userID { unsent.removeAll(server: origin, userID: userID) }
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
