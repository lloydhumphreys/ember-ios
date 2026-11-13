import EmberSDK
import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// What Invite People holds: the addresses being typed, what came of the last ones sent, and the
/// invitations no one has accepted yet, each to send again or revoke.
///
/// An invitation's link is a secret: it's kept here, in memory only, while the server hasn't
/// emailed it, and leaves the app only through the share sheet or the pasteboard when asked.
@MainActor @Observable
final class InviteModel {
    /// Where the pending invitations are.
    enum Loading: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What came of inviting one address.
    struct Outcome: Identifiable, Hashable {
        enum Kind: Hashable {
            /// Someone has an account with it already.
            case member
            /// It was invited, as this invitation.
            case invited(InvitationID)
        }

        var emailAddress: String
        var kind: Kind
        var id: String { emailAddress.lowercased() }

        init(_ outcome: InvitationOutcome) {
            emailAddress = outcome.emailAddress
            switch outcome {
            case .member: kind = .member
            case let .invited(invitation, _): kind = .invited(invitation.id)
            }
        }
    }

    /// The addresses in what's typed, each once as first written, and the words that aren't one.
    struct Addresses: Equatable {
        var valid: [String] = []
        var junk: [String] = []
    }

    /// What's typed in the field. Kept whatever the server answers, until what it holds is invited.
    var text = ""

    private(set) var failure: String?
    private(set) var isSending = false
    private(set) var loading = Loading.idle
    /// What came of the last addresses sent, in the order they were given.
    private(set) var outcomes: [Outcome] = []
    /// The invitations no one has accepted yet, newest first, as the server lists them.
    private(set) var pending: [EmailInvitation] = []
    /// The invitations being sent again or revoked.
    private(set) var working: Set<InvitationID> = []
    /// The links Ember didn't email, by invitation, only as long as the screen is open.
    private var links: [InvitationID: Secret] = [:]
    /// The invitations on their way to being revoked, which a reload mustn't bring back.
    private var revoking: Set<InvitationID> = []
    @ObservationIgnored private var client: EmberClient?

    func attach(_ client: EmberClient) {
        self.client = client
    }

    // MARK: What the screen asks

    /// Whether Send has something to send.
    var canSend: Bool {
        !isSending && !Self.addresses(in: text).valid.isEmpty
    }

    func isWorking(on id: InvitationID) -> Bool {
        working.contains(id)
    }

    /// The link to pass on for `id`, while Ember hasn't emailed it.
    func link(for id: InvitationID) -> Secret? {
        links[id]
    }

    /// The pending invitations Pending lists: those not already under Invited, from this visit.
    var pendingShown: [EmailInvitation] {
        Self.pendingShown(pending, outcomes: outcomes)
    }

    /// The pending invitation `id`, while it's pending.
    func invitation(_ id: InvitationID) -> EmailInvitation? {
        pending.first { $0.id == id }
    }

    /// Correcting what was refused is what clears the complaint about it.
    func clearFailure() {
        failure = nil
    }

    // MARK: Talking to the server

    /// Reads the pending invitations, replacing the list in place: what's shown stays until the
    /// answer comes.
    func reload() async {
        guard let client else { return }
        if loading != .loaded { loading = .loading }
        do {
            let fresh = try await client.invitations()
            pending = fresh.filter { !revoking.contains($0.id) }
            let ids = Set(pending.map(\.id))
            links = links.filter { ids.contains($0.key) }
            loading = .loaded
        } catch {
            let message = Self.message(error)
            if loading == .loaded { failure = message } else { loading = .failed(message) }
        }
    }

    /// Invites the addresses typed. Anything refused, here or by the server, leaves them as typed.
    func send() async {
        guard let client, !isSending else { return }
        let addresses = Self.addresses(in: text)
        if let refusal = Self.refusal(of: addresses) {
            failure = refusal
            return
        }
        let sent = text
        isSending = true
        failure = nil
        defer { isSending = false }
        do {
            let answered = try await client.invite(emailAddresses: addresses.valid)
            var saved: [EmailInvitation] = []
            for case let .invited(invitation, link) in answered {
                saved.append(invitation)
                keep(link, for: invitation.id)
            }
            merge(saved)
            outcomes = answered.map(Outcome.init)
            if text == sent { text = "" }
        } catch {
            failure = Self.message(error)
        }
    }

    /// Sends `id` again with a new link, in place of the old one, which stops working. Returns the
    /// invitation it's now listed as, or nil if it wasn't sent.
    @discardableResult
    func resend(_ id: InvitationID) async -> InvitationID? {
        guard let client, !working.contains(id) else { return nil }
        working.insert(id)
        defer { working.remove(id) }
        do {
            let resent = try await client.resendInvitation(id)
            if resent.invitation.id != id { links[id] = nil }
            keep(resent.link, for: resent.invitation.id)
            merge([resent.invitation])
            return resent.invitation.id
        } catch {
            failure = Self.message(error)
            return nil
        }
    }

    /// Revokes `id`, taking it off the list at once and putting it back if the server refuses.
    func revoke(_ id: InvitationID) async {
        guard let client, !working.contains(id), let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let invitation = pending.remove(at: index)
        working.insert(id)
        revoking.insert(id)
        defer {
            working.remove(id)
            revoking.remove(id)
        }
        do {
            try await client.revokeInvitation(id)
            links[id] = nil
        } catch let error as EmberError where error.status == 404 {
            // Already accepted or revoked: gone either way.
            links[id] = nil
        } catch {
            if !pending.contains(where: { $0.id == id }) {
                pending.insert(invitation, at: min(index, pending.count))
            }
            failure = Self.message(error)
        }
    }

