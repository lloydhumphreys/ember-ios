import Foundation
import EmberSDK
import EmberRichText

/// What a message's row shows of its text, as the web's `message-item.tsx` decides it: the body,
/// unless a bot sent only cards; and where neither the body nor any card has anything to draw
/// (cards of kinds this build doesn't know), the plain text, which holds what the cards said.
enum MessageText: Equatable {
    case none
    case body
    case plainText

    static func of(_ message: Message, document: RichDocument, shownCards: [Card]) -> MessageText {
        let hasCards = !(message.cards ?? []).isEmpty
        if !document.blocks.isEmpty { return message.body.isEmpty && hasCards ? .none : .body }
        // Nothing to draw: a bot's cards this build can't show (which the SDK leaves out) still
        // said something. A file message's plain text is its file's name, which its row shows.
        if message.attachment == nil, shownCards.isEmpty, !message.plainText.isEmpty { return .plainText }
        return .none
    }
}

/// Who may change a message, as the web's menu has it: its author and any administrator may
/// delete it, and edit it too unless it carries a file or cards, whose text stays as sent.
struct MessageChanges: Equatable {
    var canEdit: Bool
    var canDelete: Bool

    static func of(_ message: Message, myID: UserID, isAdministrator: Bool) -> MessageChanges {
        let mayChange = message.creator.id == myID || isAdministrator
        let fixed = message.attachment != nil || !(message.cards ?? []).isEmpty
        return MessageChanges(canEdit: mayChange && !fixed, canDelete: mayChange)
    }
}

/// How a message shows its file, as the web's `Attachment` does where iOS can follow it: a picture
/// from its preview, or from the file itself when it's a picture any browser shows, of a known
/// size of at most 250 megapixels and at most 5 MiB; a video by its poster; anything else (an SVG
/// among them, which iOS can't draw) as its row.
enum AttachmentDisplay: Equatable {
    case picture(path: String)
    case row

    static let maxBytes = 5 * 1024 * 1024
    static let maxPixels = 250_000_000
    private static let webImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func of(_ file: StoredFile) -> AttachmentDisplay {
        if file.contentType == "image/svg+xml" { return .row }
        if file.isVideo { return file.previewUrl.map { .picture(path: $0) } ?? .row }
        if let preview = file.previewUrl { return .picture(path: preview) }
        if webImageTypes.contains(file.contentType), file.byteSize <= maxBytes,
           let width = file.width, let height = file.height, width > 0, height > 0, width * height <= maxPixels {
            return .picture(path: file.url)
        }
        return .row
    }
}

// MARK: - Cards

/// A card's frame is narrow at 400 points or less, as the web's container query has it: its fields
/// take one column and a section's button goes under its text.
enum CardWidth {
    static let narrowest: CGFloat = 400
    static func isNarrow(_ width: CGFloat) -> Bool { width <= narrowest }
}

/// What colours the bar down an attachment's leading side.
enum CardBar: Equatable {
    case separator, green, orange, red
    case rgb(red: Double, green: Double, blue: Double)

    /// Nil for a card of blocks, which has no bar.
    static func of(_ card: Card) -> CardBar? {
        guard card.source == .attachment else { return nil }
        switch card.accent {
        case .good: return .green
        case .warning: return .orange
        case .danger: return .red
        case let .rgb(red, green, blue): return .rgb(red: red, green: green, blue: blue)
        case nil: return .separator
        }
    }
}

/// A card's fields in rows: short ones two to a row in the wide frame, the rest on a row of their own,
/// placed as a CSS grid places them (a full-width field starts a new row, leaving a gap beside a short one).
enum CardFieldRows {
    static func rows(_ fields: [CardField], columns: Int) -> [[CardField]] {
        guard columns > 1 else { return fields.map { [$0] } }
        var rows: [[CardField]] = []
        var current: [CardField] = []
        for field in fields {
            if !field.short {
                if !current.isEmpty { rows.append(current); current = [] }
                rows.append([field])
            } else {
                current.append(field)
                if current.count == columns { rows.append(current); current = [] }
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

/// A footer's line: its text and its moment, in the reader's zone and locale, with a dot between. The
/// moment is its date and, as the web's footer has it, its time as the message's own row shows one:
/// hour and minute, from the same fields, so the two read alike.
enum CardFooterText {
    static let format = Date.FormatStyle().year().month(.abbreviated).day().hour().minute()

    static func text(_ text: String?, at: Date?, format: Date.FormatStyle = format) -> String {
        [text, at.map { $0.formatted(format) }].compactMap(\.self).joined(separator: " · ")
    }
}

/// Whether a card's text folds behind Show more, and which way its button reads.
struct CardFold: Equatable {
    let isLong: Bool
    var isOpen = false

    init(isLong: Bool, isOpen: Bool = false) {
        self.isLong = isLong
        self.isOpen = isOpen
    }

    init(html: String) { self.init(isLong: CardText.isLong(html: html)) }

    /// The button's title, or nil when the text is short and shows whole.
    var buttonTitle: String? {
        guard isLong else { return nil }
        return isOpen ? "Show less" : "Show more"
    }

    var isClipped: Bool { isLong && !isOpen }

    /// How many lines folded text shows, as the web clamps it.
    static let shownLines = 5

    /// The height that shows folded text's first `lines` lines whole, cutting under the last of them
    /// and through no other: the bottom of the `lines`th row, where a row is lines whose spans overlap
    /// (a list's number and its item's first line, side by side, are one). Each span is a line's
    /// typographic top and bottom, in the text's own space. Nil when there are no lines.
    static func height(lineSpans spans: [ClosedRange<CGFloat>], lines: Int = shownLines) -> CGFloat? {
        var rows: [ClosedRange<CGFloat>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            // Lines that only touch, as one line under another in a paragraph does, are two rows.
            if let last = rows.last, span.lowerBound < last.upperBound - 0.5 {
                rows[rows.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                rows.append(span)
            }
        }
        guard !rows.isEmpty else { return nil }
        return rows[min(lines, rows.count) - 1].upperBound.rounded(.up)
    }
}
