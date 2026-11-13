import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// The rules behind threads and staged files that don't need a screen: where links go, how
/// replies group, what the divider counts, what the also-send toggle says and how big a preview is.
@MainActor
@Suite struct ThreadsAndUploadsTests {
    private let room = Fixtures.general.id

    private func reply(_ id: MessageID, to parent: MessageID, minute: Int = 0, by creator: User = Fixtures.grace, alsoSent: Bool = false) -> Message {
        var message = Fixtures.message(id, "reply \(id)", by: creator, minute: minute)
        message.parentId = parent
        message.alsoSent = alsoSent
        return message
    }

    private func grouping(_ items: [TimelineItem]) -> [String: Bool] {
        var grouped: [String: Bool] = [:]
        for item in items {
            switch item {
            case .message(let message, let isGrouped): grouped[message.id.rawValue] = isGrouped
            case .pending(let pending, let isGrouped): grouped[pending.clientMessageId.rawValue] = isGrouped
            case .day: break
            }
        }
        return grouped
    }

    private func days(_ items: [TimelineItem]) -> Int {
        items.filter { if case .day = $0 { true } else { false } }.count
    }

    // MARK: Links

    @Test func aMessageLinksToItsRoom() {
        let message = Fixtures.message("m1", "hi")
        #expect(RoomLink.to(message) == RoomLink(roomID: room, messageID: "m1"))
    }

    @Test func aReplyLinksToItsThreadAtItself() {
        #expect(RoomLink.to(reply("r1", to: "p1")) == RoomLink(roomID: room, messageID: "r1", threadID: "p1"))
    }

    @Test func aMessagesThreadIsItsOwn() {
        #expect(RoomLink.thread(of: Fixtures.message("p1", "parent")) == RoomLink(roomID: room, threadID: "p1"))
    }

    @Test func aRepliesThreadIsItsParents() {
        #expect(RoomLink.thread(of: reply("r1", to: "p1", alsoSent: true)) == RoomLink(roomID: room, threadID: "p1"))
    }

    // MARK: Jumps

    @Test func aJumpCentresARowThatFitsAndTopsOneThatDoesnt() {
        #expect(JumpLanding.placement(rowHeight: 300, viewport: 600) == .center)
        #expect(JumpLanding.placement(rowHeight: 600, viewport: 600) == .center)
        #expect(JumpLanding.placement(rowHeight: 744, viewport: 608) == .top)
    }

    @Test func aJumpHasLandedOnlyWithTheRowsTopInView() {
        // Wholly in view.
        #expect(JumpLanding.isLanded(minY: 157, height: 311, viewport: 626))
        // Its top under the navigation bar, as a tall row centred has it.
        #expect(!JumpLanding.isLanded(minY: -68, height: 744, viewport: 608))
        // A tall row with its top just under the bar.
        #expect(JumpLanding.isLanded(minY: 0, height: 744, viewport: 608))
        // Off the screen, above or below.
        #expect(!JumpLanding.isLanded(minY: -400, height: 300, viewport: 626))
        #expect(!JumpLanding.isLanded(minY: 700, height: 300, viewport: 626))
        // A row that fits but runs under the composer.
        #expect(!JumpLanding.isLanded(minY: 500, height: 300, viewport: 626))
    }

    @Test func aJumpThatMissesItsRowScrollsEachWayInTurn() {
        #expect(JumpLanding.placement(afterMisses: 1) == .bottom)
        #expect(JumpLanding.placement(afterMisses: 2) == .top)
        #expect(JumpLanding.placement(afterMisses: 3) == .bottom)
    }

    // MARK: Grouping

    @Test func aReplyShownInTheRoomNeverGroups() {
        let items = TimelineLayout.items(
            messages: [Fixtures.message("m1", "hi"), reply("r1", to: "p1", minute: 1, alsoSent: true)],
            pending: [], me: nil)
        #expect(grouping(items)["r1"] == false)
    }

    @Test func aMessageAfterAReplyInTheRoomStillGroups() {
        let items = TimelineLayout.items(
            messages: [reply("r1", to: "p1", alsoSent: true), Fixtures.message("m2", "and", minute: 1)],
            pending: [], me: nil)
        #expect(grouping(items)["m2"] == true)
    }

    @Test func repliesInTheirThreadGroup() {
        let items = TimelineLayout.items(
            messages: [reply("r1", to: "p1"), reply("r2", to: "p1", minute: 2)],
            pending: [], me: nil, in: .thread)
        #expect(grouping(items) == ["r1": false, "r2": true])
    }

