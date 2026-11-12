import Foundation
import Testing
import SwiftUI
import UIKit
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// A message row's shape at the largest text sizes, its grouped boosts, its fold, and what
/// VoiceOver says for it. Rows are laid out and drawn off screen; nothing here needs a simulator UI.
@MainActor
@Suite struct MessageRowTests {
    private let host = "ember.test"
    private let longName = "Maya Rodríguez-Fitzgerald"

    // MARK: Boosts

    private func boost(_ id: String, _ content: String, by user: User, minute: Int = 0) -> Boost {
        Boost(id: id, messageId: "m1", booster: user, content: content,
              createdAt: Date(timeIntervalSince1970: 1_000_000 + Double(minute) * 60))
    }

    @Test func boostsAreGroupedByWhatWasBoostedInTheOrderEachFirstAppeared() {
        let boosts = [
            boost("b1", "🎉", by: Fixtures.grace),
            boost("b2", "👍", by: Fixtures.alan),
            boost("b3", "🎉", by: Fixtures.ada),
            boost("b4", "ship it", by: Fixtures.grace),
            boost("b5", "🎉", by: Fixtures.alan),
        ]
        let groups = BoostGroup.of(boosts, myID: Fixtures.ada.id)
        #expect(groups.map(\.content) == ["🎉", "👍", "ship it"])
        #expect(groups.map(\.count) == [3, 1, 1])
        #expect(groups[0].boosters.map(\.id) == [Fixtures.grace.id, Fixtures.ada.id, Fixtures.alan.id])
    }

    @Test func yourBoostIsMarkedAndKeptSoItCanBeTakenBack() {
        let boosts = [
            boost("b1", "🎉", by: Fixtures.grace),
            boost("b2", "🎉", by: Fixtures.ada),
            boost("b3", "👍", by: Fixtures.alan),
        ]
        let groups = BoostGroup.of(boosts, myID: Fixtures.ada.id)
        #expect(groups[0].isMine)
        // The id the chip's Remove Boost sends is your own boost's, not the first booster's.
        #expect(groups[0].mine?.id == "b2")
        #expect(!groups[1].isMine)
        #expect(groups[1].mine == nil)
    }

    @Test func noBoostsMakeNoChips() {
        #expect(BoostGroup.of([], myID: Fixtures.ada.id).isEmpty)
    }

    @Test func aBoostChipSaysWhatHowManyAndWhetherYouBoosted() {
        let groups = BoostGroup.of([
            boost("b1", "🎉", by: Fixtures.grace),
            boost("b2", "🎉", by: Fixtures.ada),
            boost("b3", "👍", by: Fixtures.alan),
            boost("b4", "🚀", by: Fixtures.ada),
        ], myID: Fixtures.ada.id)
        #expect(groups.map(\.spoken) == ["🎉 2, including yours", "👍 1", "🚀 1, yours"])
    }

    @Test func theHoldMenusQuickReactionsAreOfferedOnesInOneRow() {
        #expect(!BoostChoices.quick.isEmpty)
        #expect(BoostChoices.quick.count <= BoostChoices.perRow)
        #expect(BoostChoices.quick.allSatisfy(Reactions.all.contains))
        #expect(Set(BoostChoices.quick).count == BoostChoices.quick.count)
    }

    // MARK: Folding

    @Test func aLongMessageFoldsAndAShortOneDoesNot() {
        #expect(MessageFold.isLong(plainText: String(repeating: "word ", count: 1_990)))
        #expect(!MessageFold.isLong(plainText: "A short message."))
        #expect(!MessageFold.isLong(plainText: String(repeating: "a", count: MessageFold.foldCharacters)))
        // Many short lines, as a pasted log or a long code block has.
        #expect(MessageFold.isLong(plainText: (1...20).map { "line \($0)" }.joined(separator: "\n")))
        #expect(!MessageFold.isLong(plainText: (1...5).map { "line \($0)" }.joined(separator: "\n")))
    }

    @Test func unfoldingIsRememberedApartFromTheRow() {
        let folds = MessageFolds()
        #expect(!folds.isOpen("m1"))
        folds.toggle("m1")
        #expect(folds.isOpen("m1"))
        #expect(!folds.isOpen("m2"))
        #expect(folds.lastToggle == MessageFolds.Toggle(messageID: "m1", isOpen: true, serial: 1))
        folds.toggle("m1")
        #expect(!folds.isOpen("m1"))
        #expect(folds.lastToggle == MessageFolds.Toggle(messageID: "m1", isOpen: false, serial: 2))
    }

