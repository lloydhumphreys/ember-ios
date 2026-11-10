import Foundation
import EmberSDK
import EmberRichText

/// Message bodies, read into documents once each. Reading HTML on every redraw of a long room
/// would be the slowest thing it does; a message's `updatedAt` changes with an edit, which reads
/// it again.
@MainActor final class DocumentCache {
    static let shared = DocumentCache()

    private let documents = NSCache<NSString, Box>()

    private init() {
        documents.countLimit = 1_000
        cardDocuments.countLimit = 2_000
        shownCards.countLimit = 500
    }

    func document(for message: Message, host: String) -> RichDocument {
        document(key: "\(host)|\(message.id)|\(message.updatedAt.timeIntervalSince1970)", html: message.body, plainText: message.plainText, host: host)
    }

    func document(for pending: PendingMessage, host: String) -> RichDocument {
        document(key: "\(host)|pending|\(pending.clientMessageId)", html: pending.body, plainText: pending.plainText, host: host)
    }

    private func document(key: String, html: String, plainText: String, host: String) -> RichDocument {
        if let box = documents.object(forKey: key as NSString) { return box.document }
        let document = RichText.document(html: html, plainText: plainText, host: host)
        documents.setObject(Box(document), forKey: key as NSString)
        return document
    }

    // MARK: Cards

    private let cardDocuments = NSCache<NSString, CardTextBox>()
    private let shownCards = NSCache<NSString, CardsBox>()

    /// A card's rich text (a text part, a field, a cell, a tile's body) read once per host, and
    /// whether it's long enough to fold.
    func cardText(html: String, host: String) -> (document: RichDocument, isLong: Bool) {
        let key = "\(host)|\(html)" as NSString
        if let box = cardDocuments.object(forKey: key) { return (box.document, box.isLong) }
        let box = CardTextBox(document: CardText.document(html: html, host: host), isLong: CardText.isLong(html: html))
        cardDocuments.setObject(box, forKey: key)
        return (box.document, box.isLong)
    }

    /// A message's cards as they may be drawn: every image, icon, link and button address through
    /// the card address rule, once per version of the message. Empty when there are none to draw.
    func cards(for message: Message, host: String) -> [Card] {
        guard let cards = message.cards, !cards.isEmpty else { return [] }
        let key = "\(host)|\(message.id)|\(message.updatedAt.timeIntervalSince1970)|\(cards.count)" as NSString
        if let box = shownCards.object(forKey: key) { return box.cards }
        let shown = Self.shownCards(cards, host: host)
        shownCards.setObject(CardsBox(shown), forKey: key)
        return shown
    }

    nonisolated static func shownCards(_ cards: [Card], host: String) -> [Card] {
        cards.withAddresses { CardText.address($0, host: host) }
    }

    private final class Box {
        let document: RichDocument
        init(_ document: RichDocument) { self.document = document }
    }

    private final class CardTextBox {
        let document: RichDocument
        let isLong: Bool
        init(document: RichDocument, isLong: Bool) {
            self.document = document
            self.isLong = isLong
        }
    }

    private final class CardsBox {
        let cards: [Card]
        init(_ cards: [Card]) { self.cards = cards }
    }
}
