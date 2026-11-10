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
        var names: [String: String] = [:]
        for user in message.mentions { names[user.id] = nameOf(user) }
        editable = EditableBody(body: message.body, mentionNames: names)
    }

    var id: String { message.id }

    /// What the field starts with.
    var text: String { editable.text }

    /// The body to save for `draft`, or nil when there's nothing to save.
    func body(for draft: String) -> String? {
        Self.editedText(draft, from: editable.text).map(editable.body(editedTo:))
    }

    /// The text an edit saves for `draft` typed over `text`, or nil when the draft is blank or the
    /// same as `text` once both are trimmed. The ends are never part of an edit: `text`'s own
    /// leading and trailing white space stands in for the draft's, so a stray space the keyboard
    /// left at the end neither counts as a change nor goes into the body.
    static func editedText(_ draft: String, from text: String) -> String? {
        let space = CharacterSet.whitespacesAndNewlines
        let trimmed = draft.trimmingCharacters(in: space)
        guard !trimmed.isEmpty, trimmed != text.trimmingCharacters(in: space) else { return nil }
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
