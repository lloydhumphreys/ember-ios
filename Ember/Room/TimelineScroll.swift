import SwiftUI
import EmberSDK

/// Where a timeline's scroll view stands, read once per geometry change, so one value carries
/// everything the scroll decisions need.
struct TimelineGeometry: Equatable {
    /// The content offset, `-insetTop` at the very top.
    var offset: CGFloat
    var contentHeight: CGFloat
    var containerWidth: CGFloat
    /// The height of the region between the bars, which the insets are outside of.
    var containerHeight: CGFloat
    var insetTop: CGFloat
    var insetBottom: CGFloat

    init(offset: CGFloat, contentHeight: CGFloat, containerWidth: CGFloat, containerHeight: CGFloat, insetTop: CGFloat = 0, insetBottom: CGFloat = 0) {
        self.offset = offset
        self.contentHeight = contentHeight
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
        self.insetTop = insetTop
        self.insetBottom = insetBottom
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
            containerWidth: geometry.containerSize.width, containerHeight: geometry.containerSize.height,
            insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
    }

    var minOffset: CGFloat { -insetTop }

    /// Where the offset sits at the end; the top for content shorter than the region.
    var maxOffset: CGFloat { max(minOffset, contentHeight - insetTop - containerHeight) }

    /// How far the end is below what's in view. What's under the bars' glass counts as not read.
    var distanceToEnd: CGFloat { contentHeight - (offset + insetTop + containerHeight) }

    /// Whether the end is on screen, give or take a little. Content shorter than the region is
    /// always at its end.
    var isNearEnd: Bool { distanceToEnd <= 60 }

    /// Whether the top is close enough that the next older page should be on its way, so it has
    /// usually arrived by the time someone reaches it.
    var isNearStart: Bool { offset + insetTop < 400 }

    /// Whether any of the content is in the region. An offset left wholly past either end shows
    /// none of it, whatever rows the scroll view still lists as in view.
    var showsContent: Bool {
        contentHeight > 0 && offset + insetTop < contentHeight && offset + insetTop + containerHeight > 0
    }

    /// Whether the region the content is shown in changed size: a rotation, the composer growing
    /// or shrinking, the keyboard coming or going.
    func viewportChanged(from old: TimelineGeometry) -> Bool {
        containerWidth != old.containerWidth || containerHeight != old.containerHeight
            || insetTop != old.insetTop || insetBottom != old.insetBottom
    }
}

/// What a timeline does as its scroll view's geometry changes, worked out without a screen.
enum TimelineScroll {
    enum Move: Equatable {
        case none
        /// Back to the end, for a reader who was there.
        case toEnd
        /// Back to the row that was at the top, for a reader who wasn't at the end, whose rows
        /// reflowed or whose offset now falls outside the content.
        case keepRow
    }

    struct Decision: Equatable {
        var move: Move
        var isPinnedToEnd: Bool
    }

    /// What to do when the geometry goes from `old` to `new`. `isPinnedToEnd` is whether the
    /// reader was at the end and means to stay there; `canHoldEnd` whether the end shown is one to
    /// hold, which it isn't while a later page exists or a finger is on the timeline.
    ///
    /// The region changing size keeps a reader at the end there, and anyone else on the row they
    /// were reading when the width reflows the rows or the offset ends up outside the content. The
    /// offset moving on its own, by hand or by a scroll, decides whether the reader is at the end.
    /// The content changing height under a still offset keeps a reader at the end there.
    ///
    /// Wherever the offset is left outside the content, it's brought back (see `bringBack`).
    /// While the reader's fold is being held (see `holdsFold`), the content changing height moves
    /// nothing else, and whether the reader is at the end is read from where the offset was left.
    ///
    /// While the timeline is on its way to the end (`isGoingToEnd`), the offset moving is that
    /// scroll, not the reader leaving the end, and anything that grows meanwhile, a message just
    /// sent or the composer, is followed to the end.
    static func decide(
        from old: TimelineGeometry, to new: TimelineGeometry, isPinnedToEnd: Bool, canHoldEnd: Bool,
        isHoldingFold: Bool = false, isTouched: Bool = false, isGoingToEnd: Bool = false
    ) -> Decision {
        if isGoingToEnd, canHoldEnd, !isTouched, !isHoldingFold {
            let grew = new.contentHeight != old.contentHeight || new.viewportChanged(from: old)
            return Decision(move: grew ? .toEnd : .none, isPinnedToEnd: true)
        }
        if new.viewportChanged(from: old) {
            if isPinnedToEnd {
                return Decision(move: canHoldEnd ? .toEnd : .none, isPinnedToEnd: true)
            }
            let reflowed = new.containerWidth != old.containerWidth
            let outside = new.offset > new.maxOffset + 0.5 || new.offset < new.minOffset - 0.5
            return Decision(move: reflowed || outside ? .keepRow : .none, isPinnedToEnd: false)
        }
        if let move = bringBack(new, isTouched: isTouched) {
            return Decision(move: move, isPinnedToEnd: move == .toEnd || new.isNearEnd)
        }
        if abs(new.offset - old.offset) >= 0.5 {
            return Decision(move: .none, isPinnedToEnd: new.isNearEnd)
        }
        if new.contentHeight != old.contentHeight, isHoldingFold {
            return Decision(move: .none, isPinnedToEnd: new.isNearEnd)
        }
        if new.contentHeight != old.contentHeight, isPinnedToEnd, canHoldEnd {
            return Decision(move: .toEnd, isPinnedToEnd: true)
        }
        return Decision(move: .none, isPinnedToEnd: isPinnedToEnd)
    }

