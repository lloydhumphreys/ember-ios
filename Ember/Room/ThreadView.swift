import SwiftUI
import EmberSDK

/// One thread: its parent, how many replies it has, and the replies, over the room's socket,
/// with the composer at the foot as in a room.
struct ThreadView: View {
    let link: RoomLink

    @Environment(Workspace.self) private var workspace
    @State private var thread: ThreadSession?

    var body: some View {
        Group {
            if let thread {
                ThreadScreen(thread: thread)
            } else {
                Color.clear
            }
        }
        .onAppear {
            // The room's own session, so a thread pushed from its room shares the room's socket
            // and timeline rather than opening another; and the thread the room already holds,
            // when another screen has it open.
            guard thread == nil, let parentID = link.threadID else { return }
            thread = workspace.thread(parentID, in: link.roomID, at: link.messageID)
        }
    }
}

private struct ThreadScreen: View {
    let thread: ThreadSession

    @Environment(Workspace.self) private var workspace
    @Environment(NetworkStatus.self) private var network
    @State private var editing: MessageEdit?
    @State private var boosting: Message?
    @State private var selecting: SelectableText?
    @State private var sentCount = 0
    /// Holds the thread open on the room's socket, and the socket up, while the screen shows.
    @State private var lease: ThreadLease?

    private var room: RoomSession { thread.room }

    /// The thread's own notice first, then the room's (an edit or boost refused while offline).
    private var notice: String? { thread.notice ?? room.notice }

    var body: some View {
        content
            .navigationTitle("Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                if let connection = RoomConnection(isOnline: network.isOnline, isLoaded: thread.timeline.isLoaded, status: room.status) {
                    ToolbarItem(placement: .topBarTrailing) {
                        RoomConnectionView(connection: connection)
                    }
                }
            }
            .onAppear {
                if lease == nil || lease?.isClosed == true { lease = thread.open() }
            }
            .onDisappear {
                lease.map(Lease.closeSoon)
                lease = nil
            }
            .alert(
                notice ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { clearNotice() } })
            ) {
                Button("OK", role: .cancel) { clearNotice() }
            }
            .messageActionPresentations(room: room, boosting: $boosting, selecting: $selecting)
    }

    @ViewBuilder private var content: some View {
        if let unavailable = thread.timeline.parent == .gone ? .notFound : RoomUnavailable(room.status) {
            RoomUnavailableView(reason: unavailable, place: .thread) {
                lease = RoomUnavailable.retry(thread, keeping: lease)
            }
        } else {
            ThreadTimelineView(
                thread: thread,
                sentCount: sentCount,
                actions: MessageActions(
                    edit: { message in
                        let edit = MessageEdit(message) { workspace.name(of: $0) }
                        editing = edit
                    },
                    customBoost: { boosting = $0 },
                    selectText: { selecting = SelectableText(text: $0) },
                    message: { id in
                        id == thread.parentID ? thread.timeline.parentMessage : thread.timeline.replies.first { $0.id == id }
                    }
                )
            )
            .bottomBar(spacing: 0) {
                if thread.timeline.canReply {
                    RoomComposer(room: room, thread: thread, editing: $editing) {
                        sentCount += 1
                    }
                }
            }
        }
    }

    private func clearNotice() {
        if thread.notice != nil { thread.notice = nil } else { room.notice = nil }
    }
}

/// The parent at the top, then the replies, newest at the foot. It keeps to the end as replies
/// arrive while read there, as the room does, loads older replies as the top comes near, and
/// brings the reply a link went to into view.
private struct ThreadTimelineView: View {
    let thread: ThreadSession
    let sentCount: Int
    let actions: MessageActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isNearTop = false
    /// Paging waits for the first layout (and the scroll to a linked reply) to land.
    @State private var hasSettled = false
    @State private var highlightedID: MessageID?
    /// The reply a link is landing on, and where its row is, as the room's jump has them.
    @State private var landingID: MessageID?
    @State private var landingFrame: CGRect?
    @State private var olderGate = PagingGate()
    @State private var tracker = TimelineTracker()
    @State private var layout = TimelineLayoutCache(in: .thread)
    /// The last fold this timeline has stopped holding its offset for, as in the room.
    @State private var settledFold = MessageFolds.shared.lastToggle?.serial

    private static let bottomID = "thread-bottom"

