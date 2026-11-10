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
    /// A finger is on the timeline, or it's still coasting from one.
    @State private var isScrollingByHand = false
    /// The reader is at the end and means to stay there: set from where each scroll comes to
    /// rest, by hand or not, and left alone by changes that don't move the offset (the content
    /// or the composer changing height), which are what it answers.
    @State private var isPinnedToEnd = true
    /// The second, a frame later, of the two scrolls that hold the end.
    @State private var holdTask: Task<Void, Never>?
    /// The message a jump is landing on, and where its row is in the visible region (nil while
    /// the lazy stack hasn't built it), which tells the landing when it's in view.
    @State private var landingID: String?
    @State private var landingFrame: CGRect?
    /// The height between the navigation bar and the composer.
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "timeline-bottom"

    private var timeline: Timeline { session.timeline }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if timeline.isLoadingOlder {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    ForEach(items) { item in
                        row(item)
                    }
                    if timeline.isLoadingNewer {
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
                .padding(.top, 8)
            }
            // Opens at the end and keeps it in view as the content grows, but content shorter
            // than the screen sits at the top, under the navigation bar, rather than at the foot
            // with blank space over it.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if !timeline.isLoaded { ProgressView() }
            }
            .overlay(alignment: .bottomTrailing) {
                jumpToLatest(proxy: proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { Self.isNearEnd($0) } action: { _, near in
                isNearBottom = near
            }
            .onScrollGeometryChange(for: Bool.self) { Self.isNearStart($0) } action: { _, near in
                isNearTop = near
            }
            // Held at the end while it's read there, as the content or the composer changes
            // height (a message or a boost row arriving, an image loading, the composer growing or
            // shrinking back) without the offset moving. Not only when the change leaves the end
            // out of reach: a short row grows the content by less than the slack in `isNearEnd`
            // and would otherwise sit under the composer. Any change that moves the offset (a
            // scroll by hand, a jump, the bottom anchor answering an older page's prepend) only
            // decides whether the reader is still at the end. Not while a later page exists: the
            // end shown isn't the room's end.
            .onScrollGeometryChange(for: TimelineEnd.self) { geometry in
                TimelineEnd(
                    contentHeight: geometry.contentSize.height, inset: geometry.contentInsets.bottom,
                    container: geometry.containerSize.height, offset: geometry.contentOffset.y,
                    isNear: Self.isNearEnd(geometry))
            } action: { old, new in
                if abs(new.offset - old.offset) >= 0.5 {
                    isPinnedToEnd = new.isNear
                    return
                }
                guard isPinnedToEnd, !timeline.hasNewer, !isScrollingByHand,
                      new.contentHeight != old.contentHeight || new.inset != old.inset || new.container != old.container
                else { return }
                holdAtEnd(proxy)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in
                viewportHeight = height
            }
            .onScrollPhaseChange { _, phase in
                isScrollingByHand = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            // Asking for a page sets its loading flag there and then, which turns the wish back
            // off and adds a spinner row; from `onChange` that lands inside the same update and
            // fires it again in the frame. A task asks once the update is over.
            .task(id: wantsOlder) {
                if wantsOlder { session.loadOlder() }
            }
            .task(id: wantsNewer) {
                if wantsNewer { session.loadNewer() }
            }
            .onChange(of: sentCount) {
                scrollToBottom(proxy)
            }
            .onChange(of: latestHasArrived) { _, arrived in
                if arrived {
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
            .onDisappear { holdTask?.cancel() }
            .task(id: highlightedID) {
                guard highlightedID != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                withAnimation(.easeOut(duration: 0.6)) { highlightedID = nil }
            }
        }
    }

    private var items: [TimelineItem] {
        TimelineLayout.items(messages: timeline.messages, pending: timeline.pending, me: timeline.me?.id)
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
        await JumpLander.on(anchor, proxy, frame: { landingFrame }, viewport: { viewportHeight }).show(
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
        hasSettled && !isJumpUnsettled && isNearTop && timeline.isLoaded && timeline.hasMore && !timeline.isLoadingOlder
    }

    private var wantsNewer: Bool {
        hasSettled && !isJumpUnsettled && isNearBottom && timeline.isLoaded && timeline.hasNewer && !timeline.isLoadingNewer
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
            Button {
                // During a jump the page on screen may be the latest, but the one on its way
                // isn't: ask for the newest page rather than scroll to the end of this one.
                if timeline.hasNewer || session.isJumping {
                    isAwaitingLatest = true
                    session.jumpToLatest()
                } else {
                    scrollToBottom(proxy)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .accessibilityLabel("Jump to Latest")
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
        holdTask?.cancel()
        holdTask = Task {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard isPinnedToEnd, !isScrollingByHand, !timeline.hasNewer else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    /// Whether the end is on screen, give or take a little. The top inset (the navigation bar)
    /// counts as scrolled past; the container stops at the composer, so what's under its glass
    /// hasn't been read. Content shorter than the screen is always at its end.
    static func isNearEnd(_ geometry: ScrollGeometry) -> Bool {
        let visibleBottom = geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
        return geometry.contentSize.height - visibleBottom <= 60
    }

    /// Whether the top is close enough that the next older page should be on its way, so it has
    /// usually arrived by the time someone reaches it.
    static func isNearStart(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.contentInsets.top < 400
    }

    struct TimelineEnd: Equatable {
        var contentHeight: CGFloat
        var inset: CGFloat
        var container: CGFloat
        var offset: CGFloat
        var isNear: Bool
    }

    private struct AnchorKey: Equatable {
        var anchor: String?
        var isLoaded: Bool
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