    /// The offset never stays outside the content: left past the end, as content shrinking under a
    /// still offset leaves it, it goes back to the end; left before the start, the row at the top
    /// is put back. nil while it's within the content, or while a finger is on the timeline
    /// (`isTouched`), which the scroll view brings back itself when it's let go.
    static func bringBack(_ geometry: TimelineGeometry, isTouched: Bool) -> Move? {
        guard !isTouched else { return nil }
        if geometry.offset > geometry.maxOffset + 0.5 { return .toEnd }
        if geometry.offset < geometry.minOffset - 0.5 { return .keepRow }
        return nil
    }

    /// What a timeline holding a row in place (`TimelineTracker.keepID`) does as the geometry
    /// changes: puts it back as the region or the content changes size, or as the offset leaves
    /// the content.
    static func keeping(from old: TimelineGeometry, to new: TimelineGeometry, isTouched: Bool) -> Move {
        let changed = bringBack(new, isTouched: isTouched) != nil || new.viewportChanged(from: old)
            || new.contentHeight != old.contentHeight
        return changed ? .keepRow : .none
    }

    /// Of the rows in view, `ids`, the one highest on screen, by `position` among the timeline's
    /// rows, top first, at `start` or below it. The scroll view lists them in no order to rely on.
    /// Rows it has no position for, such as the end's spacer, count as lowest; a day's heading
    /// counts only when nothing else is in view, as it doesn't stay with the rows under it
    /// (`TimelineItem.isDay`).
    ///
    /// The rows in view can be read against a layout newer than they are: an older page laid out
    /// under a still offset puts its own rows in view before the timeline hears it arrived. The
    /// reader's row is then the highest of those from where the old first message now is; nil when
    /// none of them are.
    static func topmost(_ ids: [String], position: (String) -> Int?, from start: Int = 0) -> String? {
        let below = ids.filter { id in position(id).map { $0 >= start } ?? true }
        let rows = below.filter { !TimelineItem.isDay($0) }
        return (rows.isEmpty ? below : rows).min { (position($0) ?? .max) < (position($1) ?? .max) }
    }

    /// Of the rows in view, `ids`, the one the reader is reading: the highest whose top is on
    /// screen. That's the highest row in view if it's wholly in view (`whole`), else the next one
    /// down, as only the foot of the highest shows; the highest when it's the only one, filling the
    /// screen.
    static func readerRow(_ ids: [String], whole: [String], position: (String) -> Int?) -> String? {
        guard let top = topmost(ids, position: position) else { return nil }
        if whole.contains(top) { return top }
        return topmost(ids.filter { $0 != top && !TimelineItem.isDay($0) }, position: position).flatMap { next in
            position(next) == nil ? nil : next
        } ?? top
    }

    enum Recovery: Equatable {
        case toEnd
        /// Back to this row, at the top.
        case row(String)
    }

    /// What brings back a timeline that shows none of its rows once it has stood still: to the
    /// row it was keeping (`keeping`), else to the end. nil while it shows one (`rowsInView`), has
    /// none (`hasRows`), or is being moved by a finger or a jump still landing (`isMoving`).
    static func recover(hasRows: Bool, rowsInView: Bool, isMoving: Bool, keeping: String?) -> Recovery? {
        guard hasRows, !rowsInView, !isMoving else { return nil }
        return keeping.map(Recovery.row) ?? .toEnd
    }

    /// What brings back a timeline coming back on screen, whose rows the scroll view last listed
    /// before it went: a reader at the end goes back there, as a fold made elsewhere meanwhile (in a
    /// thread, on its parent) can have left the offset past it; anyone else goes back to their row
    /// (`readerRow`) only if a fold was made while away (`foldedAway`), and otherwise stays put.
    static func returning(isPinnedToEnd: Bool, readerRow: String?, foldedAway: Bool) -> Recovery? {
        if isPinnedToEnd { return .toEnd }
        guard foldedAway else { return nil }
        return readerRow.map(Recovery.row) ?? .toEnd
    }