    private func keep(_ link: Secret?, for id: InvitationID) {
        links[id] = link
    }

    private func merge(_ saved: [EmailInvitation]) {
        let before = Set(pending.map(\.id))
        pending = Self.merged(pending, with: saved)
        let after = Set(pending.map(\.id))
        for gone in before.subtracting(after) { links[gone] = nil }
    }

    // MARK: Worked out without the server

    /// `pending` without what `outcomes` has as invited, by id or address, so nothing's listed twice.
    static func pendingShown(_ pending: [EmailInvitation], outcomes: [Outcome]) -> [EmailInvitation] {
        var ids: Set<InvitationID> = []
        var addresses: Set<String> = []
        for outcome in outcomes {
            guard case let .invited(id) = outcome.kind else { continue }
            ids.insert(id)
            addresses.insert(outcome.id)
        }
        return pending.filter { !ids.contains($0.id) && !addresses.contains($0.emailAddress.lowercased()) }
    }

    /// `pending` with each of `saved` in place of what it was, by id or address, newest first.
    static func merged(_ pending: [EmailInvitation], with saved: [EmailInvitation]) -> [EmailInvitation] {
        let ids = Set(saved.map(\.id))
        let addresses = Set(saved.map { $0.emailAddress.lowercased() })
        let kept = pending.filter { !ids.contains($0.id) && !addresses.contains($0.emailAddress.lowercased()) }
        return (saved + kept).sorted(by: newestFirst)
    }

    /// Newest first, as the server lists them: by when their links were made, then by id.
    static func newestFirst(_ a: EmailInvitation, _ b: EmailInvitation) -> Bool {
        a.createdAt == b.createdAt ? a.id.rawValue > b.id.rawValue : a.createdAt > b.createdAt
    }

    /// Whether the email provider refused to send `invitation`'s newest link.
    static func wasRefused(_ invitation: EmailInvitation) -> Bool {
        if case .refused = invitation.delivery { true } else { false }
    }

    /// The addresses in `text`: apart by commas, semicolons, spaces or new lines, each once whatever
    /// its case, as first written. A name before an address in angle brackets, or in quotes, is
    /// left out, so a line pasted from a mail app reads.
    static func addresses(in text: String) -> Addresses {
        let unquoted = text.replacing(/"[^"]*"/, with: " ")
        var words: [String] = []
        for entry in unquoted.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }) {
            words += wordsOf(String(entry))
        }
        var result = Addresses()
        var seen: Set<String> = []
        for word in words {
            if isEmailAddress(word) {
                if seen.insert(word.lowercased()).inserted { result.valid.append(word) }
            } else {
                result.junk.append(word)
            }
        }
        return result
    }

    /// The words of one entry: all but a name before an address in angle brackets.
    private static func wordsOf(_ entry: String) -> [String] {
        var words: [String] = []
        var rest = Substring(entry)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            // What comes before the brackets is the name, but for any address among it.
            words += rest[..<open].split(whereSeparator: \.isWhitespace).map(String.init).filter(isEmailAddress)
            words += rest[rest.index(after: open) ..< close].split(whereSeparator: \.isWhitespace).map(String.init)
            rest = rest[rest.index(after: close)...]
        }
        words += rest.split(whereSeparator: \.isWhitespace).map(String.init)
        return words
    }

    /// Whether `address` is one Ember sends to, as the server judges it: a local part of the
    /// characters RFC 5322 allows unquoted, then a domain of letters, digits and hyphens between dots.
    static func isEmailAddress(_ address: String) -> Bool {
        guard address.utf8.count <= 254 else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let localAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+/=?^_`{|}~-")
        let atoms = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard atoms.allSatisfy({ !$0.isEmpty && $0.allSatisfy(localAllowed.contains) }) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        let labelAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy(labelAllowed.contains)
        }
    }

    /// Why `addresses` can't be sent as they are, or nil when they can.
    static func refusal(of addresses: Addresses) -> String? {
        if addresses.valid.isEmpty, addresses.junk.isEmpty {
            return "Give an email address to invite"
        }
        if !addresses.junk.isEmpty {
            let listed = addresses.junk.joined(separator: ", ")
            return addresses.junk.count == 1 ? "This isn’t an email address: \(listed)" : "These aren’t email addresses: \(listed)"
        }
        if addresses.valid.count > EmailInvitation.mostAtOnce {
            return "Invite at most \(EmailInvitation.mostAtOnce) email addresses at once"
        }
        return nil
    }

    /// What to show of `error`: the server's own message, as the app's other screens show it.
    static func message(_ error: any Error) -> String {
        error.localizedDescription
    }

    // MARK: Passing a link on

    /// How long a copied link stays on the pasteboard.
    static let copiedLinkLifetime: TimeInterval = 10 * 60

    /// The link as a URL, for the share sheet, when it is one.
    static func url(of link: Secret) -> URL? {
        guard let url = URL(string: link.revealed), url.scheme != nil else { return nil }
        return url
    }

    /// Puts `link` on `pasteboard`, on this device only, until it expires.
    static func copy(_ link: Secret, to pasteboard: UIPasteboard = .general, now: Date = .now) {
        pasteboard.setItems(pasteboardItems(for: link), options: pasteboardOptions(now: now))
    }

    static func pasteboardItems(for link: Secret) -> [[String: Any]] {
        var item: [String: Any] = [UTType.utf8PlainText.identifier: link.revealed]
        if let url = url(of: link) { item[UTType.url.identifier] = url }
        return [item]
    }

    static func pasteboardOptions(now: Date) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(copiedLinkLifetime)]
    }
}
