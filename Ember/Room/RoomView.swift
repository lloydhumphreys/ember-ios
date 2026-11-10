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

    @State private var draft = ""
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

    private var room: Room? { workspace.room(link.roomID)?.room }

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
                RoomToolbar(roomID: link.roomID, room: room, status: session.status, isLoaded: session.timeline.isLoaded)
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
        if session.status == .stopped(.notFound) {
            ContentUnavailableView("Room not found", systemImage: "number")
        } else {
            RoomTimeline(
                session: session,
                sentCount: sentCount,
                actions: MessageActions(
                    edit: { message in
                        let edit = MessageEdit(message) { workspace.name(of: $0) }
                        editing = edit
                        draft = edit.text
                    },
                    customBoost: { boosting = $0 },
                    selectText: { selecting = SelectableText(text: $0) },
                    openThread: { threadLink = $0 }
                )
            )
            .safeAreaBar(edge: .bottom, spacing: 0) {
                RoomComposer(room: session, draft: $draft, editing: $editing) {
                    sentCount += 1
                }
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
    /// The custom boost's alert and the Select Text sheet, which rows in a room and in a thread
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
            .alert("Boost", isPresented: Binding(get: { boosting != nil }, set: { if !$0 { boosting = nil } })) {
                TextField("Boost", text: $customBoost)
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
                Button("Boost") {
                    if let boosting, Limits.boostFits(customBoost) {
                        room.boost(boosting.id, content: customBoost)
                    }
                    customBoost = ""
                    boosting = nil
                }
            }
            .sheet(item: $selecting) { text in
                SelectTextSheet(text: text.text)
            }
    }
}

struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}
