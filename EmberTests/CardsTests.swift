import Foundation
import Testing
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// The rules behind a message's cards, text, menu and file that don't need a screen.
@MainActor
@Suite struct CardsTests {
    private let host = "ember.example.com"

    private func document(_ message: Message) -> RichDocument {
        RichText.document(html: message.body, plainText: message.plainText, host: host)
    }

    private func file(_ contentType: String, bytes: Int = 1_000, width: Int? = 800, height: Int? = 600, preview: String? = nil) throws -> StoredFile {
        var object: [String: Any] = [
            "id": "file_1", "name": "f", "contentType": contentType, "byteSize": bytes,
            "url": "/files/f", "downloadUrl": "/files/f?download=1",
        ]
        if let width { object["width"] = width }
        if let height { object["height"] = height }
        if let preview { object["previewUrl"] = preview }
        return try JSONDecoder().decode(StoredFile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: What a row shows of its text

    @Test func aPlainMessageShowsItsBody() {
        let message = Fixtures.message("m1", "hello")
        #expect(MessageText.of(message, document: document(message), shownCards: []) == .body)
    }

    @Test func aCardsOnlyMessageShowsNoText() {
        let message = Fixtures.cardMessage("m1")
        let cards = DocumentCache.shownCards(message.cards ?? [], host: host)
        #expect(MessageText.of(message, document: document(message), shownCards: cards) == .none)
    }

    @Test func aMessageWithABodyAndCardsShowsBoth() {
        var message = Fixtures.cardMessage("m1")
        message.body = "<p>Heads up</p>"
        let cards = DocumentCache.shownCards(message.cards ?? [], host: host)
        #expect(MessageText.of(message, document: document(message), shownCards: cards) == .body)
    }

    @Test func cardsThatCantBeDrawnFallBackToThePlainText() {
        var message = Fixtures.cardMessage("m1", cards: [])
        message.cards = nil
        #expect(MessageText.of(message, document: document(message), shownCards: []) == .plainText)
    }

    @Test func aFileMessageDoesntRepeatItsNameAsText() throws {
        var message = Fixtures.message("m1", "photo.png")
        message.body = ""
        message.attachment = try file("image/png")
        #expect(MessageText.of(message, document: document(message), shownCards: []) == .none)
    }

    // MARK: Who may change a message

    @Test func anAuthorMayEditAndDeleteTheirOwn() {
        let message = Fixtures.message("m1", "hi", by: Fixtures.grace)
        #expect(MessageChanges.of(message, myID: Fixtures.grace.id, isAdministrator: false) == MessageChanges(canEdit: true, canDelete: true))
    }

    @Test func someoneElseMayNotChangeIt() {
        let message = Fixtures.message("m1", "hi", by: Fixtures.grace)
        #expect(MessageChanges.of(message, myID: Fixtures.me.id, isAdministrator: false) == MessageChanges(canEdit: false, canDelete: false))
    }

    @Test func anAdministratorMayChangeAnyonesMessage() {
        let message = Fixtures.message("m1", "hi", by: Fixtures.grace)
        #expect(MessageChanges.of(message, myID: Fixtures.me.id, isAdministrator: Fixtures.me.administrator) == MessageChanges(canEdit: true, canDelete: true))
    }

    @Test func aMessageWithCardsIsNeverEdited() {
        let message = Fixtures.cardMessage("m1")
        #expect(MessageChanges.of(message, myID: Fixtures.me.id, isAdministrator: true) == MessageChanges(canEdit: false, canDelete: true))
    }

    @Test func aMessageWithAFileIsNeverEdited() throws {
        var message = Fixtures.message("m1", "photo.png", by: Fixtures.grace)
        message.attachment = try file("image/png")
        #expect(MessageChanges.of(message, myID: Fixtures.grace.id, isAdministrator: false) == MessageChanges(canEdit: false, canDelete: true))
    }

    // MARK: How a file shows

    @Test func anSVGIsARow() throws {
        #expect(AttachmentDisplay.of(try file("image/svg+xml")) == .row)
        #expect(AttachmentDisplay.of(try file("image/svg+xml", preview: "/p")) == .row)
    }

    @Test func aSmallPNGOfKnownSizeIsItsOwnPicture() throws {
        #expect(AttachmentDisplay.of(try file("image/png")) == .picture(path: "/files/f"))
        #expect(AttachmentDisplay.of(try file("image/webp", bytes: AttachmentDisplay.maxBytes)) == .picture(path: "/files/f"))
    }

    @Test func aPictureTooHeavyOrTooLargeOrOfUnknownSizeIsARow() throws {
        #expect(AttachmentDisplay.of(try file("image/jpeg", bytes: AttachmentDisplay.maxBytes + 1)) == .row)
        #expect(AttachmentDisplay.of(try file("image/jpeg", width: 20_000, height: 12_501)) == .row)
        #expect(AttachmentDisplay.of(try file("image/gif", width: nil, height: nil)) == .row)
        #expect(AttachmentDisplay.of(try file("image/heic")) == .row)
    }

    @Test func aPreviewIsPreferred() throws {
        #expect(AttachmentDisplay.of(try file("image/heic", bytes: 50_000_000, preview: "/p")) == .picture(path: "/p"))
    }

    @Test func aVideoShowsItsPosterOrItsRow() throws {
        #expect(AttachmentDisplay.of(try file("video/mp4", preview: "/poster")) == .picture(path: "/poster"))
        #expect(AttachmentDisplay.of(try file("video/mp4")) == .row)
    }

    @Test func aPDFIsARow() throws {
        #expect(AttachmentDisplay.of(try file("application/pdf", width: nil, height: nil)) == .row)
    }

    // MARK: Cards

    @Test func aCardIsNarrowAt400PointsOrLess() {
        #expect(CardWidth.isNarrow(399))
        #expect(CardWidth.isNarrow(400))
        #expect(!CardWidth.isNarrow(401))
    }

    @Test func onlyAnAttachmentHasABar() {
        #expect(CardBar.of(Fixtures.deployCard) == nil)
        #expect(CardBar.of(Fixtures.alertCard) == .red)
        #expect(CardBar.of(Card(source: .attachment, color: "good", parts: [])) == .green)
        #expect(CardBar.of(Card(source: .attachment, color: "warning", parts: [])) == .orange)
        #expect(CardBar.of(Card(source: .attachment, parts: [])) == .separator)
        guard case let .rgb(red, green, blue) = CardBar.of(Card(source: .attachment, color: "#ff0000", parts: [])) else {
            Issue.record("a hex colour should be its own bar")
            return
        }
        #expect(red == 1 && green == 0 && blue == 0)
    }

    @Test func fieldsFillRowsAsAGridDoes() {
        let a = CardField(title: "a", short: true), b = CardField(title: "b", short: true)
        let c = CardField(title: "c", short: true), long = CardField(title: "long")
        let titles = { (rows: [[CardField]]) in rows.map { $0.map { $0.title ?? "" } } }
        #expect(titles(CardFieldRows.rows([a, b, c, long], columns: 2)) == [["a", "b"], ["c"], ["long"]])
        #expect(titles(CardFieldRows.rows([a, long, b], columns: 2)) == [["a"], ["long"], ["b"]])
        #expect(titles(CardFieldRows.rows([a, b], columns: 1)) == [["a"], ["b"]])
    }

    @Test func aFooterJoinsItsTextAndTime() {
        var format = CardFooterText.format
        format.locale = Locale(identifier: "en_US")
        format.timeZone = TimeZone(identifier: "UTC")!
        let at = ISO8601DateFormatter().date(from: "2026-10-12T10:00:00Z")!
        let text = CardFooterText.text("Grafana", at: at, format: format)
        #expect(text.hasPrefix("Grafana · 10/12/2026"))
        // Its time reads as the row's: hour and minute, from the same fields.
        var rowFormat = Date.FormatStyle.dateTime.hour().minute()
        rowFormat.locale = format.locale
        rowFormat.timeZone = format.timeZone
        #expect(text.hasSuffix(at.formatted(rowFormat)))
        #expect(CardFooterText.text("Grafana", at: nil) == "Grafana")
        #expect(CardFooterText.text(nil, at: nil) == "")
    }

    @Test func foldedTextCutsUnderItsFifthRow() {
        // Seven lines of a paragraph, 20 points each, one touching the next.
        let lines = (0..<7).map { CGFloat($0) * 20...CGFloat($0 + 1) * 20 }
        #expect(CardFold.height(lineSpans: lines) == 100)
        // A list's numbers beside its items' first lines are one row with them.
        let numbers: [ClosedRange<CGFloat>] = [0...19.5, 40...59.5]
        #expect(CardFold.height(lineSpans: lines + numbers) == 100)
        // A row that ends partway down a point cuts under it, not through it.
        #expect(CardFold.height(lineSpans: [0...18.2, 18.2...36.4], lines: 2) == 37)
        // Fewer rows than it shows: all of them.
        #expect(CardFold.height(lineSpans: [0...20, 20...40]) == 40)
        #expect(CardFold.height(lineSpans: []) == nil)
    }

    @Test func buttonsFlowOntoFurtherRows() {
        // Three that fit beside one another share a row.
        #expect(FlowRows.rows(widths: [60, 60, 60], in: 200, spacing: 8) == [0..<3])
        // One that doesn't fit beside the rest starts the next.
        #expect(FlowRows.rows(widths: [80, 80, 80], in: 200, spacing: 8) == [0..<2, 2..<3])
        // One wider than the whole row has a row to itself.
        #expect(FlowRows.rows(widths: [50, 300, 50], in: 200, spacing: 8) == [0..<1, 1..<2, 2..<3])
        #expect(FlowRows.rows(widths: [], in: 200, spacing: 8) == [])
    }

    @Test func longTextFoldsBehindShowMore() {
        var fold = CardFold(isLong: true)
        #expect(fold.isClipped)
        #expect(fold.buttonTitle == "Show more")
        fold.isOpen = true
        #expect(!fold.isClipped)
        #expect(fold.buttonTitle == "Show less")
        #expect(CardFold(isLong: false).buttonTitle == nil)
        #expect(CardFold(html: "<p>Short</p>").buttonTitle == nil)
    }

    @Test func shownCardsDropAddressesTheRuleRefuses() throws {
        let card = Card(source: .attachment, thumb: CardImage(url: "http://127.0.0.1/x.png"), parts: [
            .title(text: "Own", href: "https://\(host)/settings"),
            .buttons([
                CardButton(text: "Fine", href: "https://example.com/ok"),
                CardButton(text: "Local", href: "http://127.0.0.1:8787/admin"),
            ]),
        ])
        let shown = DocumentCache.shownCards([card], host: host)
        let json = String(decoding: try JSONEncoder().encode(shown), as: UTF8.self)
        #expect(!json.contains("127.0.0.1"))
        #expect(!json.contains(host))
        #expect(json.contains("example.com"))
    }
}
