import Foundation
import Testing
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// What the composer shows and saves when a formatted message is edited.
@Suite struct MessageEditTests {
    private let sam = User(id: "abcdefghij012345", name: "Sam")
    private var mention: String {
        "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(sam.id)\"></action-text-attachment>"
    }
    private var body: String {
        "<p>Welcome to <strong>Fernwood</strong>. Read <a href=\"https://example.com/guide\">the guide</a> with \(mention) today.</p>"
    }

    private func message(_ body: String, mentions: [User] = []) -> Message {
        var message = Fixtures.message("m1", "")
        message.body = body
        message.mentions = mentions
        return message
    }

    private var edit: MessageEdit {
        MessageEdit(message(body, mentions: [sam])) { $0.id == "abcdefghij012345" ? "Sam Rivera" : $0.name }
    }

    @Test func theFieldShowsTheTextWithTheMentionByName() {
        #expect(edit.text == "Welcome to Fernwood. Read the guide with @Sam Rivera today.")
    }

    @Test func aMentionDefaultsToTheNameTheMessageCarries() {
        #expect(MessageEdit(message(body, mentions: [sam])).text.contains("with @Sam today"))
    }

    @Test func changingOnePlainWordKeepsTheBoldLinkAndMention() throws {
        let saved = try #require(edit.body(for: "Welcome to Fernwood. Read the guide with @Sam Rivera tomorrow."))
        #expect(saved == body.replacing("today", with: "tomorrow"))
        #expect(saved.contains("<strong>Fernwood</strong>"))
        #expect(saved.contains("<a href=\"https://example.com/guide\">the guide</a>"))
        #expect(saved.contains(mention))
    }

    @Test func aWordAddedInsideTheBoldIsBold() throws {
        let saved = try #require(edit.body(for: "Welcome to Fernwood Park. Read the guide with @Sam Rivera today."))
        #expect(saved == body.replacing("<strong>Fernwood</strong>", with: "<strong>Fernwood Park</strong>"))
    }

    @Test func aListKeepsItsItems() throws {
        let list = "<p>Launch checklist for <strong>Thursday</strong>:</p><ol><li>Freeze the build</li><li>Final QA pass</li></ol>"
        let edit = MessageEdit(message(list))
        #expect(edit.text == "Launch checklist for Thursday:\nFreeze the build\nFinal QA pass")
        let saved = try #require(edit.body(for: "Launch checklist for Thursday:\nFreeze the build\nLast QA pass"))
        #expect(saved == list.replacing("Final", with: "Last"))
    }

    @Test func anUnchangedDraftHasNothingToSave() {
        #expect(MessageEdit.editedText(edit.text, from: edit.text) == nil)
        #expect(edit.body(for: edit.text) == nil)
    }

    @Test func aBlankDraftHasNothingToSave() {
        #expect(edit.body(for: "") == nil)
        #expect(edit.body(for: "  \n ") == nil)
    }

    @Test func whiteSpaceAtTheEndsIsNotAnEdit() {
        #expect(edit.body(for: edit.text + " ") == nil)
        #expect(edit.body(for: " \n" + edit.text + "\n\n") == nil)
    }

    @Test func theEndsKeepTheirOwnWhiteSpaceWhenTheMiddleChanges() {
        #expect(MessageEdit.editedText("Hi there ", from: "Hi") == "Hi there")
        #expect(MessageEdit.editedText("  Hi there", from: "Hi \n") == "Hi there \n")
        #expect(MessageEdit.editedText(" Hi", from: "Hi") == nil)
    }

    @Test func aFileOnlyMessageStartsEmptyAndTakesACaption() throws {
        var file = message("")
        let object: [String: Any] = [
            "id": "file_1", "name": "report.pdf", "contentType": "application/pdf", "byteSize": 10,
            "url": "/files/report.pdf", "downloadUrl": "/files/report.pdf?download=1",
        ]
        file.attachment = try JSONDecoder().decode(StoredFile.self, from: JSONSerialization.data(withJSONObject: object))
        let edit = MessageEdit(file)
        #expect(edit.text == "")
        #expect(edit.body(for: "") == nil)
        #expect(edit.body(for: "   ") == nil)
        #expect(try #require(edit.body(for: "The report")) == RichText.body(fromPlainText: "The report"))
    }
}
