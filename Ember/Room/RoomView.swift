import SwiftUI
import EmberSDK
import EmberRichText

/// One room: its timeline over a live `RoomSession`, with the composer floating at the foot.
struct RoomView: View {
    let link: RoomLink

    @Environment(Workspace.self) private var workspace
    @State private var session: RoomSession?

    init(link: RoomLink) {
        self.link = link
    }

    var body: some View {
        Group {
            if let session {
                RoomScreen(link: link, session: session)
            } else {
                Color.clear
            }
        }
        .onAppear {
            // Made once for the life of the screen, so a push back from a deeper screen comes
            // back to the same timeline rather than a fresh connection.
            if session == nil {
                session = workspace.session(for: link.roomID, around: link.messageID)
            }
        }
    }
}

private struct RoomScreen: View {
    let link: RoomLink
    let session: RoomSession

    @Environment(Workspace.self) private var workspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.returnHome) private var returnHome

    @State private var editing: MessageEdit?
    /// The message a custom boost is being typed for.
    @State private var boosting: Message?
    @State private var selecting: SelectableText?
    /// Bumped when this person sends, so the timeline goes to the bottom to show it.
    @State private var sentCount = 0
    /// This screen's hold on the room's socket. The session is shared with any other screen
    /// showing the same room (another tab's stack), so each keeps its own lease rather than
    /// starting and stopping the session under the other.
    @State private var lease: RoomLease?
    /// The thread pushed from a row. A row's context menu can't hold a navigation link, so rows
    /// ask and the screen pushes.
    @State private var threadLink: RoomLink?
    /// Whether this is the screen on top, so its alert doesn't try to show from under a thread
    /// showing the same notice.
    @State private var isShown = false
    /// The room as the sidebar last listed it while this screen showed, kept once it's gone.
    @State private var listed: Room?
    @State private var isShowingInfo = false
    /// Set when you deleted the room, or saved it without you, from its details here.
    @State private var hasLeft = false

    private var room: Room? { workspace.room(link.roomID)?.room }

    private var gone: RoomGone? {
        RoomGone(wasListed: listed != nil, isListed: room != nil, status: session.status, hasLeft: hasLeft)
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            // A room is a place you're in, not one you pass through: the tabs would only sit
            // between the composer and the home indicator, and Back is how you leave. They come
            // back at the top of the stack, on the tab that was showing.
            .toolbar(.hidden, for: .tabBar)
            .navigationBarBackButtonHidden()
            .keepsSwipeBack()
            .toolbar {
                RoomToolbar(
                    roomID: link.roomID,
                    room: room ?? listed,
                    status: session.status,
                    isLoaded: session.timeline.isLoaded,
                    openInfo: room != nil && gone == nil ? { isShowingInfo = true } : nil
                )
            }
            // On the screen rather than the title, which goes with the room, so deleting the room
            // from here still comes back to take the tab home.
            .sheet(isPresented: $isShowingInfo, onDismiss: {
                if hasLeft { returnHome() }
            }) {
                // Left is known before Edit Room is down, so the room behind never says it was deleted.
                RoomInfoView(roomID: link.roomID, present: session.timeline.present, onLeaving: { hasLeft = true }) {
                    hasLeft = true
                    isShowingInfo = false
                }
            }
            .onChange(of: room, initial: true) { _, room in
                if let room { listed = room }
            }
            .onAppear {
                isShown = true
                if lease == nil || lease?.isClosed == true { lease = session.open() }
                session.setVisible(scenePhase == .active)
                workspace.currentRoomID = link.roomID
                workspace.markRead(link.roomID)
            }
            .onDisappear {
                isShown = false
                session.setTyping(false)
                lease.map(Lease.closeSoon)
                lease = nil
                // Another room may already have taken over by the time this one goes, when one
                // room is pushed over another.
                if workspace.currentRoomID == link.roomID { workspace.currentRoomID = nil }
                workspace.markRead(link.roomID)
            }
            .onChange(of: scenePhase) { _, phase in
                session.setVisible(phase == .active)
            }
            .alert(
                session.notice ?? "",
                isPresented: Binding(get: { isShown && session.notice != nil }, set: { if !$0 { session.notice = nil } })
            ) {
                Button("OK", role: .cancel) { session.notice = nil }
            }
            .messageActionPresentations(room: session, boosting: $boosting, selecting: $selecting)
            // On the screen rather than a row, which the lazy timeline may let go of.
            .navigationDestination(item: $threadLink) { ThreadView(link: $0) }
    }

    @ViewBuilder private var content: some View {
        if gone == .deleted, !session.timeline.isLoaded {
            // Gone with nothing of it to show.
            ContentUnavailableView(RoomGone.deletedText, systemImage: "number")
        } else if gone == nil || gone == .notFound, let unavailable = RoomUnavailable(session.status) {
            RoomUnavailableView(reason: unavailable, place: .room) {
                lease = RoomUnavailable.retry(session, keeping: lease)
            }
        } else {
            RoomTimeline(
                session: session,
                sentCount: sentCount,
                actions: MessageActions(
                    edit: { message in
                        let edit = MessageEdit(message) { workspace.name(of: $0) }
                        editing = edit
                    },
                    customBoost: { boosting = $0 },
                    selectText: { selecting = SelectableText(text: $0) },
                    openThread: { threadLink = $0 },
                    message: { session.timeline.message($0) }
                )
            )
            .bottomBar(spacing: 0) {
                if let gone, gone.saysDeleted {
                    RoomDeletedNotice()
                } else {
                    RoomComposer(room: session, editing: $editing) {
                        sentCount += 1
                    }
                }
            }
        }
    }
}

