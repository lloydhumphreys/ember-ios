import Foundation
import EmberSDK
import EmberRichText

/// A message being edited: the message as it was when the edit began, and its body read for the
/// composer's field, so a save changes only what the edit touched and keeps the rest's formatting.
/// Made once when the edit begins, not on every keystroke.
struct MessageEdit {
    let message: Message
    let editable: EditableBody

    /// `nameOf` is how the timeline names someone, so a mention reads in the field as it shows.
    init(_ message: Message, nameOf: (User) -> String = \.name) {
        self.message = message
        var names: [UserID: String] = [:]
        for user in message.mentions { names[user.id] = nameOf(user) }
        mentioned = names
        editable = EditableBody(body: message.body, mentionNames: names)
    }

    /// Who the message mentions, each by their id and the name the field writes after "@".
    let mentioned: [UserID: String]

    var id: MessageID { message.id }

    /// What the field starts with.
    var text: String { editable.text }

    /// The body to save for `draft`, or nil when there's nothing to save.
    func body(for draft: String) -> String? {
        body(for: Draft(text: draft))
    }

    /// The body to save for `draft`, or nil when it's blank or would save the body the message
    /// has. Each "@" and name of someone chosen while editing becomes a mention of them, as
    /// composing makes one; the mentions the message has stay as they are.
    func body(for draft: Draft) -> String? {
        guard let text = Self.savedText(draft.text, from: editable.text) else { return nil }
        let body = editable.body(editedTo: text, mentions: draft.pruned.mentions)
        return body == message.body ? nil : body
    }

    /// Whether `draft` has something to save, without building the body while only its text has
    /// changed, as that alone always does.
    func canSave(_ draft: Draft) -> Bool {
        if Self.editedText(draft.text, from: editable.text) != nil { return true }
        return !draft.pruned.mentions.isEmpty && body(for: draft) != nil
    }

    /// The name being typed after "@" at `caret` (the end when nil) in `draft`, as composing finds
    /// one, with the names the message mentions counted as chosen. None until the draft is
    /// something other than the message's text, so starting to edit a message that ends in a name
    /// suggests nobody.
    func mentionQuery(in draft: Draft, caret: String.Index? = nil) -> MentionQuery? {
        guard draft.text != text else { return nil }
        return MentionQuery.active(in: draft.text, caret: caret, chosen: Array(draft.mentions.values) + mentioned.values)
    }

    /// The text an edit saves for `draft` typed over `text`, or nil when the draft is blank or the
    /// same as `text` once both are trimmed. The ends are never part of an edit: `text`'s own
    /// leading and trailing white space stands in for the draft's, so a stray space the keyboard
    /// left at the end neither counts as a change nor goes into the body.
    static func editedText(_ draft: String, from text: String) -> String? {
        let space = CharacterSet.whitespacesAndNewlines
        guard draft.trimmingCharacters(in: space) != text.trimmingCharacters(in: space) else { return nil }
        return savedText(draft, from: text)
    }

    /// `draft` with `text`'s own white space at its ends, or nil when it's blank: what an edit
    /// saves, whether or not that's `text` again.
    static func savedText(_ draft: String, from text: String) -> String? {
        let space = CharacterSet.whitespacesAndNewlines
        let trimmed = draft.trimmingCharacters(in: space)
        guard !trimmed.isEmpty else { return nil }
        // Trimmed by scalar, as `trimmingCharacters` trims.
        let scalars = text.unicodeScalars
        let leading = scalars.prefix { space.contains($0) }
        let trailing = scalars.dropFirst(leading.count).reversed().prefix { space.contains($0) }
        var out = ""
        out.unicodeScalars.append(contentsOf: leading)
        out += trimmed
        out.unicodeScalars.append(contentsOf: trailing.reversed())
        return out
    }
}