    @Test func groupingStopsAfterFiveMinutes() {
        let items = TimelineLayout.items(
            messages: [reply("r1", to: "p1"), reply("r2", to: "p1", minute: 6)],
            pending: [], me: nil, in: .thread)
        #expect(grouping(items)["r2"] == false)
    }

    @Test func aTombstoneNeverGroups() {
        var gone = Fixtures.message("m2", "", minute: 1)
        gone.deleted = true
        let items = TimelineLayout.items(
            messages: [Fixtures.message("m1", "hi"), gone, Fixtures.message("m3", "again", minute: 2)],
            pending: [], me: nil)
        #expect(grouping(items) == ["m1": false, "m2": false, "m3": false])
    }

    @Test func aPendingReplyInTheRoomNeverGroups() {
        let me = Fixtures.grace.id
        let pending = PendingMessage(
            clientMessageId: "c1", body: "<p>x</p>", plainText: "x",
            createdAt: Fixtures.message("m", "").createdAt.addingTimeInterval(30), parentId: "p1", delivery: .threadAndRoom)
        let items = TimelineLayout.items(messages: [Fixtures.message("m1", "hi")], pending: [pending], me: me)
        #expect(grouping(items)["c1"] == false)
    }

    @Test func theRoomHeadsItsFirstDay() {
        let items = TimelineLayout.items(messages: [Fixtures.message("m1", "hi")], pending: [], me: nil)
        #expect(days(items) == 1)
    }

    @Test func aThreadsFirstReplyHasNoDayHeading() {
        let items = TimelineLayout.items(messages: [reply("r1", to: "p1")], pending: [], me: nil, in: .thread)
        #expect(days(items) == 0)
    }

    @Test func aThreadHeadsALaterDay() {
        let items = TimelineLayout.items(
            messages: [reply("r1", to: "p1"), reply("r2", to: "p1", minute: 60 * 24)],
            pending: [], me: nil, in: .thread)
        #expect(days(items) == 1)
    }

    // MARK: The divider

    @Test func noDividerAtNoReplies() {
        #expect(TimelineLayout.replyCount(summary: nil, loaded: 0) == nil)
        #expect(TimelineLayout.replyCount(summary: 0, loaded: 0) == nil)
    }

    @Test func theDividerCountsTheSummaryOrWhatsLoaded() {
        #expect(TimelineLayout.replyCount(summary: 12, loaded: 5) == 12)
        #expect(TimelineLayout.replyCount(summary: 2, loaded: 3) == 3)
        #expect(TimelineLayout.replyCount(summary: nil, loaded: 1) == 1)
    }

    // MARK: Also send

    @Test func alsoSendNamesTheRoom() {
        #expect(RoomComposer.alsoSendLabel(for: Room(id: "r", kind: .open, name: "general")) == "Also send to #general")
    }

    @Test func alsoSendInADirectMessage() {
        #expect(RoomComposer.alsoSendLabel(for: Room(id: "d", kind: .direct)) == "Also send as direct message")
    }

    // MARK: Staging

    @Test func previewsFitTheirBoundsWithoutGrowing() {
        #expect(Staging.previewPixelSize(width: 4000, height: 3000, orientation: 1) == 1067)
        #expect(Staging.previewPixelSize(width: 600, height: 400, orientation: 1) == 600)
        #expect(Staging.previewPixelSize(width: 3000, height: 1000, orientation: 1) == 1200)
    }

    @Test func aTurnedPictureFitsTheBoundsTheWayItsShown() {
        // Stored 4000 × 3000 but shown 3000 × 4000: it's the height that has to fit 800.
        #expect(Staging.previewPixelSize(width: 4000, height: 3000, orientation: 6) == 800)
    }

    @Test func filesOver250MBAreRefused() {
        #expect(!Staging.isTooLarge(byteSize: 250_000_000))
        #expect(Staging.isTooLarge(byteSize: 250_000_001))
    }

    @Test func contentTypesComeFromTheExtension() {
        #expect(Staging.contentType(of: URL(filePath: "/tmp/a.jpg")) == "image/jpeg")
        #expect(Staging.contentType(of: URL(filePath: "/tmp/a.mov")) == "video/quicktime")
        #expect(Staging.contentType(of: URL(filePath: "/tmp/a")) == "application/octet-stream")
    }

    @Test func fileSymbols() {
        #expect(FileRow.symbol(contentType: "application/pdf", name: "a.pdf") == "doc.richtext")
        #expect(FileRow.symbol(contentType: "application/octet-stream", name: "a.zip") == "doc.zipper")
    }
}