    /// How long a timeline that shows none of its rows waits before it's brought back
    /// (`recover`): longer than any scroll, jump or fold of its own takes to land.
    static let blankWait = Duration.milliseconds(800)

    /// Whether `toggle` was made in a thread's timeline (`inThread`) or a room's. A message shown
    /// in both, a thread's parent, changes height in both, but only the one it was tapped in holds
    /// its place for it or lets go of its end.
    static func isFold(_ toggle: MessageFolds.Toggle, inThread: Bool) -> Bool {
        inThread ? toggle.place != .room : toggle.place == .room
    }

    /// Whether a timeline is still holding its offset for the reader's last fold, `toggle`, made in
    /// it (`isHere`): from the toggle until `settled`, the last toggle the timeline has let go of,
    /// catches up with it.
    static func holdsFold(_ toggle: MessageFolds.Toggle?, isHere: Bool, settled: Int?) -> Bool {
        guard let toggle, isHere else { return false }
        return toggle.serial != settled
    }

    /// How long a fold is held for: the row's new height and its measured fold are laid out well
    /// within it.
    static let foldHold = Duration.milliseconds(300)

    /// How long the reader's row is held at the top after the region changes size: a rotation's
    /// layouts, and the bars and insets settling after it, are over well within it.
    static let resizeHold = Duration.milliseconds(700)

    /// How long a scroll to the end counts as on its way there: an animated one lands, and a
    /// message just sent and the composer letting go of its files are laid out, well within it.
    static let endHold = Duration.milliseconds(600)

    /// How long after a timeline comes back on screen the reader is put back again (`returning`):
    /// a scroll asked for as it appears can land before the transition bringing it back is over,
    /// against the layout from before it went.
    static let returnHold = Duration.milliseconds(450)

    /// Where the scroll view keeps its content as that changes size: by its foot, so the end stays
    /// in view as messages arrive; by its top while the reader's fold is held, so the rows above it,
    /// and its own top, stay put. A fold is made with the message's top on screen
    /// (`MessageFold.raisesFirst`), so it stays in view.
    static func sizeChangeAnchor(isHoldingFold: Bool) -> UnitPoint {
        isHoldingFold ? .top : .bottom
    }

    /// How many of `messages` came from others after `lastSeen`, the newest message when the
    /// reader left the end: what the jump-down button counts while the newest are loaded. Zero
    /// when nothing was seen, or it's no longer loaded.
    static func unseen(in messages: [Message], after lastSeen: MessageID?, me: UserID?) -> Int {
        guard let lastSeen, let index = messages.lastIndex(where: { $0.id == lastSeen }) else { return 0 }
        return messages[(index + 1)...].count { $0.creator.id != me }
    }
}

/// Whether a timeline may ask for the page at one of its ends. A page asked for near the start
/// lands above the reader, who is still near the start when it does; asking again then would
/// chain page after page while nobody scrolls. So once a page is asked for, the next waits until
/// the reader has been away from that end, or starts a scroll by hand there.
struct PagingGate: Equatable {
    private(set) var isOpen = true

    mutating func asked() {
        isOpen = false
    }

    /// Opens again once the reader is seen away from the end, or scrolling by hand.
    mutating func saw(isNear: Bool, scrollingByHand: Bool) {
        if !isNear || scrollingByHand { isOpen = true }
    }

    /// Whether a finger came down on the scroll view. A drag can start straight in
    /// `.interacting`, and catching a fling goes from `.decelerating` to `.interacting`, neither
    /// passing through `.tracking`.
    static func fingerCameDown(from old: ScrollPhase, to new: ScrollPhase) -> Bool {
        let touching: [ScrollPhase] = [.tracking, .interacting]
        return touching.contains(new) && !touching.contains(old)
    }
}

/// What a timeline tracks about its scroll view without showing it, kept out of observation so
/// that writing it on every scroll doesn't run the timeline's body again.
@MainActor
final class TimelineTracker {
    var geometry: TimelineGeometry?
    /// The row at the top of what's in view.
    var topID: String?
    /// The rows in view, in no order, as the scroll view last listed them.
    var visibleIDs: [String] = []
    /// The rows wholly in view, in no order.
    var wholeIDs: [String] = []
    /// The row being read: the highest whose top is on screen (`TimelineScroll.readerRow`).
    var readerID: String?
    /// The last row read, kept while nothing is in view.
    var lastRowID: String?
    /// The row being read while the region last stood still: what the reader was looking at
    /// before a rotation, whose first layouts move it before the timeline hears of the new size.
    private(set) var settledTopID: String?
    /// The visible region's height, for landing a jump.
    var viewportHeight: CGFloat = 0
    /// Whether the reader is at the end and means to stay there as it grows.
    var isPinnedToEnd = true
    var isScrollingByHand = false
    /// The row to put back at the top once rows coming or going above it are laid out.
    private(set) var keepID: String?
    /// Whether a scroll to the end is on its way there (see `TimelineScroll.decide`).
    private(set) var isGoingToEnd = false
    /// Whether a message is being brought to the top to be folded (`raise`).
    private(set) var isRaising = false
    private var keepTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    private var raiseTask: Task<Void, Never>?
    private var blankTask: Task<Void, Never>?
    private var heldFold: Int?

