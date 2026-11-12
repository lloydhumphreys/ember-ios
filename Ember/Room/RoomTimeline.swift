import SwiftUI
import EmberSDK

/// The room's messages, newest at the foot. It opens at the bottom and stays there as messages
/// arrive while it's read there, but leaves someone who has scrolled up where they are. Older
/// pages load as the top comes near, newer ones (after a jump back in time) as the foot does.
struct RoomTimeline: View {
    let session: RoomSession
    /// Goes up each time this person sends, which takes the timeline to the bottom to show it.
    let sentCount: Int
    let actions: MessageActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isNearBottom = true
    @State private var isNearTop = false
    /// Paging waits until the first layout has settled where it's going, so the moment before the
    /// bottom anchor takes hold (when the offset is still 0) doesn't read as reaching the top.
    @State private var hasSettled = false
    /// The message a link arrived at, lit up for a moment once it's scrolled to.
    @State private var highlightedID: String?
    /// The jump to latest asked for a fresh page; scroll down once it's here.
    @State private var isAwaitingLatest = false
    /// Goes up to (re)start the wait after which paging may begin. Kept apart from the anchor's
    /// task, which `anchorShown()` cancels, so settling always finishes: each bump restarts the
    /// wait, and only the view going away stops it (and coming back runs the anchor task again).
    @State private var settleRequest = 0
    /// The message a jump is landing on, and where its row is in the visible region (nil while
    /// the lazy stack hasn't built it), which tells the landing when it's in view.
    @State private var landingID: String?
    @State private var landingFrame: CGRect?
    /// Whether the page at each end may be asked for (see `PagingGate`).
    @State private var olderGate = PagingGate()
    @State private var newerGate = PagingGate()
    /// The newest message when the reader left the bottom, which the jump-down button counts from.
    @State private var lastSeenID: String?
    @State private var tracker = TimelineTracker()
    @State private var layout = TimelineLayoutCache()
    /// The last fold this timeline has stopped holding its offset for (see `TimelineScroll.holdsFold`).
    @State private var settledFold = MessageFolds.shared.lastToggle?.serial
    /// Whether the timeline has gone off screen since it last came on, and the last fold then.
    @State private var hasLeft = false
    @State private var foldWhenLeft: Int?
    /// Goes up as the timeline comes back on screen, to put the reader back again once it's there.
    @State private var returnRequest = 0

    private static let bottomID = "timeline-bottom"

