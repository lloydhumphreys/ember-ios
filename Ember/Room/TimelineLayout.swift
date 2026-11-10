import Foundation
import EmberSDK

/// One row of the timeline as it's laid out: a day's heading, a message, or one still on its way.
enum TimelineItem: Identifiable {
    case day(Date)
    /// `grouped` when it follows on from the same person's message, so it goes without a header.
    case message(Message, grouped: Bool)
    case pending(PendingMessage, grouped: Bool)

    var id: String {
        switch self {
        case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
        case .message(let message, _): message.id
        case .pending(let pending, _): TimelineItem.pendingID(pending.clientMessageId)
        }
    }

    static func pendingID(_ clientMessageId: String) -> String { "pending-\(clientMessageId)" }
}

/// Lays out a timeline the way the web does: a message from the same person within five minutes
/// of the one before shares its header, and each new day gets a heading.
enum TimelineLayout {
    static let groupingWindow: TimeInterval = 5 * 60

    /// Where the rows are shown, which changes two of the web's rules.
    enum Place {
        /// A room, where a reply also sent there quotes what it answers above its text, and so
        /// always shows its header.
        case room
        /// A thread's replies, under the parent: the first gets no day heading, as it follows the
        /// parent rather than starting the list.
        case thread
    }

    static func items(
        messages: [Message], pending: [PendingMessage], me: UserID?, in place: Place = .room, calendar: Calendar = .current
    ) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var previous: (creator: UserID, at: Date, deleted: Bool)?

        func startsDay(_ date: Date) -> Bool {
            guard let previous else { return place == .room }
            return !calendar.isDate(previous.at, inSameDayAs: date)
        }

        func quotes(_ parentID: String?) -> Bool {
            place == .room && parentID != nil
        }

        for message in messages {
            let newDay = startsDay(message.createdAt)
            if newDay { items.append(.day(calendar.startOfDay(for: message.createdAt))) }
            let grouped = !newDay && !quotes(message.parentId)
                && follows(previous, creator: message.creator.id, at: message.createdAt, deleted: message.isDeleted)
            items.append(.message(message, grouped: grouped))
            previous = (message.creator.id, message.createdAt, message.isDeleted)
        }

        // Pending messages are always this person's, and go after everything the room has confirmed.
        for message in pending {
            let newDay = startsDay(message.createdAt)
            if newDay { items.append(.day(calendar.startOfDay(for: message.createdAt))) }
            let grouped = !newDay && !quotes(message.parentId)
                && me.map { follows(previous, creator: $0, at: message.createdAt, deleted: false) } == true
            items.append(.pending(message, grouped: grouped))
            previous = (me ?? "", message.createdAt, false)
        }
        return items
    }

    /// What the divider under a thread's parent counts: the parent's own summary, or the replies
    /// loaded when there are more of those (one just arrived). nil at none, when there's no divider.
    static func replyCount(summary: Int?, loaded: Int) -> Int? {
        let count = max(summary ?? 0, loaded)
        return count > 0 ? count : nil
    }

    private static func follows(_ previous: (creator: UserID, at: Date, deleted: Bool)?, creator: UserID, at date: Date, deleted: Bool) -> Bool {
        guard let previous, !previous.deleted, !deleted else { return false }
        return previous.creator == creator && abs(date.timeIntervalSince(previous.at)) <= groupingWindow
    }
}

/// Where a jump's message lands: wholly in view, centred, when it fits between the navigation bar
/// and the composer; otherwise with its top just under the bar, so its start is what's read first.
/// Heights and positions are in the visible region's own space, 0 being its top.
enum JumpLanding {
    enum Placement: Equatable {
        case center
        case top
        case bottom
    }

    static func placement(rowHeight: CGFloat, viewport: CGFloat) -> Placement {
        rowHeight <= viewport ? .center : .top
    }

    /// Where to scroll the row to after `misses` scrolls in a row left it unbuilt. A scroll to the
    /// same place lands where the stack's stale estimates put it each time, so the row (just past
    /// the screen's edge) is never built; one to its bottom and then its top moves half a screen
    /// either way, which builds it and corrects the estimates.
    static func placement(afterMisses misses: Int) -> Placement {
        misses % 2 == 1 ? .bottom : .top
    }

    /// Whether the row is where it should land: its top in view and, when it fits, all of it.
    static func isLanded(minY: CGFloat, height: CGFloat, viewport: CGFloat) -> Bool {
        let slack: CGFloat = 1
        guard minY >= -slack, minY < viewport else { return false }
        return height > viewport || minY + height <= viewport + slack
    }
}

/// Lands a jump on its message, for the room and a thread alike. One scroll isn't enough: the lazy
/// stack places the row from estimated heights for the rows it hasn't built, and their real
/// heights then leave it elsewhere. So it scrolls, waits a beat, measures where the row really
/// is, and scrolls again until the row has stayed where `JumpLanding` puts it for two looks in a
/// row, or the tries run out. The scrolling, measuring and waiting are handed in, so the loop can
/// be run without a screen or a clock.
@MainActor
struct JumpLander {
    /// Where the row is in the visible region (nil while the lazy stack hasn't built it), and the
    /// visible region's height.
    struct Measure {
        var frame: CGRect?
        var viewport: CGFloat
    }

    var tries = 12
    var scroll: @MainActor (JumpLanding.Placement) -> Void
    var measure: @MainActor () -> Measure
    /// A beat for a scroll to take hold; throws when the run is cancelled.
    var wait: @MainActor () async throws -> Void

    /// Whether the row landed. False when the tries ran out first, with the timeline left where
    /// the last of them put it. Throws when the run is cancelled.
    func land() async throws -> Bool {
        var placement = JumpLanding.Placement.center
        var needsScroll = true
        var timesLanded = 0
        var misses = 0
        for _ in 0..<tries {
            if needsScroll { scroll(placement) }
            try await wait()
            let measured = measure()
            guard let frame = measured.frame, measured.viewport > 0 else {
                // Not built: the stack's estimates were off, and scrolling to the same place again
                // would land in the same wrong spot.
                misses += 1
                placement = JumpLanding.placement(afterMisses: misses)
                needsScroll = true
                timesLanded = 0
                continue
            }
            misses = 0
            placement = JumpLanding.placement(rowHeight: frame.height, viewport: measured.viewport)
            needsScroll = !JumpLanding.isLanded(minY: frame.minY, height: frame.height, viewport: measured.viewport)
            timesLanded = needsScroll ? 0 : timesLanded + 1
            if timesLanded == 2 { return true }
        }
        return false
    }

    /// Lands, lights the row only if it got there, then says it's been shown, landed or not, so a
    /// jump that can't land isn't tried again and again. Cancelled (a newer jump, the view going
    /// away), it does neither: the run that takes over shows it in its turn.
    func show(highlight: @MainActor () -> Void, shown: @MainActor () -> Void) async {
        let landed: Bool
        do { landed = try await land() } catch { return }
        if landed { highlight() }
        shown()
    }
}
