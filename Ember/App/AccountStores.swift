import Foundation

/// What the app keeps for one signed-in account: drafts, the messages, pictures and files it saw,
/// and what it's in the middle of. Each account has its own, in folders of its own, so two accounts
/// never read or empty each other's.
///
/// Every store's `shared` is the one in `current`, the account on screen, which `Accounts` sets
/// before that account's screens are made. Anything that starts on one account's screen holds the
/// store it started with, so a switch doesn't move it to the next account's.
@MainActor final class AccountStores {
    /// The account on screen's. Until `Accounts` sets one, and in tests, stores in the folders the
    /// app used before it held more than one account, made only if they're read.
    static var current: AccountStores {
        get { chosen ?? unshared }
        set { chosen = newValue }
    }

    private static var chosen: AccountStores?
    private static let unshared = AccountStores(folders: .unshared)

    /// Where an account's stores keep what outlives the app.
    struct Folders: Equatable {
        /// Drafts, kept until they're sent.
        let support: URL?
        /// Downloaded files and picture sizes, which the system may clear.
        let caches: URL

        /// The folders the app used before it held more than one account: an account found signed
        /// in from then moves out of them.
        static var unshared: Folders {
            Folders(
                support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                caches: URL.cachesDirectory)
        }

        /// The account `id`'s own.
        static func account(_ id: String) -> Folders {
            Folders(
                support: unshared.support?.appending(path: "Accounts/\(id)", directoryHint: .isDirectory),
                caches: URL.cachesDirectory.appending(path: "Accounts/\(id)", directoryHint: .isDirectory))
        }

        var drafts: URL? { support?.appending(path: "Drafts.json") }
        var files: URL { caches.appending(path: "Files", directoryHint: .isDirectory) }
        var pictureSizes: URL { caches.appending(path: "PictureSizes.json") }
    }

    let folders: Folders
    let drafts: Drafts
    let documents: DocumentCache
    let remoteImages: RemoteImages
    let cardImages: CardImages
    let pictureSizes: PictureSizes
    let stagedThumbnails: StagedThumbnails
    let avatars: AvatarImages
    let folds: MessageFolds
    let sentChanges: SentChanges
    let pickerLists: PickerLists

    /// `folders` nil keeps everything in memory alone, for tests.
    init(folders: Folders?) {
        self.folders = folders ?? Folders(support: nil, caches: URL.temporaryDirectory.appending(path: "Accounts/\(UUID().uuidString)"))
        drafts = Drafts(file: folders?.drafts)
        documents = DocumentCache(files: self.folders.files)
        remoteImages = RemoteImages()
        cardImages = CardImages()
        pictureSizes = PictureSizes(file: folders?.pictureSizes)
        stagedThumbnails = StagedThumbnails()
        avatars = AvatarImages()
        folds = MessageFolds()
        sentChanges = SentChanges()
        pickerLists = PickerLists()
    }

    /// Deletes this account's folders, once its stores have been emptied.
    func deleteFolders() {
        guard folders != .unshared else { return }
        if let support = folders.support { try? FileManager.default.removeItem(at: support) }
        try? FileManager.default.removeItem(at: folders.caches)
    }
}