    /// A 9,950-character message is drawn folded, and a row made again after unfolding it (as the
    /// lazy timeline makes a row scrolled back into view) is drawn open.
    @Test func aLongMessageIsDrawnFoldedAndStaysOpenInARowMadeAgain() throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 221)
        #expect(text.count == 9_945)
        let message = Fixtures.message("fold-\(UUID().uuidString)", text)
        let short = Fixtures.message("short", "One line.")

        let folded = try size(row(message))
        let shortSize = try size(row(short))
        let fullText = try size(textOnly(message))
        #expect(folded.height < fullText.height / 4)
        #expect(folded.height > shortSize.height * 3)

        MessageFolds.shared.toggle(message.id)
        defer { MessageFolds.shared.toggle(message.id) }
        let opened = try size(row(message))
        #expect(opened.height > fullText.height)
    }

    /// A folded message's first layout on screen, before its fold has ever been measured, is the
    /// height it keeps: laid out again once the fold is known, it doesn't change. Drawn in a window,
    /// as the room draws it, where the measurement is applied before the row is first shown.
    @Test(arguments: [DynamicTypeSize.large, .xxxLarge, .accessibility3])
    func aFoldedMessageIsDrawnAtItsMeasuredHeightTheFirstTime(size textSize: DynamicTypeSize) throws {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)
        let message = Fixtures.message("fold-first-\(UUID().uuidString)", text)
        #expect(MessageFolds.shared.foldHeight(message.id) == nil)
        let first = shownHeight(row(message).dynamicTypeSize(textSize))
        #expect(MessageFolds.shared.foldHeight(message.id) != nil)
        let again = shownHeight(row(message).dynamicTypeSize(textSize))
        // Within one of the screen's pixels.
        #expect(abs(first.height - again.height) < 1 / first.scale)
    }

    // MARK: The largest text size

    /// At the largest size the name had a third of a 390-point row beside an 80-point face and the
    /// time, and was cut to "May…".
    @Test func atTheLargestTextSizeTheAuthorsNameIsNotCut() throws {
        let message = Fixtures.message("m1", "Sent while offline", by: User(id: "user_maya", name: longName))
        let texts = try laidOutTexts(row(message).dynamicTypeSize(.accessibility5))
        #expect(!texts.isEmpty)
        #expect(texts.allSatisfy { !$0.isTruncated })
        // The name wrapped onto more than one line rather than being cut.
        #expect(texts.contains { $0.lines > 1 })
    }

    /// The probe above can see a cut: the old header's single line, as wide as it was left, is.
    @Test func theOldOneLineHeaderIsSeenToCutTheName() throws {
        let old = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(longName).font(.subheadline.weight(.bold)).lineLimit(1)
            Text("16:28").font(.caption)
        }
        .frame(width: 390 - 32 - 80 - 10)
        let texts = try laidOutTexts(old.dynamicTypeSize(.accessibility5))
        #expect(texts.contains { $0.isTruncated })
    }

    @Test func atTheLargestTextSizeTheFaceStopsGrowing() {
        #expect(MessageRowLayout.avatarSize(80, isStacked: true) == MessageRowLayout.largestStackedAvatar)
        #expect(MessageRowLayout.avatarSize(36, isStacked: true) == 36)
        #expect(MessageRowLayout.avatarSize(44, isStacked: false) == 44)
    }

    // MARK: Emoji

    @Test func anEmojiOnlyMessageIsLargeButStopsGrowing() throws {
        let document = RichText.document(html: "<p>🎉🎉🎉</p>", plainText: "🎉🎉🎉", host: host)
        #expect(document.isEmojiOnly)
        let atLargest = try size(body(document).dynamicTypeSize(.accessibility5))
        let atBound = try size(body(document).dynamicTypeSize(MessageBody.largestEmojiSize))
        let atDefault = try size(body(document).dynamicTypeSize(.large))
        #expect(atLargest == atBound)
        #expect(atBound.height > atDefault.height)
        // Words keep following the text size all the way up.
        let words = RichText.document(html: "<p>hello</p>", plainText: "hello", host: host)
        let wordsLargest = try size(body(words).dynamicTypeSize(.accessibility5))
        let wordsBound = try size(body(words).dynamicTypeSize(MessageBody.largestEmojiSize))
        #expect(wordsLargest.height > wordsBound.height)
    }

    // MARK: VoiceOver

    @Test func aRowReadsWhoWhenWhatThenBoostsAndReplies() {
        let boosts = BoostGroup.of([
            boost("b1", "🎉", by: Fixtures.grace),
            boost("b2", "🎉", by: Fixtures.ada),
        ], myID: Fixtures.ada.id)
        let label = MessageSpeech.label(
            author: "Grace Hopper", isAssistant: false, time: "10:01", text: "Ship it\n", isEdited: true,
            isDeleted: false, mentionsMe: true, boosts: boosts, replies: 3)
        #expect(label == "Grace Hopper, 10:01. Mentions you. Ship it. Edited. Reactions: 🎉 2, including yours. 3 replies.")
    }

    @Test func aPlainRowReadsOnlyWhatItHas() {
        let label = MessageSpeech.label(
            author: "Deploys", isAssistant: true, time: "09:30", text: "Done!", isEdited: false,
            isDeleted: false, mentionsMe: false, boosts: [], replies: 1)
        #expect(label == "Deploys, assistant, 09:30. Done! 1 reply.")
    }

    @Test func aDeletedRowSaysSoAndKeepsItsReplies() {
        let label = MessageSpeech.label(
            author: "Grace Hopper", isAssistant: false, time: "10:01", text: "", isEdited: false,
            isDeleted: true, mentionsMe: true, boosts: [], replies: 2)
        #expect(label == "This message was deleted. 2 replies.")
    }

    @Test func aMessagesLinksAreOfferedInReadingOrder() {
        let document = RichText.document(
            html: #"<p>See <a href="https://example.com/a">the plan</a> and</p><ul><li><a href="https://example.com/b">https://example.com/b</a></li></ul>"#,
            plainText: "See the plan and https://example.com/b", host: host)
        let links = MessageSpeech.links(in: document)
        #expect(links.map(\.url) == ["https://example.com/a", "https://example.com/b"])
        #expect(links.map(\.text) == ["the plan", "https://example.com/b"])
    }

    // MARK: The room's bar

    @Test func theRoomsFacesStayInsideTheBar() {
        #expect(RoomTitleLayout.faceSize(24) == 24)
        #expect(RoomTitleLayout.faceSize(60) == RoomTitleLayout.largestFace)
        // The faces and the room round them fit a 44-point bar.
        #expect(RoomTitleLayout.largestFace + RoomTitleLayout.facePadding * 2 <= 44)
    }

    // MARK: Helpers

    private static let workspace = Workspace.mock()
    private static let session = RoomSession.mock()

    private func row(_ message: Message) -> some View {
        MessageRow(
            message: message, grouped: false, me: Fixtures.ada, isHighlighted: false,
            session: Self.session,
            actions: MessageActions(edit: { _ in }, customBoost: { _ in }, selectText: { _ in }))
        .environment(Self.workspace)
    }

    private func body(_ document: RichDocument) -> some View {
        MessageBody(document: document).environment(Self.workspace)
    }

    private func textOnly(_ message: Message) -> some View {
        RichTextView(document: RichText.document(html: message.body, plainText: message.plainText, host: host))
            .fixedSize(horizontal: false, vertical: true)
            .environment(Self.workspace)
    }

    /// A view's size laid out 390 points wide, as an iPhone's row is.
    /// The height `view` takes in its first layout in a window 390 points wide, and the window's
    /// pixels to a point.
    private func shownHeight(_ view: some View) -> (height: CGFloat, scale: CGFloat) {
        let host = UIHostingController(rootView: AnyView(view))
        host.sizingOptions = .intrinsicContentSize
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2000))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        return (host.view.intrinsicContentSize.height, window.screen.scale)
    }

    private func size(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        return try #require(renderer.uiImage).size
    }

    private struct LaidOutText {
        let isTruncated: Bool
        let lines: Int
    }

    private final class Collected {
        var texts: [LaidOutText] = []
    }

    /// Every text in a view as it was laid out 390 points wide: whether it was cut, and its lines.
    private func laidOutTexts(_ view: some View) throws -> [LaidOutText] {
        let collected = Collected()
        let probe = view.backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
            let _ = collected.texts = layouts.map { text in
                LaidOutText(
                    isTruncated: text.layout.isTruncated,
                    lines: text.layout.count)
            }
            Color.clear
        }
        let renderer = ImageRenderer(content: probe)
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        _ = try #require(renderer.uiImage)
        return collected.texts
    }
}