    /// Notes where the reader is after a geometry change: the row being read counts as theirs
    /// unless the region is changing size or a row is being held.
    func noteTop(resized: Bool) {
        if !resized, keepID == nil { settledTopID = readerID ?? topID }
    }

    /// The reader's row as the region changes size, held through the layouts that follow.
    func keepRowThroughResize(_ proxy: ScrollViewProxy) {
        guard let id = settledTopID ?? topID else { return }
        keepOnNextLayout(id, for: TimelineScroll.resizeHold)
        keep(id, proxy)
    }

    /// Counts the timeline as on its way to the end for a moment, then runs `settle`, which lands
    /// it there if something left it short.
    func goingToEnd(then settle: @escaping @MainActor () -> Void) {
        isGoingToEnd = true
        endTask?.cancel()
        endTask = Task { [weak self] in
            do { try await Task.sleep(for: TimelineScroll.endHold) } catch { return }
            self?.isGoingToEnd = false
            settle()
        }
    }

    /// A finger has come down on the timeline: whatever was being held is the reader's again.
    func handTookOver() {
        cancelMoves()
        settledTopID = topID
    }

    /// Starts holding the reader's fold `toggle`, before its new height is laid out: the first
    /// time it's asked for, whatever was being held lets go, as what the timeline does about that
    /// height is the fold's own, and isn't undone.
    func hold(_ toggle: MessageFolds.Toggle) {
        guard heldFold != toggle.serial else { return }
        heldFold = toggle.serial
        cancelMoves()
    }

    /// Brings the row `id` to the top, with nothing moving it meanwhile, then runs `fold` a frame
    /// later, once the rows around it are laid out where the scroll put them; a scroll by hand
    /// meanwhile folds it where it is. The fold then happens with the row's top on screen.
    func raise(_ id: String, _ proxy: ScrollViewProxy, then fold: @escaping @MainActor () -> Void) {
        cancelMoves()
        guard !isScrollingByHand else { return fold() }
        isRaising = true
        proxy.scrollTo(id, anchor: .top)
        raiseTask = Task { [weak self] in
            defer {
                self?.isRaising = false
                fold()
            }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            if self?.isScrollingByHand == false { proxy.scrollTo(id, anchor: .top) }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    /// Holds `id` at the top through the layouts of the next moment: rows added or taken away
    /// above it are laid out over a frame or two, and each would carry it off.
    func keepOnNextLayout(_ id: String, for duration: Duration = .milliseconds(250)) {
        keepID = id
        keepTask?.cancel()
        keepTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.keepID = nil
        }
    }

    /// Puts `id` back at the top now and again a frame later, once the rows around it have their
    /// heights. A finger on the timeline lets it go.
    func keep(_ id: String, _ proxy: ScrollViewProxy) {
        guard !isScrollingByHand else {
            keepID = nil
            return
        }
        proxy.scrollTo(id, anchor: .top)
        move { proxy.scrollTo(id, anchor: .top) }
    }

    /// Runs `check` once the timeline has stood still a moment (`TimelineScroll.blankWait`), in
    /// place of any check still waiting; `check` says whether to look again after another.
    func watchForBlank(_ check: @escaping @MainActor () -> Bool) {
        blankTask?.cancel()
        blankTask = Task { [weak self] in
            do { try await Task.sleep(for: TimelineScroll.blankWait) } catch { return }
            if check() { self?.watchForBlank(check) }
        }
    }

    /// Lets go of everything the timeline was doing and waiting to do, as it goes off screen: a
    /// fold, a held row or a check made there mustn't act on it once it's back.
    func leave() {
        cancelMoves()
        blankTask?.cancel()
    }

    /// Runs `step` a frame from now, in place of any step still waiting.
    func move(_ step: @escaping @MainActor () -> Void) {
        moveTask?.cancel()
        moveTask = Task {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            step()
        }
    }

    func cancelMoves() {
        moveTask?.cancel()
        keepTask?.cancel()
        endTask?.cancel()
        keepID = nil
        isGoingToEnd = false
    }
}
