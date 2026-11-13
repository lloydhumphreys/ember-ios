import Foundation
import UIKit
import EmberSDK

/// Whose composer a draft belongs to: a room's, or one of its threads', for someone signed in to a
/// server.
struct DraftKey: Hashable, Sendable {
    let server: String
    let user: UserID
    let room: RoomID
    /// The thread's first message, for a reply; nil for the room itself.
    var thread: MessageID? = nil

    /// The key as it's written to disk.
    var storageKey: String {
        [server, user.rawValue, room.rawValue, thread?.rawValue ?? ""].joined(separator: " ")
    }
}

/// What someone has written and not sent: the text as the field has it, and who it mentions, each
/// by their id and the name the text writes after "@".
struct Draft: Codable, Equatable, Sendable {
    var text = ""
    var mentions: [UserID: String] = [:]

    var isEmpty: Bool { text.isEmpty }

    /// The draft with only the mentions whose "@" and name are still somewhere in the text.
    var pruned: Draft {
        var draft = self
        draft.mentions = mentions.filter { text.contains("@" + $0.value) }
        return draft
    }
}

/// Every composer's unsent work: drafts kept on disk across launches until they're sent or emptied,
/// and the files staged in each, kept in memory so they're still there on coming back to the room
/// or thread (but not after the app is quit, when a launch sweeps their copies away).
@MainActor @Observable final class Drafts {
    static var shared: Drafts { AccountStores.current.drafts }

    /// Every draft with something in it, by `DraftKey.storageKey`.
    private(set) var drafts: [String: Draft]

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var staged: [DraftKey: StagedFiles] = [:]
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var backgrounding: Task<Void, Never>?

    /// Drafts read from `file`, saved back to it; nil keeps them in memory alone.
    init(file: URL?) {
        self.file = file
        drafts = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Draft].self, from: $0) } ?? [:]
        guard file != nil else { return }
        backgrounding = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.save()
            }
        }
    }

    isolated deinit {
        backgrounding?.cancel()
        saving?.cancel()
    }

    func draft(for key: DraftKey) -> Draft {
        drafts[key.storageKey] ?? Draft()
    }

    /// Keeps `draft` for `key`, without the mentions its text no longer has; an empty one is
    /// forgotten. Written to disk a moment later, so typing isn't a write per key.
    func set(_ draft: Draft, for key: DraftKey) {
        let pruned = draft.pruned
        let storageKey = key.storageKey
        guard drafts[storageKey] ?? Draft() != pruned else { return }
        drafts[storageKey] = pruned.isEmpty ? nil : pruned
        scheduleSave()
    }

    func clear(_ key: DraftKey) {
        set(Draft(), for: key)
    }

    /// The files staged in `key`'s composer, made the first time it's asked for.
    func staged(for key: DraftKey) -> StagedFiles {
        if let files = staged[key] { return files }
        let files = StagedFiles()
        staged[key] = files
        return files
    }

    /// Forgets every draft, on disk too, and lets go of every composer's staged files, as signing
    /// out should. The files themselves go, and their copies stop, when the last composer still
    /// holding them does (`StagedFiles`' deinit).
    func removeAll() {
        drafts = [:]
        staged = [:]
        saving?.cancel()
        saving = nil
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes the drafts to disk now.
    func save() {
        saving?.cancel()
        saving = nil
        guard let file else { return }
        guard !drafts.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func scheduleSave() {
        guard file != nil, saving == nil else { return }
        saving = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.save()
        }
    }
}
