import EmberSDK
import EmberTesting
import Foundation
import Testing
@testable import Ember

/// The layout kept between updates gives the same rows as laying the timeline out afresh, while
/// laying out only the messages that changed or whose neighbour above did.
@MainActor
@Suite struct TimelineLayoutCacheTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func ids(_ items: [TimelineItem]) -> [String] {
        items.map { item in
            switch item {
            case .day: item.id
            case .message(_, let grouped), .pending(_, let grouped): "\(item.id)\(grouped ? "+" : "")"
            }
        }
    }

    private func fresh(_ messages: [Message], _ pending: [PendingMessage] = []) -> [String] {
        ids(TimelineLayout.items(messages: messages, pending: pending, me: Fixtures.ada.id, calendar: utc))
    }

    @Test func layingOutTheSameTimelineAgainLaysOutNothing() {
        let cache = TimelineLayoutCache(calendar: utc)
        let messages = TimelineOpenTests.firehose(300)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        #expect(cache.laidOut == 300)
        let again = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        #expect(ids(again) == fresh(messages))
        #expect(cache.laidOut == 0)
    }

    @Test func aRowsPositionIsWhereTheLatestLayoutPutsIt() {
        let cache = TimelineLayoutCache(calendar: utc)
        let first = [Fixtures.message("a", "A", minute: 1), Fixtures.message("b", "B", minute: 2)]
        let items = cache.items(messages: first, pending: [], me: Fixtures.ada.id)
        #expect(cache.position(of: "b") == items.firstIndex { $0.id == "b" })
        #expect(cache.position(of: "gone") == nil)
        let older = [Fixtures.message("z", "Z", minute: 0)] + first
        let again = cache.items(messages: older, pending: [], me: Fixtures.ada.id)
        #expect(cache.position(of: "b") == again.firstIndex { $0.id == "b" })
        #expect(cache.position(of: "z")! < cache.position(of: "a")!)
    }

    @Test func theDaysAreDrawnAgainOnceTheTimeZoneChanges() {
        let cache = TimelineLayoutCache(calendar: utc)
        let messages = [
            Fixtures.message("late", "Late", minute: 13 * 60 + 30),
            Fixtures.message("early", "Early", minute: 14 * 60 + 30),
        ]
        let days = { (items: [TimelineItem]) in items.filter { if case .day = $0 { true } else { false } }.count }
        #expect(days(cache.items(messages: messages, pending: [], me: Fixtures.ada.id)) == 2)
        var west = utc
        west.timeZone = TimeZone(secondsFromGMT: -2 * 3600)!
        cache.calendar = west
        let again = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        #expect(days(again) == 1)
        #expect(ids(again) == ids(TimelineLayout.items(messages: messages, pending: [], me: Fixtures.ada.id, calendar: west)))
    }

    @Test func aMessageArrivingLaysOutOnlyThatMessage() {
        let cache = TimelineLayoutCache(calendar: utc)
        let messages = TimelineOpenTests.firehose(300, endingAt: 300)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        let more = messages + TimelineOpenTests.firehose(1, endingAt: 301)
        #expect(ids(cache.items(messages: more, pending: [], me: Fixtures.ada.id)) == fresh(more))
        #expect(cache.laidOut == 1)
    }

    @Test func anOlderPageLaysOutThePageAndTheMessageBelowIt() {
        let cache = TimelineLayoutCache(calendar: utc)
        let messages = TimelineOpenTests.firehose(40, endingAt: 400)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        let more = TimelineOpenTests.firehose(40, endingAt: 360) + messages
        #expect(ids(cache.items(messages: more, pending: [], me: Fixtures.ada.id)) == fresh(more))
        #expect(cache.laidOut == 41)
    }

    @Test func anEditOrDeleteLaysOutThatMessageAndTheOneAfter() {
        let cache = TimelineLayoutCache(calendar: utc)
        var messages = TimelineOpenTests.firehose(40, endingAt: 400)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        messages[10].plainText = "edited"
        #expect(ids(cache.items(messages: messages, pending: [], me: Fixtures.ada.id)) == fresh(messages))
        #expect(cache.laidOut == 1)
        messages[20].deleted = true
        #expect(ids(cache.items(messages: messages, pending: [], me: Fixtures.ada.id)) == fresh(messages))
        #expect(cache.laidOut == 2)
        messages.remove(at: 30)
        #expect(ids(cache.items(messages: messages, pending: [], me: Fixtures.ada.id)) == fresh(messages))
        #expect(cache.laidOut == 1)
    }

    @Test func aMessageOnItsWayIsLaidOutAfterTheLoadedOnes() {
        let cache = TimelineLayoutCache(calendar: utc)
        let messages = TimelineOpenTests.firehose(40, endingAt: 400)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        let pending = PendingMessage(
            clientMessageId: "c1", body: "<p>x</p>", plainText: "x",
            createdAt: messages.last!.createdAt.addingTimeInterval(30))
        #expect(ids(cache.items(messages: messages, pending: [pending], me: Fixtures.ada.id)) == fresh(messages, [pending]))
        #expect(cache.laidOut == 0)
    }

    @Test func theCostOfANewMessageInAFullRoom() {
        let clock = ContinuousClock()
        let messages = TimelineOpenTests.firehose(300, endingAt: 300)
        let more = messages + TimelineOpenTests.firehose(1, endingAt: 301)
        let cache = TimelineLayoutCache(calendar: utc)
        _ = cache.items(messages: messages, pending: [], me: Fixtures.ada.id)
        let cached = clock.measure { _ = cache.items(messages: more, pending: [], me: Fixtures.ada.id) }
        let again = clock.measure { _ = cache.items(messages: more, pending: [], me: Fixtures.ada.id) }
        let afresh = clock.measure { _ = TimelineLayout.items(messages: more, pending: [], me: Fixtures.ada.id, calendar: utc) }
        print("MEASURE layoutAfresh301=\(afresh) layoutCachedArrival=\(cached) layoutUnchanged=\(again)")
        #expect(cache.laidOut == 0)
    }
}