    private var timeline: ThreadTimeline { thread.timeline }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let parent = timeline.parentMessage {
                        MessageRow(
                            message: parent, grouped: false, me: timeline.me, isHighlighted: false,
                            session: thread.room, actions: actions, place: .threadParent)
                        .id(TimelineItem.rowID(parent.id))
                        if let count = TimelineLayout.replyCount(summary: parent.thread?.count, loaded: timeline.replies.count) {
                            RepliesDivider(count: count)
                        }
                    }
                    if timeline.isLoadingOlder {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                    Color.clear
                        .frame(height: 8)
                        .id(Self.bottomID)
                }
                .scrollTargetLayout()
                .padding(.top, 8)
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
            .onScrollPhaseChange { old, phase in
                tracker.isScrollingByHand = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .tracking, old != .tracking { tracker.handTookOver() }
                if PagingGate.fingerCameDown(from: old, to: phase), !olderGate.isOpen {
                    olderGate.saw(isNear: isNearTop, scrollingByHand: true)
                }
            }
            // A task rather than `onChange`, as in the room: asking sets the loading flag at once,
            // which would turn the wish off again within the same update.
            .task(id: wantsOlder) {
                guard wantsOlder else { return }
                olderGate.asked()
                thread.loadOlder()
            }
            // Older replies landing above the reader are kept from carrying them down the screen,
            // as in the room.
            // A reply folded or unfolded keeps its place, as in the room.
            .onChange(of: MessageFolds.shared.lastToggle) { _, toggle in
                guard let toggle, isFoldHere(toggle) else { return }
                tracker.hold(toggle)
            }
            .onChange(of: MessageFolds.shared.raising) { _, raise in
                guard let raise, raise.place != .room else { return }
                let row = TimelineItem.rowID(raise.messageID)
                guard position(of: row) != nil else { return MessageFolds.shared.dropped(raise) }
                tracker.raise(row, proxy) { MessageFolds.shared.raised(raise) }
            }
            .task(id: MessageFolds.shared.lastToggle?.serial) {
                guard let serial = MessageFolds.shared.lastToggle?.serial, serial != settledFold else { return }
                do { try await Task.sleep(for: TimelineScroll.foldHold) } catch { return }
                settledFold = serial
            }
            .onChange(of: timeline.replies.first?.id) {
                guard !tracker.isPinnedToEnd, timeline.focus == nil, let top = tracker.topID else { return }
                tracker.keepOnNextLayout(top)
            }
            .onChange(of: sentCount) {
                tracker.isPinnedToEnd = true
                scrollToBottom(proxy)
            }
            .task(id: FocusKey(focus: timeline.focus, isLoaded: timeline.isLoaded)) {
                await showFocus(proxy)
            }
            .task(id: highlightedID) {
                guard highlightedID != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                withAnimation(.easeOut(duration: 0.6)) { highlightedID = nil }
            }
            .onAppear { tracker.watchForBlank { lookForBlank(proxy) } }
            .onDisappear {
                tracker.leave()
                settledFold = MessageFolds.shared.lastToggle?.serial
            }
        }
    }

    private var items: [TimelineItem] {
        layout.items(messages: timeline.replies, pending: timeline.pending, me: timeline.me?.id)
    }

    /// One geometry change, read once, as the room reads it (see `TimelineScroll.decide`).
    private func scrolled(from old: TimelineGeometry, to new: TimelineGeometry, _ proxy: ScrollViewProxy) {
        tracker.geometry = new
        tracker.viewportHeight = new.containerHeight
        let resized = new.viewportChanged(from: old)
        if let keep = tracker.keepID {
            switch TimelineScroll.keeping(from: old, to: new, isTouched: tracker.isScrollingByHand) {
            case .toEnd:
                tracker.cancelMoves()
                tracker.isPinnedToEnd = true
                holdAtEnd(proxy)
            case .keepRow: tracker.keep(keep, proxy)
            case .none: break
            }
        } else {
            let decision = TimelineScroll.decide(
                from: old, to: new, isPinnedToEnd: tracker.isPinnedToEnd, canHoldEnd: !tracker.isScrollingByHand,
                isHoldingFold: isHoldingFold, isTouched: tracker.isScrollingByHand, isGoingToEnd: tracker.isGoingToEnd)
            tracker.isPinnedToEnd = decision.isPinnedToEnd
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
        if isNearTop != new.isNearStart { isNearTop = new.isNearStart }
        var gate = olderGate
        gate.saw(isNear: new.isNearStart, scrollingByHand: false)
        if gate != olderGate { olderGate = gate }
    }

    /// Whether `toggle` was the parent or a reply folded or unfolded in this thread.
    private func isFoldHere(_ toggle: MessageFolds.Toggle) -> Bool {
        TimelineScroll.isFold(toggle, inThread: true)
            && (toggle.messageID == timeline.parentMessage?.id || timeline.replies.contains { $0.id == toggle.messageID })
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

    /// Where the row `id` falls, the parent first, then the replies' rows.
    private func position(of id: String) -> Int? {
        id == timeline.parentMessage.map({ TimelineItem.rowID($0.id) }) ? -1 : layout.position(of: id)
    }

    /// As the room notes it.
    private func noteReader(_ proxy: ScrollViewProxy) {
        tracker.readerID = TimelineScroll.readerRow(tracker.visibleIDs, whole: tracker.wholeIDs, position: position(of:))
        if let reader = tracker.readerID, position(of: reader) != nil {
            tracker.lastRowID = reader
        } else {
            tracker.watchForBlank { lookForBlank(proxy) }
        }
    }

    /// As the room brings itself back from showing none of its rows.
    private func lookForBlank(_ proxy: ScrollViewProxy) -> Bool {
        guard timeline.isLoaded else { return true }
        let hasRows = timeline.parentMessage != nil || !timeline.replies.isEmpty || !timeline.pending.isEmpty
        let rowsInView = tracker.visibleIDs.contains { position(of: $0) != nil }
            && tracker.geometry?.showsContent != false
        let isMoving = tracker.isScrollingByHand || tracker.isRaising || timeline.focus != nil || landingID != nil
        let keeping = (tracker.keepID ?? (tracker.isPinnedToEnd ? nil : tracker.lastRowID)).flatMap { id in
            position(of: id) == nil ? nil : id
        }
        switch TimelineScroll.recover(hasRows: hasRows, rowsInView: rowsInView, isMoving: isMoving, keeping: keeping) {
        case .toEnd:
            // As the room does it (see `RoomTimeline.returnToEnd`).
            tracker.isPinnedToEnd = true
            if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            tracker.move { holdAtEnd(proxy) }
            return true
        case .row(let id):
            tracker.lastRowID = nil
            tracker.keep(id, proxy)
            return true
        case nil:
            return true
        }
    }

    /// Not while a link's reply is still being paged back to: the thread does that itself.
    private var wantsOlder: Bool {
        hasSettled && olderGate.isOpen && timeline.focus == nil && isNearTop && timeline.isLoaded && timeline.hasMore && !timeline.isLoadingOlder
    }

    /// Lands on the reply a link went to once the thread has it, as the room lands a jump, lights
    /// it if it got there, and tells the thread either way, which clears `focus` and so cancels
    /// this run; settling then runs here alone. Cancelled before it's done, the focus stays for the
    /// run that takes over.
    private func showFocus(_ proxy: ScrollViewProxy) async {
        guard timeline.isLoaded else { return }
        if let focus = timeline.focus {
            hasSettled = false
            // A beat for the page's layout to land, as the room waits before a jump's scroll.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard timeline.replies.contains(where: { $0.id == focus }) else {
                thread.focusShown()
                return
            }
            landingFrame = nil
            landingID = focus
            defer { landingID = nil }
            tracker.cancelMoves()
            await JumpLander.on(TimelineItem.rowID(focus), proxy, frame: { landingFrame }, viewport: { tracker.viewportHeight }).show(
                highlight: { highlightedID = focus },
                shown: {
                    // Left where the landing put it, rather than taken back to the end as the
                    // content grows.
                    tracker.isPinnedToEnd = false
                    thread.focusShown()
                })
            return
        }
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        hasSettled = true
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .day(let date):
            DaySeparator(date: date)
        case .message(let message, let grouped):
            MessageRow(
                message: message, grouped: grouped, me: timeline.me,
                isHighlighted: highlightedID == message.id,
                session: thread.room, actions: actions, place: .threadReply)
            .reportsLandingFrame(if: message.id == landingID, to: $landingFrame)
        case .pending(let pending, let grouped):
            PendingRow(
                pending: pending, grouped: grouped, me: timeline.me,
                retry: { thread.retry($0) }, discard: { thread.discard($0) })
        }
    }

    /// As the room's: now, and again a frame later once a shrinking composer's inset has gone.
    private func holdAtEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
        let tracker = tracker
        tracker.move {
            guard tracker.isPinnedToEnd, !tracker.isScrollingByHand else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        goingToEnd(proxy)
    }

    /// As the room's: anything that grows on the way to the end is followed, and the end landed
    /// once that's over.
    private func goingToEnd(_ proxy: ScrollViewProxy) {
        let tracker = tracker
        tracker.goingToEnd {
            guard tracker.isPinnedToEnd, !tracker.isScrollingByHand, let geometry = tracker.geometry,
                geometry.distanceToEnd > 1 || TimelineScroll.bringBack(geometry, isTouched: false) == .toEnd
            else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        goingToEnd(proxy)
        if reduceMotion {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private struct FocusKey: Equatable {
        var focus: MessageID?
        var isLoaded: Bool
    }
}

/// Between the parent and its replies: how many there are, on a rule.
private struct RepliesDivider: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("^[\(count) reply](inflect: true)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
