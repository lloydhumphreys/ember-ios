import Foundation
import EmberSDK

/// A name being typed after "@", which the composer suggests people for: from the "@" to the caret.
struct MentionQuery: Equatable {
    /// From the "@" to the caret.
    let range: Range<String.Index>
    /// What's been typed after the "@".
    let text: String

    /// The longest a name being typed can run before it no longer reads as one.
    static let longest = 40

    /// How many people the composer suggests at once.
    static let limit = 5

    /// The name being typed at `caret` (the end when nil) in `text`: an "@" at the start or after
    /// something that isn't a letter or digit, then up to `longest` characters on one line. None
    /// when the "@" starts a mention already chosen (one of `chosen`, the names mentioned), whole or
    /// with something other than a letter or digit after it, so a chosen name isn't asked about again.
    static func active(in text: String, caret: String.Index? = nil, chosen: some Collection<String> = []) -> MentionQuery? {
        let caret = min(caret ?? text.endIndex, text.endIndex)
        var index = caret
        var count = 0
        while index > text.startIndex, count <= longest {
            let before = text.index(before: index)
            let character = text[before]
            if character.isNewline { return nil }
            if character == "@" {
                if before > text.startIndex {
                    let previous = text[text.index(before: before)]
                    if previous.isLetter || previous.isNumber { return nil }
                }
                let typed = String(text[index..<caret])
                if chosen.contains(where: { name in
                    guard !name.isEmpty, typed.hasPrefix(name) else { return false }
                    guard typed.count > name.count else { return true }
                    let next = typed[typed.index(typed.startIndex, offsetBy: name.count)]
                    return !(next.isLetter || next.isNumber)
                }) { return nil }
                return MentionQuery(range: before..<caret, text: typed)
            }
            index = before
            count += 1
        }
        return nil
    }

    /// Who to suggest for `query`: people still active, other than `me`, with a word of their name
    /// that starts with what's typed, whatever its case or accents, the first `limit`. People come
    /// before bots; within each, those in `first` before everyone else, then by name and id.
    static func candidates(_ people: some Sequence<DirectoryUser>, matching query: String, first: Set<UserID> = [], excluding me: UserID? = nil, limit: Int = limit) -> [DirectoryUser] {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let matching = people.filter { person in
            person.status == .active && person.id != me && (typed.isEmpty || wordStarts(in: person.name, with: typed))
        }
        func order(_ person: DirectoryUser) -> (Int, Int, String, UserID) {
            (person.role == .bot ? 1 : 0, first.contains(person.id) ? 0 : 1, person.name.lowercased(), person.id)
        }
        return Array(matching.sorted { order($0) < order($1) }.prefix(limit))
    }

    /// Whether a word of `name` starts with `typed`, which may run on into the next word ("Sam R"):
    /// a word starting at a letter or digit that isn't after another, so "Mary-Jane" has "Jane".
    static func wordStarts(in name: String, with typed: String) -> Bool {
        var previous: Character?
        for index in name.indices {
            let character = name[index]
            defer { previous = character }
            if let previous, previous.isLetter || previous.isNumber { continue }
            guard character.isLetter || character.isNumber else { continue }
            if name.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive], range: index..<name.endIndex, locale: .current) != nil {
                return true
            }
        }
        return false
    }

    /// `draft` with this query replaced by `name` mentioning `id`, and where the caret goes next.
    /// A space follows the name, and the caret goes after it, unless something other than a letter
    /// or digit is already there: the caret goes past a space or tab, or stays at the name's end
    /// before a line break or punctuation, which reads against the name.
    func choosing(_ id: UserID, name: String, in draft: Draft) -> (draft: Draft, caret: String.Index) {
        let text = draft.text
        let following = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        let spaced = following.map { $0.isLetter || $0.isNumber } ?? true
        let inserted = "@" + name + (spaced ? " " : "")
        let past = following.map { $0.isWhitespace && !$0.isNewline } ?? false
        var next = draft
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        next.text.replaceSubrange(range, with: inserted)
        next.mentions[id] = name
        let caret = next.text.index(next.text.startIndex, offsetBy: start + inserted.count + (past ? 1 : 0))
        return (next, caret)
    }
}