    private var timeline: Timeline { session.timeline }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if timeline.olderPageFailure != nil {
                        PageRetry { session.retryOlder() }
                    } else if timeline.isLoadingOlder {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                    if timeline.newerPageFailure != nil {
                        PageRetry { session.retryNewer() }
                    } else if timeline.isLoadingNewer {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    // Somewhere to scroll down to that doesn't move as the last message's
                    // boosts or attachment change its height. It stands in for the stack's bottom
                    // padding, so scrolling to it lands at the true end, as the first layout does.
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomID)
                }
                .scrollTargetLayout()
                .padding(.top, 8)
                .environment(\.holdsFolds, hasLeft)
            }
            // Opens at the end and keeps it in view as the content grows, but content shorter
            // than the screen sits at the top, under the navigation bar, rather than at the foot
            // with blank space over it.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(TimelineScroll.sizeChangeAnchor(isHoldingFold: holdsFold), for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if !timeline.isLoaded { ProgressView() }
            }
            .overlay(alignment: .bottomTrailing) {
                jumpToLatest(proxy: proxy)
            }
            .onScrollGeometryChange(for: TimelineGeometry.self) { TimelineGeometry($0) } action: { old, new in
                scrolled(from: old, to: new, proxy)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                tracker.visibleIDs = ids
                tracker.topID = TimelineScroll.topmost(ids, position: layout.position(of:))
                noteReader(proxy)
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.99) { ids in
                tracker.wholeIDs = ids
                noteReader(proxy)
            }
            .onScrollPhaseChange { old, phase, context in
                tracker.isScrollingByHand = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .tracking, old != .tracking { tracker.handTookOver() }
                if PagingGate.fingerCameDown(from: old, to: phase) { scrollBegan() }
                // iOS 18 can leave out the last geometry changes of a scroll, leaving the timeline
                // short of where it came to rest: the jump-down button stays up at the end, and a
                // tap on it, scrolling nowhere, changes nothing to hear of. At rest the scroll
                // view's own geometry is where it is.
                if phase == .idle, let last = tracker.geometry {
                    let now = TimelineGeometry(context.geometry)
                    if now != last { scrolled(from: last, to: now, proxy) }
                }
            }
            // Asking for a page sets its loading flag there and then, which turns the wish back
            // off and adds a spinner row; from `onChange` that lands inside the same update and
            // fires it again in the frame. A task asks once the update is over.
            .task(id: wantsOlder) {
                guard wantsOlder else { return }
                olderGate.asked()
                session.loadOlder()
            }
            .task(id: wantsNewer) {
                guard wantsNewer else { return }
                newerGate.asked()
                session.loadNewer()
            }
            // Rows coming or going above the reader (an older page, or the oldest let go) would
            // carry what they're reading down or up the screen; the row at the top is put back once
            // they're laid out.
            // A message folded or unfolded here keeps the rows above it (see
            // `TimelineScroll.sizeChangeAnchor`), held from as the body reads it for the scroll
            // anchor, before the new height is laid out; this is for a fold the body hasn't read.
            .onChange(of: MessageFolds.shared.lastToggle) { _, toggle in
                guard let toggle, isFoldHere(toggle) else { return }
                tracker.hold(toggle)
            }
            // A fold asked for with the message's top above what's in view brings it to the top
            // first (see `MessageFold.raisesFirst`).
            .onChange(of: MessageFolds.shared.raising) { _, raise in
                guard let raise, raise.place == .room else { return }
                guard timeline.message(raise.messageID) != nil else { return MessageFolds.shared.dropped(raise) }
                tracker.raise(raise.messageID, proxy) { MessageFolds.shared.raised(raise) }
            }
            .task(id: MessageFolds.shared.lastToggle?.serial) {
                guard let serial = MessageFolds.shared.lastToggle?.serial, serial != settledFold else { return }
                do { try await Task.sleep(for: TimelineScroll.foldHold) } catch { return }
                settledFold = serial
            }
            .onChange(of: timeline.messages.first?.id) { oldFirst, _ in
                guard !tracker.isPinnedToEnd, !isJumpUnsettled else { return }
                let start = oldFirst.flatMap(layout.position(of:)) ?? 0
                guard let top = TimelineScroll.topmost(tracker.visibleIDs, position: layout.position(of:), from: start)
                    ?? oldFirst ?? tracker.topID else { return }
                tracker.keepOnNextLayout(top)
            }
            .onChange(of: timeline.hasNewer) { syncAwayFromLatest() }
            .onChange(of: sentCount) {
                followSend(proxy)
            }
            .onChange(of: latestHasArrived) { _, arrived in
                if arrived {
                    tracker.isPinnedToEnd = true
                    scrollToBottom(proxy, animated: false)
                    // Clearing the wait turns `latestHasArrived` back off; written in this update,
                    // that fires this handler again in the same frame.
                    Task { @MainActor in isAwaitingLatest = false }
                }
            }
            .task(id: AnchorKey(anchor: timeline.anchor, isLoaded: timeline.isLoaded)) {
                await showAnchor(proxy)
            }
            .task(id: settleRequest) {
                guard settleRequest > 0 else { return }
                // A beat for the scroll that's just been asked for to land before paging can
                // read its position.
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                hasSettled = true
            }
            .onAppear {
                tracker.watchForBlank { lookForBlank(proxy) }
                if hasLeft {
                    hasLeft = false
                    cameBack(proxy)
                    returnRequest += 1
                }
            }
            .task(id: returnRequest) {
                guard returnRequest > 0 else { return }
                do { try await Task.sleep(for: TimelineScroll.returnHold) } catch { return }
                cameBack(proxy)
            }
            .onDisappear {
                tracker.leave()
                settledFold = MessageFolds.shared.lastToggle?.serial
                hasLeft = true
                foldWhenLeft = settledFold
            }
            .task(id: highlightedID) {
                guard highlightedID != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                withAnimation(.easeOut(duration: 0.6)) { highlightedID = nil }
            }
        }
    }

    private var items: [TimelineItem] {
        layout.items(messages: timeline.messages, pending: timeline.pending, me: timeline.me?.id)
    }

    /// One geometry change, read once: whether to hold the end, put a row back, or only note where
    /// the reader is (see `TimelineScroll.decide`). Not held at the end while a later page exists,
    /// since the end shown isn't the room's, or while a finger is on the timeline.
    private func scrolled(from old: TimelineGeometry, to new: TimelineGeometry, _ proxy: ScrollViewProxy) {
        tracker.geometry = new
        tracker.viewportHeight = new.containerHeight
        let resized = new.viewportChanged(from: old)
        if let keep = tracker.keepID {
            switch TimelineScroll.keeping(from: old, to: new, isTouched: tracker.isScrollingByHand) {
            case .toEnd:
                tracker.cancelMoves()
                setPinned(true)
                holdAtEnd(proxy)
            case .keepRow: tracker.keep(keep, proxy)
            case .none: break
            }
        } else {
            let decision = TimelineScroll.decide(
                from: old, to: new, isPinnedToEnd: tracker.isPinnedToEnd,
                canHoldEnd: !timeline.hasNewer && !tracker.isScrollingByHand,
                isHoldingFold: isHoldingFold, isTouched: tracker.isScrollingByHand,
                isGoingToEnd: tracker.isGoingToEnd)
            setPinned(decision.isPinnedToEnd)
            switch decision.move {
            case .toEnd: holdAtEnd(proxy)
            case .keepRow:
                if resized {
                    tracker.keepRowThroughResize(proxy)
                } else if let top = tracker.topID {
                    tracker.keep(top, proxy)
                }
            case .none: break
            }
        }
        tracker.noteTop(resized: resized)
        if isNearBottom != new.isNearEnd {
            isNearBottom = new.isNearEnd
            lastSeenID = new.isNearEnd ? nil : timeline.messages.last?.id
        }
        if isNearTop != new.isNearStart { isNearTop = new.isNearStart }
        see(isNearStart: new.isNearStart, isNearEnd: new.isNearEnd, byHand: false)
    }

    /// Whether `toggle` was a message folded or unfolded in this room's timeline.
    private func isFoldHere(_ toggle: MessageFolds.Toggle) -> Bool {
        TimelineScroll.isFold(toggle, inThread: false) && timeline.message(toggle.messageID) != nil
    }

    /// Whether the offset is held for a fold the reader has just made here.
    private var isHoldingFold: Bool {
        let toggle = MessageFolds.shared.lastToggle
        return TimelineScroll.holdsFold(toggle, isHere: toggle.map(isFoldHere) ?? false, settled: settledFold)
    }

    /// Whether the fold the reader has just made here is held, starting to hold it the first time.
    private var holdsFold: Bool {
        guard isHoldingFold, let toggle = MessageFolds.shared.lastToggle else { return false }
        tracker.hold(toggle)
        return true
    }

    /// Notes the row being read from the rows in view, and, with none of the timeline's rows in
    /// view, starts watching for the timeline being left blank (see `lookForBlank`).
    private func noteReader(_ proxy: ScrollViewProxy) {
        tracker.readerID = TimelineScroll.readerRow(tracker.visibleIDs, whole: tracker.wholeIDs, position: layout.position(of:))
        if let reader = tracker.readerID, layout.position(of: reader) != nil {
            tracker.lastRowID = reader
        } else {
            tracker.watchForBlank { lookForBlank(proxy) }
        }
    }

    /// Brings back a timeline that has stood still with none of its rows in view (see
    /// `TimelineScroll.recover`): to the row it was keeping, or the reader's last row while they're
    /// away from the end, else to the end. Looks again for as long as the timeline is on screen.
    private func lookForBlank(_ proxy: ScrollViewProxy) -> Bool {
        guard timeline.isLoaded else { return true }
        let hasRows = !timeline.messages.isEmpty || !timeline.pending.isEmpty
        let rowsInView = tracker.visibleIDs.contains { layout.position(of: $0) != nil }
            && tracker.geometry?.showsContent != false
        let isMoving = tracker.isScrollingByHand || tracker.isRaising || isJumpUnsettled || landingID != nil
        let keeping = (tracker.keepID ?? (tracker.isPinnedToEnd ? nil : tracker.lastRowID)).flatMap { id in
            layout.position(of: id) == nil ? nil : id
        }
        switch TimelineScroll.recover(hasRows: hasRows, rowsInView: rowsInView, isMoving: isMoving, keeping: keeping) {
        case .toEnd:
            returnToEnd(proxy)
            return true
        case .row(let id):
            // Tried once: if that doesn't bring a row into view, the next look goes to the end.
            tracker.lastRowID = nil
            tracker.keep(id, proxy)
            return true
        case nil:
            return true
        }
    }

    /// Puts the reader back where they were as the timeline comes back on screen (see
    /// `TimelineScroll.returning`), as it appears and again once it's there, unless a jump is still
    /// landing or a finger has taken over.
    private func cameBack(_ proxy: ScrollViewProxy) {
        guard timeline.isLoaded, !isJumpUnsettled, landingID == nil, !tracker.isScrollingByHand else { return }
        let reader = tracker.lastRowID.flatMap { id in layout.position(of: id) == nil ? nil : id }
        let foldedAway = MessageFolds.shared.lastToggle?.serial != foldWhenLeft
        switch TimelineScroll.returning(isPinnedToEnd: tracker.isPinnedToEnd, readerRow: reader, foldedAway: foldedAway) {
        case .toEnd: returnToEnd(proxy)
        case .row(let id): tracker.keep(id, proxy)
        case nil: break
        }
    }

    /// Brings the timeline to the end by way of its last row. A row whose height changed while the
    /// timeline was off screen can leave the stack's end where the old height put it, past the
    /// rows; scrolling to the last row lays it out as it is now, so the end is found from there.
    private func returnToEnd(_ proxy: ScrollViewProxy) {
        setPinned(true)
        if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
        tracker.move { holdAtEnd(proxy) }
    }

    /// A finger has come down on the timeline: a page at the end it's at may be asked for again.
    private func scrollBegan() {
        guard let geometry = tracker.geometry else { return see(isNearStart: isNearTop, isNearEnd: isNearBottom, byHand: true) }
        see(isNearStart: geometry.isNearStart, isNearEnd: geometry.isNearEnd, byHand: true)
    }

    private func see(isNearStart: Bool, isNearEnd: Bool, byHand: Bool) {
        var older = olderGate
        older.saw(isNear: isNearStart, scrollingByHand: byHand)
        if older != olderGate { olderGate = older }
        var newer = newerGate
        newer.saw(isNear: isNearEnd, scrollingByHand: byHand)
        if newer != newerGate { newerGate = newer }
    }

    private func setPinned(_ pinned: Bool) {
        guard tracker.isPinnedToEnd != pinned else { return }
        tracker.isPinnedToEnd = pinned
        syncAwayFromLatest()
    }

    /// Tells the session whether the reader is away from the newest messages, so a reconnect
    /// keeps what they're reading.
    private func syncAwayFromLatest() {
        let away = !tracker.isPinnedToEnd || timeline.hasNewer
        if timeline.isAwayFromLatest != away { session.setAwayFromLatest(away) }
    }

    /// This person's own message, text or file, brings the room to the bottom to show it: the end
    /// of this page, or the newest page when this one isn't it. A text sent from an older page asks
    /// for the newest itself; a file doesn't, so it's asked for here.
    private func followSend(_ proxy: ScrollViewProxy) {
        if timeline.hasNewer || timeline.isLoadingPage || session.isJumping {
            if session.isJumping || !timeline.isLoadingPage { session.jumpToLatest() }
            isAwaitingLatest = true
        } else {
            setPinned(true)
            scrollToBottom(proxy)
        }
    }

    /// Whether a jump is still to be landed: on its way, or arrived and not yet scrolled to.
    /// Paging waits, since the page it would extend is about to be replaced or scrolled away from.
    private var isJumpUnsettled: Bool {
        session.isJumping || timeline.anchor != nil
    }

    /// The newest page asked for by Jump to Latest is here.
    private var latestHasArrived: Bool {
        isAwaitingLatest && timeline.isLoaded && !timeline.isLoadingPage && !session.isJumping && !timeline.hasNewer
    }

    /// Lands on the message the latest page was centred on (see `JumpLander`), lights it if it got
    /// there, and tells the session it's been shown either way. That last step clears
    /// `timeline.anchor`, which is part of this task's id, so it cancels this run: everything after
    /// the scroll (settling, the highlight's fade) runs in tasks of its own. A landing that runs
    /// out of tries leaves the timeline where its last try put it, unlit, rather than lighting
    /// whatever happens to be there.
    private func showAnchor(_ proxy: ScrollViewProxy) async {
        guard timeline.isLoaded else { return }
        guard let anchor = timeline.anchor else {
            // No jump to land (or the one being landed was replaced by a page without one):
            // settle where the layout is.
            if !hasSettled { settleRequest += 1 }
            return
        }
        hasSettled = false
        // A beat for the page's layout to land before moving off it; on the same frame the
        // scroll can fall short. Cancelled here, a newer run (a second jump, the anchor cleared,
        // the view coming back) takes over and settles in its turn.
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        guard timeline.message(anchor) != nil else {
            settleAfterJump()
            return
        }
        landingFrame = nil
        landingID = anchor
        defer { landingID = nil }
        let tracker = tracker
        tracker.cancelMoves()
        await JumpLander.on(anchor, proxy, frame: { landingFrame }, viewport: { tracker.viewportHeight }).show(
            highlight: { highlightedID = anchor },
            shown: settleAfterJump)
    }

    private func settleAfterJump() {
        // Unsettled again even if an earlier wait finished meanwhile, so paging waits for this
        // scroll to land rather than reading the position it's leaving.
        hasSettled = false
        settleRequest += 1
        session.anchorShown()
    }

    private var wantsOlder: Bool {
        hasSettled && olderGate.isOpen && !isJumpUnsettled && isNearTop && timeline.isLoaded && timeline.hasMore
            && !timeline.isLoadingOlder && timeline.olderPageFailure == nil
    }

    private var wantsNewer: Bool {
        hasSettled && newerGate.isOpen && !isJumpUnsettled && isNearBottom && timeline.isLoaded && timeline.hasNewer
            && !timeline.isLoadingNewer && timeline.newerPageFailure == nil
    }

    /// Messages from others since the reader left the bottom: those loaded after the newest they'd
    /// seen, and those held back while a later page exists.
    private var unseenCount: Int {
        timeline.arrivals + TimelineScroll.unseen(in: timeline.messages, after: lastSeenID, me: timeline.me?.id)
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .day(let date):
            DaySeparator(date: date)
        case .message(let message, let grouped):
            MessageRow(
                message: message, grouped: grouped, me: timeline.me,
                isHighlighted: highlightedID == message.id,
                session: session, actions: actions)
            .reportsLandingFrame(if: message.id == landingID, to: $landingFrame)
        case .pending(let pending, let grouped):
            PendingRow(
                pending: pending, grouped: grouped, me: timeline.me,
                retry: { session.retry($0) }, discard: { session.discard($0) })
        }
    }

    @ViewBuilder private func jumpToLatest(proxy: ScrollViewProxy) -> some View {
        if !isNearBottom || timeline.hasNewer || session.isJumping {
            let count = unseenCount
            Button {
                // During a jump the page on screen may be the latest, but the one on its way
                // isn't: ask for the newest page rather than scroll to the end of this one.
                if timeline.hasNewer || session.isJumping {
                    isAwaitingLatest = true
                    session.jumpToLatest()
                } else {
                    setPinned(true)
                    scrollToBottom(proxy)
                }
            } label: {
                HStack(spacing: 6) {
                    if count > 0 {
                        Text(count, format: .number)
                            .monospacedDigit()
                    }
                    Image(systemName: "chevron.down")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, count > 0 ? 14 : 0)
                .frame(minWidth: 44, minHeight: 44)
                .glassBackground(in: .capsule)
            }
            .accessibilityLabel("Jump to Latest")
            .accessibilityValue(count > 0 ? "\(count) new" : "")
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
        }
    }

    /// Scrolls to the end now and again a frame later. The first keeps up with growth. When the
    /// composer shrinks, a scroll on the same pass is worked out against the inset that's going,
    /// whose end is where the offset already sits, so it lands short by what the composer lost;
    /// the second runs once the new inset has taken hold.
    private func holdAtEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        let tracker = tracker
        tracker.move {
            guard tracker.isPinnedToEnd, !tracker.isScrollingByHand, !timeline.hasNewer else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        goingToEnd(proxy)
    }

    /// Follows anything that grows while the timeline is on its way to the end, and lands it there
    /// once that's over if it was left short of it or past it.
    private func goingToEnd(_ proxy: ScrollViewProxy) {
        let tracker = tracker
        tracker.goingToEnd {
            guard tracker.isPinnedToEnd, !tracker.isScrollingByHand, !timeline.hasNewer,
                let geometry = tracker.geometry,
                geometry.distanceToEnd > 1 || TimelineScroll.bringBack(geometry, isTouched: false) == .toEnd
            else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        goingToEnd(proxy)
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private struct AnchorKey: Equatable {
        var anchor: String?
        var isLoaded: Bool
    }
}

/// In place of the spinner at an end of the timeline whose page didn't load: asking for it again
/// is left to the reader, rather than done over and over.
struct PageRetry: View {
    let retry: () -> Void

    var body: some View {
        Button("Couldn't load. Retry", action: retry)
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

extension JumpLander {
    /// Lands on the row `id` in a scroll view, measured by `reportsLandingFrame` and the visible
    /// region's height, a scroll at a time 50 ms apart.
    static func on(
        _ id: String, _ proxy: ScrollViewProxy, frame: @escaping @MainActor () -> CGRect?, viewport: @escaping @MainActor () -> CGFloat
    ) -> JumpLander {
        JumpLander(
            scroll: { placement in
                let anchor: UnitPoint = switch placement {
                case .center: .center
                case .top: .top
                case .bottom: .bottom
                }
                proxy.scrollTo(id, anchor: anchor)
            },
            measure: { Measure(frame: frame(), viewport: viewport()) },
            wait: { try await Task.sleep(for: .milliseconds(50)) })
    }
}

extension View {
    /// Keeps `frame` at where this row is in the scroll view's visible region while `isLanding`,
    /// and nil once the lazy stack lets the row go, so a jump's landing can tell when it's in view.
    func reportsLandingFrame(if isLanding: Bool, to frame: Binding<CGRect?>) -> some View {
        background {
            if isLanding {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView(axis: .vertical)) } action: { new in
                        frame.wrappedValue = new
                    }
                    .onDisappear { frame.wrappedValue = nil }
            }
        }
    }
}

/// The heading over a new day's messages.
struct DaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            line
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}
