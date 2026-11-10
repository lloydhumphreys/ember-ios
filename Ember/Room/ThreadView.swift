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
            thread = workspace.session(for: link.roomID).thread(parentID, at: link.messageID)
        }
    }
}

private struct ThreadScreen: View {
    let thread: ThreadSession

    @Environment(Workspace.self) private var workspace
    @State private var draft = ""
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
        if thread.timeline.parent == .gone || room.status == .stopped(.notFound) {
            ContentUnavailableView("This message no longer exists.", systemImage: "bubble.left.and.bubble.right")
        } else {
            ThreadTimelineView(
                thread: thread,
                sentCount: sentCount,
                actions: MessageActions(
                    edit: { message in
                        let edit = MessageEdit(message) { workspace.name(of: $0) }
                        editing = edit
                        draft = edit.text
                    },
                    customBoost: { boosting = $0 },
                    selectText: { selecting = SelectableText(text: $0) }
                )
            )
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if thread.timeline.canReply {
                    RoomComposer(room: room, thread: thread, draft: $draft, editing: $editing, focusesOnAppear: true) {
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
    @State private var highlightedID: String?
    @State private var isScrollingByHand = false
    @State private var isPinnedToEnd = true
    @State private var holdTask: Task<Void, Never>?
    /// The reply a link is landing on, and where its row is, as the room's jump has them.
    @State private var landingID: String?
    @State private var landingFrame: CGRect?
    @State private var viewportHeight: CGFloat = 0

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
            .onScrollGeometryChange(for: Bool.self) { RoomTimeline.isNearStart($0) } action: { _, near in
                isNearTop = near
            }
            // Held at the end as the content or the composer changes height, as the room's is; a
            // change that moves the offset only decides whether the reader is still there.
            .onScrollGeometryChange(for: RoomTimeline.TimelineEnd.self) { geometry in
                RoomTimeline.TimelineEnd(
                    contentHeight: geometry.contentSize.height, inset: geometry.contentInsets.bottom,
                    container: geometry.containerSize.height, offset: geometry.contentOffset.y,
                    isNear: RoomTimeline.isNearEnd(geometry))
            } action: { old, new in
                if abs(new.offset - old.offset) >= 0.5 {
                    isPinnedToEnd = new.isNear
                    return
                }
                guard isPinnedToEnd, !isScrollingByHand,
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
            // A task rather than `onChange`, as in the room: asking sets the loading flag at once,
            // which would turn the wish off again within the same update.
            .task(id: wantsOlder) {
                if wantsOlder { thread.loadOlder() }
            }
            .onChange(of: sentCount) {
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
            .onDisappear { holdTask?.cancel() }
        }
    }

    private var items: [TimelineItem] {
        TimelineLayout.items(messages: timeline.replies, pending: timeline.pending, me: timeline.me?.id, in: .thread)
    }

    /// Not while a link's reply is still being paged back to: the thread does that itself.
    private var wantsOlder: Bool {
        hasSettled && timeline.focus == nil && isNearTop && timeline.isLoaded && timeline.hasMore && !timeline.isLoadingOlder
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
            await JumpLander.on(focus, proxy, frame: { landingFrame }, viewport: { viewportHeight }).show(
                highlight: { highlightedID = focus },
                shown: {
                    // Left where the landing put it, rather than taken back to the end as the
                    // content grows.
                    isPinnedToEnd = false
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
        holdTask?.cancel()
        holdTask = Task {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard isPinnedToEnd, !isScrollingByHand else { return }
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private struct FocusKey: Equatable {
        var focus: String?
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