/// What's become of a room shown that isn't there any more, as the web has it. One you deleted or
/// left here goes home. One that was there and went otherwise, deleted by someone else or with you
/// taken out of it, stays to say it was deleted. One never listed and not found was never yours to
/// see.
enum RoomGone: Equatable {
    /// Never listed, and its socket says it isn't there: "Room not found".
    case notFound
    /// It was there, and went without you doing it here: its messages stay, and it says so.
    case deleted
    /// You deleted it, or saved it without you, from its details: the tab goes home.
    case left

    static let deletedText = "This room was deleted."

    /// Whether the screen says the room was deleted. Not one you left here: it's on its way home,
    /// and looks as it did until it goes.
    var saysDeleted: Bool { self != .left }

    /// - Parameters:
    ///   - wasListed: whether the sidebar listed the room while the screen showed.
    ///   - isListed: whether it lists it now.
    ///   - status: the room's socket.
    ///   - hasLeft: whether you deleted or left the room from this screen.
    init?(wasListed: Bool, isListed: Bool, status: ConnectionStatus, hasLeft: Bool) {
        if hasLeft {
            self = .left
        } else if wasListed, !isListed {
            self = .deleted
        } else if case .stopped(.notFound) = status {
            self = wasListed ? .deleted : .notFound
        } else {
            return nil
        }
    }
}

