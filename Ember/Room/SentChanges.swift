import SwiftUI
import EmberSDK

/// Edits, deletions and boosts sent through the room's `async` calls, which say whether the room
/// made them. One of each kind goes at a time for a message, so a second tap while the first is on
/// its way does nothing; one the room refused, didn't answer or couldn't be reached for is kept,
/// to show where it was asked for and to send again. Kept outside the rows, which the timeline
/// makes and throws away.
@MainActor @Observable final class SentChanges {
    static var shared: SentChanges { AccountStores.current.sentChanges }

    /// What a change is to, and what it does.
    struct Key: Hashable {
        enum Kind: Hashable {
            case edit
            case delete
            /// Boosting with this content.
            case boost(String)
            /// Taking back the boost with this id.
            case removeBoost(String)
        }

        let messageID: String
        let kind: Kind

        static func edit(_ messageID: String) -> Key { Key(messageID: messageID, kind: .edit) }
        static func delete(_ messageID: String) -> Key { Key(messageID: messageID, kind: .delete) }
        static func boost(_ messageID: String, _ content: String) -> Key { Key(messageID: messageID, kind: .boost(Limits.trimmedBoost(content))) }
        static func removeBoost(_ messageID: String, _ boostID: String) -> Key { Key(messageID: messageID, kind: .removeBoost(boostID)) }

        /// Whether `message`, as shown to `me`, has this change made. An edit isn't told apart from
        /// one made by someone else, so never counts.
        func isShown(in message: Message, me: UserID) -> Bool {
            guard message.id == messageID else { return false }
            switch kind {
            case .edit: return false
            case .delete: return message.isDeleted
            case .boost(let content):
                return message.boosts.contains { $0.booster.id == me && Limits.trimmedBoost($0.content) == content }
            case .removeBoost(let boostID): return !message.boosts.contains { $0.id == boostID }
            }
        }
    }

    enum State: Equatable {
        case sending
        case failed
    }

    private(set) var states: [Key: State] = [:]
    /// What each change sends, kept for Retry.
    @ObservationIgnored private var changes: [Key: @MainActor () async throws -> Void] = [:]
    /// Whether the room already shows each change made, kept for Retry.
    @ObservationIgnored private var dones: [Key: @MainActor () -> Bool] = [:]
    /// The order changes failed in, so a message's failures show in it. Watched, so a message with
    /// none shows the first as it comes.
    private var failedOrder: [Key] = []
    /// The latest sending of each change, so one dismissed and sent again isn't settled by the
    /// answer to the first.
    @ObservationIgnored private var attempts: [Key: Int] = [:]
    @ObservationIgnored private var nextAttempt = 0

    init() {}

    /// Sends `change` unless the same change is on its way. True once the room has made it, or
    /// when `isDone` says the room already shows it made; false when it was already on its way,
    /// or failed and is kept for `retry`.
    @discardableResult
    func send(
        _ key: Key,
        isDone: @escaping @MainActor () -> Bool = { false },
        _ change: @escaping @MainActor () async throws -> Void
    ) async -> Bool {
        guard states[key] != .sending else { return false }
        if isDone() {
            dismiss(key)
            return true
        }
        nextAttempt += 1
        let attempt = nextAttempt
        attempts[key] = attempt
        changes[key] = change
        dones[key] = isDone
        states[key] = .sending
        failedOrder.removeAll { $0 == key }
        do {
            try await change()
            guard attempts[key] == attempt else { return true }
            dismiss(key)
            return true
        } catch {
            // Dismissed or sent again meanwhile: the later one decides what's kept.
            guard attempts[key] == attempt, states[key] == .sending else { return false }
            if isDone() {
                dismiss(key)
                return true
            }
            states[key] = .failed
            failedOrder.append(key)
            return false
        }
    }

    /// `send`, from a button.
    func start(
        _ key: Key,
        isDone: @escaping @MainActor () -> Bool = { false },
        _ change: @escaping @MainActor () async throws -> Void
    ) {
        Task { await send(key, isDone: isDone, change) }
    }

    /// Sends a failed change again, or lets it go if the room shows it made meanwhile.
    @discardableResult
    func retry(_ key: Key) async -> Bool {
        guard states[key] == .failed, let change = changes[key] else { return false }
        return await send(key, isDone: dones[key] ?? { false }, change)
    }

    /// Forgets a failed change, or stops waiting to show one on its way.
    func dismiss(_ key: Key) {
        states[key] = nil
        changes[key] = nil
        dones[key] = nil
        attempts[key] = nil
        failedOrder.removeAll { $0 == key }
    }

    /// Forgets every change, as after signing out: a failed one holds the room it was sent to and
    /// the text it sent.
    func removeAll() {
        states = [:]
        changes = [:]
        dones = [:]
        attempts = [:]
        failedOrder = []
    }

    func isSending(_ key: Key) -> Bool { states[key] == .sending }

    func hasFailed(_ key: Key) -> Bool { states[key] == .failed }

    /// Whether a deletion or boost of the message with this id is on its way. An edit on its way
    /// shows in the composer.
    func isSendingChange(to messageID: String) -> Bool {
        states.contains { $0.key.messageID == messageID && $0.key.kind != .edit && $0.value == .sending }
    }

    /// The failed deletions and boosts of `message`, in the order they failed, but for those it
    /// already shows made: an answer that came after the wait ran out. An edit's failure shows in
    /// the composer, where its text still is.
    func failures(of message: Message, me: UserID) -> [Key] {
        failedOrder.filter {
            $0.messageID == message.id && $0.kind != .edit && states[$0] == .failed && !$0.isShown(in: message, me: me)
        }
    }

    /// Lets go of the failed changes `message` already shows made.
    func settle(_ message: Message, me: UserID) {
        for key in failedOrder where key.messageID == message.id && key.isShown(in: message, me: me) {
            dismiss(key)
        }
    }

    /// What a failed change says, before its Retry.
    static func failureText(_ kind: Key.Kind) -> String {
        switch kind {
        case .edit: "Couldn’t save."
        case .delete: "Couldn’t delete."
        case .boost: "Couldn’t react."
        case .removeBoost: "Couldn’t remove reaction."
        }
    }
}

/// A message's failed deletions and boosts, each with Retry and a way to let it go, under the
/// message, as a message that didn't send shows its failure.
/// One the message comes to show made goes by itself.
struct ChangeFailures: View {
    let message: Message
    let me: UserID

    var body: some View {
        let changes = SentChanges.shared
        ForEach(changes.failures(of: message, me: me), id: \.self) { key in
            HStack(spacing: 12) {
                Label(SentChanges.failureText(key.kind), systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Retry") { Task { await changes.retry(key) } }
                    .font(.footnote.weight(.semibold))
                Button("Dismiss", systemImage: "xmark") { changes.dismiss(key) }
                    .labelStyle(.iconOnly)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: message, initial: true) { changes.settle(message, me: me) }
        // The newest failure, said as it happens; not those already there when the row shows again.
        .announcesWhenShown(changes.failures(of: message, me: me).last.map { SentChanges.failureText($0.kind) })
    }
}

/// A small spinner beside a message whose deletion or boost is still on its way after a moment,
/// as one waiting out a reconnection. One answered at once doesn't flash it.
struct ChangeWaiting: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .opacity(isShown ? 1 : 0)
            .task {
                try? await Task.sleep(for: .seconds(1))
                withAnimation { isShown = true }
            }
    }
}