/// In place of the composer, once the room has gone from under it.
private struct RoomDeletedNotice: View {
    var body: some View {
        Text(RoomGone.deletedText)
            .font(.subheadline)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Why a room or a thread shows no timeline: its socket stopped for good, where trying again on
/// its own wouldn't help.
enum RoomUnavailable: Equatable {
    /// The room is gone, or you're no longer in it.
    case notFound
    /// The server refused the connection.
    case refused

    init?(_ status: ConnectionStatus) {
        switch status {
        case .stopped(.notFound): self = .notFound
        case .stopped(.refused): self = .refused
        default: return nil
        }
    }

    /// Retry: connects the room again, keeping the screen's lease, or taking one if it has none,
    /// whether or not another screen's lease holds the room too.
    @MainActor static func retry(_ session: RoomSession, keeping lease: RoomLease?) -> RoomLease {
        let held = lease.flatMap { $0.isClosed ? nil : $0 } ?? session.open()
        session.reconnect()
        return held
    }

    /// Retry for a thread, as for a room.
    @MainActor static func retry(_ thread: ThreadSession, keeping lease: ThreadLease?) -> ThreadLease {
        let held = lease.flatMap { $0.isClosed ? nil : $0 } ?? thread.open()
        thread.reconnect()
        return held
    }
}

/// A room or thread that can't be shown: not found, or refused with Retry.
struct RoomUnavailableView: View {
    enum Place { case room, thread }

    let reason: RoomUnavailable
    let place: Place
    let retry: () -> Void

    var body: some View {
        switch reason {
        case .notFound:
            switch place {
            case .room: ContentUnavailableView("Room not found", systemImage: "number")
            case .thread: ContentUnavailableView("This message no longer exists.", systemImage: "bubble.left.and.bubble.right")
            }
        case .refused:
            ContentUnavailableView {
                Label(place == .room ? "Couldn’t open room" : "Couldn’t open thread", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// What a row can ask the screen to do. The confirmations for deleting and discarding live on
/// the row instead, so their popover points at the message they're about.
struct MessageActions {
    var edit: (Message) -> Void
    var customBoost: (Message) -> Void
    var selectText: (String) -> Void
    /// Pushes a thread; unused inside one, which has nowhere further to go.
    var openThread: (RoomLink) -> Void = { _ in }
    /// The message with this id as the screen has it now, if it has it.
    var message: (MessageID) -> Message? = { _ in nil }

    /// Whether the screen shows this message deleted, so a deletion that failed to answer made it.
    func showsDeleted(_ messageID: MessageID) -> Bool {
        message(messageID)?.isDeleted == true
    }

    /// Whether the screen shows this message without this boost, so a removal that failed to
    /// answer made it.
    func showsRemoved(boost boostID: BoostID, from messageID: MessageID) -> Bool {
        message(messageID).map { message in !message.boosts.contains { $0.id == boostID } } ?? false
    }
}

/// Letting go of a screen's lease a moment after it goes, rather than at once. Pushing a thread
/// over its room (or popping back) can bring the old screen's `onDisappear` before the new one's
/// `onAppear`, and a room whose last lease closes stops its socket there and then; held for a
/// second, the socket stays up while the other screen takes its own lease.
enum Lease {
    static let grace: Duration = .seconds(1)

    @MainActor static func closeSoon(_ lease: RoomLease) {
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            lease.close()
        }
    }

    @MainActor static func closeSoon(_ lease: ThreadLease) {
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            lease.close()
        }
    }
}

extension View {
    /// The custom boost's alert, the Select Text sheet and the person sheet, which rows in a room and in a thread
    /// both ask for. Boosts go through the room, wherever the message is shown.
    func messageActionPresentations(room: RoomSession, boosting: Binding<Message?>, selecting: Binding<SelectableText?>) -> some View {
        modifier(MessageActionPresentations(room: room, boosting: boosting, selecting: selecting))
    }
}

private struct MessageActionPresentations: ViewModifier {
    let room: RoomSession
    @Binding var boosting: Message?
    @Binding var selecting: SelectableText?

    @State private var customBoost = ""

    func body(content: Content) -> some View {
        content
            .alert("React", isPresented: Binding(get: { boosting != nil }, set: { if !$0 { boosting = nil } })) {
                TextField("Reaction", text: $customBoost)
                    // A reaction, not a sentence.
                    .textInputAutocapitalization(.never)
                    // The server counts UTF-16 units, so the field is clamped the same way. The
                    // clamp watches the string rather than sitting in the field's binding: there,
                    // a value already at the limit doesn't change, so the field isn't redrawn and
                    // keeps the extra characters it was just given.
                    .onChange(of: customBoost) { _, text in
                        let clamped = Limits.clampedBoost(text)
                        if clamped != text { customBoost = clamped }
                    }
                Button("Cancel", role: .cancel) { customBoost = ""; boosting = nil }
                Button("React") {
                    if let boosting, Limits.boostFits(customBoost) {
                        BoostChoices.boost(boosting, with: customBoost, in: room)
                    }
                    customBoost = ""
                    boosting = nil
                }
            }
            .sheet(item: $selecting) { text in
                SelectTextSheet(text: text.text)
            }
            // Whoever a message's face or name is tapped for.
            .presentsPeople()
    }
}

struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}
