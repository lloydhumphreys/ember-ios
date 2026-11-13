import Foundation
import Testing
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// Edits, deletions and boosts sent through the room's `async` calls, messages that didn't send,
/// and text typed in plain, each against a room on a mock socket.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct RoomChangesTests {
    let connector = MockSocketConnector()
    let clock = ManualClock()

    func session() -> RoomSession {
        connector.welcomeEverySocket()
        let timing = EmberTiming(clock: clock, random: { 0.5 })
        return RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: MemoryUnsentMessageStore())
    }

    func opened(_ session: RoomSession) async throws -> MockSocketConnection {
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open && session.phase == .admitted })
        return try #require(connector.latest)
    }

    func sent(_ socket: MockSocketConnection, _ type: String) -> [SentFrame] {
        socket.sentFrames.filter { $0.type == type }
    }

    /// The bodies of the messages the client created.
    func created(_ socket: MockSocketConnection) -> [String] {
        socket.sentFrames.compactMap {
            $0.type == "message.create" ? $0.string("body") : nil
        }
    }

    /// The text a body shows, its line breaks as newlines.
    func shown(_ body: String) -> String {
        RichText.document(html: body, plainText: "", host: "ember.test").blocks.map { block in
            guard case let .paragraph(inlines) = block else { return "" }
            return inlines.map { inline in
                switch inline {
                case let .text(text, _): text
                case .lineBreak: "\n"
                default: ""
                }
            }.joined()
        }.joined(separator: "\n")
    }

    /// The message with `id` as the room shows it, with no boosts and not deleted.
    func asShown(_ id: MessageID) -> Message {
        Fixtures.message(id, "Hi")
    }

    // MARK: Changes

    @Test func aChangeTheRoomMakesIsForgotten() async throws {
        let session = session()
        let socket = try await opened(session)
        let changes = SentChanges()
        let key = SentChanges.Key.delete("m002")
        let deleting = Task { await changes.send(key) { try await session.delete(message: "m002") } }
        #expect(await eventually { sent(socket, "message.delete").count == 1 })
        #expect(changes.isSending(key))
        socket.serverSends(Fixtures.RoomFrames.messageDeleted("m002", seq: 11))
        #expect(await deleting.value)
        #expect(changes.states.isEmpty)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id).isEmpty)
    }

    @Test func aChangeTheRoomRefusesIsKeptToRetry() async throws {
        let session = session()
        let socket = try await opened(session)
        let changes = SentChanges()
        let key = SentChanges.Key.boost("m002", "🎉")
        let boosting = Task { await changes.send(key) { try await session.boost(message: "m002", content: "🎉") } }
        #expect(await eventually { sent(socket, "boost.create").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.error("You can’t boost that"))
        #expect(await boosting.value == false)
        #expect(changes.hasFailed(key))
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id) == [key])
        #expect(session.notice == nil)

        let retrying = Task { await changes.retry(key) }
        #expect(await eventually { sent(socket, "boost.create").count == 2 })
        #expect(changes.isSending(key))
        changes.dismiss(key)
        socket.serverSends(Fixtures.RoomFrames.error("You can’t boost that"))
        #expect(await retrying.value == false)
        #expect(changes.states.isEmpty)
    }

    @Test func aChangeTheRoomDoesntAnswerFailsWhenItTimesOut() async throws {
        let session = session()
        let socket = try await opened(session)
        let changes = SentChanges()
        let key = SentChanges.Key.delete("m002")
        let before = clock.sleeperCount
        let deleting = Task { await changes.send(key) { try await session.delete(message: "m002") } }
        #expect(await eventually { sent(socket, "message.delete").count == 1 && clock.sleeperCount > before })
        clock.advance(by: RoomSession.changeTimeout)
        #expect(await deleting.value == false)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id) == [key])

        let retrying = Task { await changes.retry(key) }
        #expect(await eventually { sent(socket, "message.delete").count == 2 })
        socket.serverSends(Fixtures.RoomFrames.messageDeleted("m002", seq: 11))
        #expect(await retrying.value)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id).isEmpty)
    }

    @Test func theSameChangeIsntSentTwiceWhileOneIsOnItsWay() async throws {
        let session = session()
        let socket = try await opened(session)
        let changes = SentChanges()
        let key = SentChanges.Key.delete("m002")
        let first = Task { await changes.send(key) { try await session.delete(message: "m002") } }
        #expect(await eventually { sent(socket, "message.delete").count == 1 })
        #expect(await changes.send(key) { try await session.delete(message: "m002") } == false)
        #expect(sent(socket, "message.delete").count == 1)
        socket.serverSends(Fixtures.RoomFrames.messageDeleted("m002", seq: 11))
        #expect(await first.value)
    }

    @Test func aFailedEditStaysForTheComposerAndNotUnderItsMessage() async throws {
        let session = session()
        let socket = try await opened(session)
        let changes = SentChanges()
        let message = try #require(session.timeline.message("m001"))
        let edit = MessageEdit(message)
        let body = try #require(edit.body(for: "Changed"))
        let saving = Task { await RoomComposer.save(edit, body: body, in: session, changes: changes) }
        #expect(await eventually { sent(socket, "message.update").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.error("You can only edit your own messages"))
        #expect(await saving.value == false)
        #expect(changes.hasFailed(.edit("m001")))
        #expect(changes.failures(of: asShown("m001"), me: Fixtures.ada.id).isEmpty)
    }

    /// Saves `message` edited to mention Bo, chosen after "@B" typed at its end, and returns the
    /// body the room was sent.
    func savedMentioningBo(_ message: Message, in session: RoomSession, on socket: MockSocketConnection) async throws -> String {
        let edit = MessageEdit(message)
        let typed = Draft(text: edit.text + " cc @B")
        let chosen = try #require(edit.mentionQuery(in: typed)).choosing(Self.bo, name: "Bo", in: typed)
        #expect(edit.canSave(chosen.draft))
        let body = try #require(edit.body(for: chosen.draft))
        let saving = Task { await RoomComposer.save(edit, body: body, in: session, changes: SentChanges()) }
        #expect(await eventually { sent(socket, "message.check").count == 1 })
        guard case let .array(ids)? = sent(socket, "message.check").first?["clientMessageIds"] else { throw Failure() }
        let markers = ids.compactMap { if case let .string(id) = $0 { ClientMessageID(id) } else { nil } }
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: markers))
        #expect(await saving.value)
        let updates = sent(socket, "message.update")
        guard updates.count == 1, let id = updates[0].string("messageId"), let sentBody = updates[0].string("body") else { throw Failure() }
        #expect(MessageID(id) == message.id)
        return sentBody
    }

    static let bo: UserID = "1abcdefghijklmno"
    static let boMention = "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(bo.rawValue)\"></action-text-attachment>"

    @Test func anEditInTheRoomSendsTheMentionChosen() async throws {
        let session = session()
        let socket = try await opened(session)
        let message = try #require(session.timeline.message("m001"))
        let body = try await savedMentioningBo(message, in: session, on: socket)
        #expect(body == message.body.replacing("</p>", with: " cc \(Self.boMention)</p>"))
    }

    @Test func anEditOfAThreadReplySendsTheMentionChosen() async throws {
        let session = session()
        let socket = try await opened(session)
        var reply = Fixtures.message("r001", "On it", minute: 9)
        reply.parentId = "m001"
        let body = try await savedMentioningBo(reply, in: session, on: socket)
        #expect(body == "<p>On it cc \(Self.boMention)</p>")
    }

    @Test func anEditSavedClosesWhateverWasTypedWhileItWasOnItsWay() async throws {
        let session = session()
        _ = try await opened(session)
        let message = try #require(session.timeline.message("m001"))
        let other = try #require(session.timeline.message("m002"))
        let saved = MessageEdit(message)
        #expect(RoomComposer.closesEdit(saved: saved, editing: MessageEdit(message)))
        #expect(!RoomComposer.closesEdit(saved: saved, editing: MessageEdit(other)))
        #expect(!RoomComposer.closesEdit(saved: saved, editing: nil))
    }

    @Test func aChangeWhileDisconnectedFailsWhenItsLimitRunsOut() async throws {
        let session = session()
        let socket = try await opened(session)
        connector.onConnect { $0.serverCloses(code: 1006) }
        socket.serverCloses(code: 1006)
        #expect(await eventually { session.phase != .admitted })
        let changes = SentChanges()
        let key = SentChanges.Key.removeBoost("m002", "b1")
        let sending = Task { await changes.send(key) { try await session.removeBoost(id: "b1") } }
        #expect(await eventually { changes.isSending(key) })
        #expect(changes.isSendingChange(to: "m002"))
        #expect(!changes.isSendingChange(to: "m003"))
        for _ in 0 ..< 4 {
            clock.advance(by: .seconds(5))
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await sending.value == false)
        #expect(changes.hasFailed(key))
        #expect(!changes.isSendingChange(to: "m002"))
    }

    @Test func signingOutForgetsAFailedChange() async {
        let changes = SentChanges()
        let key = SentChanges.Key.delete("m002")
        #expect(await changes.send(key) { throw Failure() } == false)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id) == [key])
        changes.removeAll()
        #expect(changes.states.isEmpty)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id).isEmpty)
        #expect(await changes.retry(key) == false)
    }

    @Test func aChangeDismissedAndSentAgainIsntSettledByTheFirstsFailure() async {
        let changes = SentChanges()
        let key = SentChanges.Key.boost("m002", "🎉")
        let first = Gate(), second = Gate()
        let sending = Task { await changes.send(key) { try await first.wait() } }
        #expect(await eventually { first.isWaiting })
        changes.dismiss(key)
        let again = Task { await changes.send(key) { try await second.wait() } }
        #expect(await eventually { second.isWaiting })
        first.open(succeeding: false)
        #expect(await sending.value == false)
        #expect(changes.isSending(key))
        second.open(succeeding: true)
        #expect(await again.value)
        #expect(changes.states.isEmpty)
    }

    @Test func aChangeDismissedAndSentAgainIsntSettledByTheFirstsSuccess() async {
        let changes = SentChanges()
        let key = SentChanges.Key.boost("m002", "🎉")
        let first = Gate(), second = Gate()
        let sending = Task { await changes.send(key) { try await first.wait() } }
        #expect(await eventually { first.isWaiting })
        changes.dismiss(key)
        let again = Task { await changes.send(key) { try await second.wait() } }
        #expect(await eventually { second.isWaiting })
        first.open(succeeding: true)
        #expect(await sending.value)
        #expect(changes.isSending(key))
        second.open(succeeding: false)
        #expect(await again.value == false)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id) == [key])
    }

    @Test func aDeletionThatFailsButTheRoomShowsMadeIsntKept() async {
        let changes = SentChanges()
        let key = SentChanges.Key.delete("m002")
        var shown = false
        #expect(await changes.send(key, isDone: { shown }) {
            shown = true
            throw Failure()
        })
        #expect(changes.states.isEmpty)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id).isEmpty)
    }

    @Test func aRetryOfARemovalTheRoomShowsMadeMeanwhileCountsAsDone() async {
        let changes = SentChanges()
        let key = SentChanges.Key.removeBoost("m002", "b1")
        var shown = false, sends = 0
        #expect(await changes.send(key, isDone: { shown }) {
            sends += 1
            throw Failure()
        } == false)
        #expect(changes.hasFailed(key))
        shown = true
        #expect(await changes.retry(key))
        #expect(sends == 1)
        #expect(changes.states.isEmpty)
        #expect(changes.failures(of: asShown("m002"), me: Fixtures.ada.id).isEmpty)
    }

    @Test func aRetryOfARemovalTheRoomStillShowsIsSentAgain() async {
        let changes = SentChanges()
        let key = SentChanges.Key.removeBoost("m002", "b1")
        var sends = 0
        #expect(await changes.send(key, isDone: { false }) { sends += 1; throw Failure() } == false)
        #expect(await changes.retry(key) == false)
        #expect(sends == 2)
        #expect(changes.hasFailed(key))
    }

    @Test func aRowTellsADeletionOrRemovalMadeFromTheMessageAsShown() {
        var message = Fixtures.message("m002", "Hi")
        var shown: Message? = message
        let actions = MessageActions(edit: { _ in }, customBoost: { _ in }, selectText: { _ in }, message: { $0 == "m002" ? shown : nil })
        #expect(!actions.showsDeleted("m002"))
        #expect(actions.showsRemoved(boost: "b1", from: "m002"))
        #expect(!actions.showsRemoved(boost: "b1", from: "m404"))
        #expect(!actions.showsDeleted("m404"))
        message.deleted = true
        shown = message
        #expect(actions.showsDeleted("m002"))
    }

    @Test func aMessageShowingNoFailuresIsToldOfItsFirst() async {
        let changes = SentChanges()
        let changed = Switch(false)
        withObservationTracking {
            _ = changes.failures(of: asShown("m002"), me: Fixtures.ada.id)
        } onChange: {
            changed.set(true)
        }
        #expect(await changes.send(.boost("m002", "🎉")) { throw Failure() } == false)
        #expect(changed.isOn)
    }

    @Test func aFailedBoostTheRoomComesToShowGoesByItself() async {
        let changes = SentChanges()
        let key = SentChanges.Key.boost("m002", "🎉")
        #expect(await changes.send(key) { throw Failure() } == false)
        var message = asShown("m002")
        #expect(changes.failures(of: message, me: Fixtures.ada.id) == [key])

        message.boosts = [Boost(id: "b1", messageId: "m002", booster: Fixtures.grace, content: "🎉", createdAt: .now)]
        #expect(changes.failures(of: message, me: Fixtures.ada.id) == [key])
        changes.settle(message, me: Fixtures.ada.id)
        #expect(changes.hasFailed(key))

        message.boosts.append(Boost(id: "b2", messageId: "m002", booster: Fixtures.ada, content: "🎉", createdAt: .now))
        #expect(changes.failures(of: message, me: Fixtures.ada.id).isEmpty)
        changes.settle(message, me: Fixtures.ada.id)
        #expect(changes.states.isEmpty)
    }

    @Test func aFailedRemovalOrDeletionTheRoomComesToShowGoesByItself() async {
        let changes = SentChanges()
        let removal = SentChanges.Key.removeBoost("m002", "b2")
        let deletion = SentChanges.Key.delete("m002")
        let boost = SentChanges.Key.boost("m002", "👍")
        for key in [removal, deletion, boost] {
            #expect(await changes.send(key) { throw Failure() } == false)
        }
        var message = asShown("m002")
        message.boosts = [Boost(id: "b2", messageId: "m002", booster: Fixtures.ada, content: "🎉", createdAt: .now)]
        #expect(changes.failures(of: message, me: Fixtures.ada.id) == [removal, deletion, boost])

        message.boosts = []
        #expect(changes.failures(of: message, me: Fixtures.ada.id) == [deletion, boost])
        changes.settle(message, me: Fixtures.ada.id)
        #expect(!changes.hasFailed(removal))

        message.deleted = true
        changes.settle(message, me: Fixtures.ada.id)
        #expect(!changes.hasFailed(deletion))
        #expect(changes.hasFailed(boost))
        changes.settle(asShown("m003"), me: Fixtures.ada.id)
        #expect(changes.hasFailed(boost))
    }

    @Test func eachFailureSaysWhatDidntHappen() {
        #expect(SentChanges.failureText(.edit) == "Couldn’t save.")
        #expect(SentChanges.failureText(.delete) == "Couldn’t delete.")
        #expect(SentChanges.failureText(.boost("🎉")) == "Couldn’t react.")
        #expect(SentChanges.failureText(.removeBoost("b1")) == "Couldn’t remove reaction.")
    }

    // MARK: Not sent

    @Test func aRoomOnTheAppsClientKeepsWhatsUnsentInAFile() {
        let session = RoomSession(client: EmberClient(origin: URL(string: "https://chat.example.com")!), roomID: Fixtures.general.id)
        #expect(session.unsentStore === FileUnsentMessageStore.shared)
    }

    @Test func aMessageNotSentShowsFailedAndRetryAndDiscardGoToTheRoom() async throws {
        let session = session()
        let socket = try await opened(session)
        session.sendTimeout = .seconds(5)
        let before = clock.sleeperCount
        let id = try session.send(text: "Hello")
        #expect(await eventually { clock.sleeperCount > before })
        clock.advance(by: .seconds(5))
        let failure = try #require(await eventually { session.timeline.pending.first?.failure != nil } ? session.timeline.pending.first?.failure : nil)
        #expect(PendingRow.failureText(failure) == "Not sent")

        // Retry asks the room first, and sends only once it says it doesn't have the message.
        let checks = sent(socket, "message.check").count
        session.retry(id)
        #expect(session.timeline.pending.first?.failure == nil)
        #expect(await eventually { sent(socket, "message.check").count == checks + 1 })
        #expect(sent(socket, "message.create").count == 1)
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { sent(socket, "message.create").count == 2 })
        await Task.yield()
        #expect(sent(socket, "message.create").count == 2)
        session.discard(id)
        #expect(session.timeline.pending.isEmpty)
    }

    @Test func aMessageTheRoomRefusedSaysWhy() {
        #expect(PendingRow.failureText("That’s too long.") == "That’s too long.")
        #expect(PendingRow.failureText(Uploads.failed) == Uploads.failed)
    }

    @Test func aMessageStillUnsentWhenItsLimitRunsOutInAnOutageFails() async throws {
        let session = session()
        let first = try await opened(session)
        session.sendTimeout = .seconds(5)
        let id = try session.send(text: "Hello")
        connector.onConnect { $0.serverCloses(code: 1006) }
        first.serverCloses(code: 1006)
        #expect(await eventually { session.phase == .reconnecting })
        for _ in 0 ..< 4 {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.timeline.pending.count == 1)
        #expect(session.timeline.pending.first?.failure == nil)
        for _ in 0 ..< 4 {
            clock.advance(by: .seconds(5))
            try? await Task.sleep(for: .milliseconds(20))
        }
        let failure = try #require(session.timeline.pending.first?.failure)
        #expect(PendingRow.failureText(failure) == "Not sent")

        // Back in the room, Retry asks it first and sends the one copy it doesn't have.
        connector.welcomeEverySocket()
        for _ in 0 ..< 10 where session.phase != .admitted {
            clock.advance(by: .seconds(30))
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(await eventually { session.phase == .admitted })
        let socket = try #require(connector.latest)
        session.retry(id)
        #expect(session.timeline.pending.first?.failure == nil)
        #expect(await eventually { sent(socket, "message.check").count == 1 })
        socket.serverSends(Fixtures.RoomFrames.messageChecked(stored: [], missing: [id]))
        #expect(await eventually { sent(socket, "message.create").count == 1 })
        await Task.yield()
        #expect(sent(socket, "message.create").count == 1)
        #expect(session.timeline.pending.count == 1)
    }

    // MARK: A room that can't be shown

    @Test func aRoomStoppedForGoodShowsWhyAndOneStillTryingShowsItsTimeline() {
        #expect(RoomUnavailable(.stopped(.notFound)) == .notFound)
        #expect(RoomUnavailable(.stopped(.refused(status: 403))) == .refused)
        #expect(RoomUnavailable(.connecting) == nil)
        #expect(RoomUnavailable(.open) == nil)
        #expect(RoomUnavailable(.idle) == nil)
    }

    @Test func aRefusedRoomConnectsAgainOnAFreshLease() async throws {
        connector.autoOpen = false
        let timing = EmberTiming(clock: clock, random: { 0.5 })
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: MemoryUnsentMessageStore())
        var lease = session.open()
        #expect(await eventually { connector.connections.count == 1 })
        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { RoomUnavailable(session.status) == .refused })

        connector.autoOpen = true
        connector.welcomeEverySocket()
        lease.close()
        lease = session.open()
        #expect(await eventually { session.phase == .admitted })
        #expect(RoomUnavailable(session.status) == nil)
        lease.close()
    }

    // MARK: Couldn't open

    @Test func retryOnARefusedRoomConnectsAgainAndKeepsTheScreensLease() async throws {
        let session = session()
        connector.onConnect { $0.serverCloses(httpStatus: 403) }
        let screen = session.open()
        let thread = session.open()
        #expect(await eventually { RoomUnavailable(session.status) == .refused })
        let count = connector.connections.count
        connector.welcomeEverySocket()
        let kept = RoomUnavailable.retry(session, keeping: screen)
        #expect(kept === screen)
        #expect(!screen.isClosed)
        #expect(await eventually { session.phase == .admitted })
        #expect(connector.connections.count == count + 1)
        thread.close()
        screen.close()
    }

    @Test func retryOnARefusedThreadConnectsItsRoomAgainAndKeepsTheScreensLease() async throws {
        let session = session()
        connector.onConnect { $0.serverCloses(httpStatus: 403) }
        let room = session.open()
        let thread = session.thread("m001")
        let screen = thread.open()
        #expect(await eventually { RoomUnavailable(session.status) == .refused })
        connector.welcomeEverySocket()
        let kept = RoomUnavailable.retry(thread, keeping: screen)
        #expect(kept === screen)
        #expect(!screen.isClosed)
        #expect(await eventually { session.phase == .admitted })
        screen.close()
        room.close()
    }

    // MARK: The bar

    @Test func theBarShowsOfflineWhileTheDeviceIsAndReconnectingOnceLoaded() {
        #expect(RoomConnection(isOnline: false, isLoaded: true, status: .open) == .offline)
        #expect(RoomConnection(isOnline: false, isLoaded: false, status: .connecting) == .offline)
        #expect(RoomConnection(isOnline: true, isLoaded: true, status: .connecting) == .reconnecting)
        #expect(RoomConnection(isOnline: true, isLoaded: false, status: .connecting) == nil)
        #expect(RoomConnection(isOnline: true, isLoaded: true, status: .open) == nil)
    }

    // MARK: Folding

    @Test func aMessageFoldedWithItsTopAboveWhatsInViewIsBroughtUpFirst() {
        let folds = MessageFolds()
        folds.toggle("p")
        #expect(folds.isOpen("p"))
        folds.setTop(-900, for: "p", in: .room)
        folds.toggle("p")
        #expect(folds.raising == .init(messageID: "p", place: .room))
        #expect(folds.isOpen("p"))
        #expect(folds.lastToggle?.serial == 1)
        folds.raised(.init(messageID: "p", place: .room))
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("p"))
        #expect(folds.lastToggle == .init(messageID: "p", isOpen: false, serial: 2, place: .room))
    }

    @Test func aMessageBeingBroughtUpIsFoldedOnceHoweverOftenItsAskedFor() {
        let folds = MessageFolds()
        folds.toggle("p")
        folds.setTop(-900, for: "p", in: .room)
        folds.toggle("p")
        folds.toggle("p")
        let raise = MessageFolds.Raise(messageID: "p", place: .room)
        folds.raised(raise)
        folds.raised(raise)
        #expect(!folds.isOpen("p"))
        #expect(folds.lastToggle?.serial == 2)
    }

    @Test func aMessageFoldedWithItsTopOnScreenOrUnmeasuredFoldsAtOnce() {
        let folds = MessageFolds()
        folds.toggle("p")
        folds.setTop(120, for: "p", in: .room)
        folds.toggle("p")
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("p"))
        folds.toggle("q")
        folds.toggle("q")
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("q"))
    }

    @Test func aMessageOpenedIsNeverBroughtUpFirst() {
        let folds = MessageFolds()
        folds.setTop(-900, for: "p", in: .room)
        folds.toggle("p")
        #expect(folds.raising == nil)
        #expect(folds.isOpen("p"))
    }

    @Test func whereAMessagesTopIsIsReadInTheTimelineItWasTappedIn() {
        let folds = MessageFolds()
        folds.toggle("p")
        folds.toggle("p", in: .threadParent)
        folds.setTop(-900, for: "p", in: .room)
        folds.setTop(40, for: "p", in: .threadParent)
        folds.toggle("p", in: .threadParent)
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("p", in: .threadParent))
        folds.setTop(nil, for: "p", in: .room)
        folds.toggle("p")
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("p"))
        folds.toggle("p", in: .threadReply)
        folds.setTop(-300, for: "p", in: .threadReply)
        folds.toggle("p", in: .threadReply)
        #expect(folds.raising == .init(messageID: "p", place: .threadReply))
        #expect(folds.isOpen("p", in: .threadReply))
    }

    @Test func aMessageOpenedInAThreadStaysAsItWasInTheRoom() {
        let folds = MessageFolds()
        folds.toggle("p", in: .threadParent)
        #expect(folds.isOpen("p", in: .threadParent))
        #expect(folds.isOpen("p", in: .threadReply))
        #expect(!folds.isOpen("p"))
        folds.toggle("p")
        folds.toggle("p", in: .threadParent)
        #expect(folds.isOpen("p"))
        #expect(!folds.isOpen("p", in: .threadParent))
        folds.removeAll()
        #expect(!folds.isOpen("p"))
    }

    @Test func signingOutForgetsWhereTheMessagesWereAndWhatWasBeingBroughtUp() {
        let folds = MessageFolds()
        folds.toggle("p")
        folds.setTop(-900, for: "p", in: .room)
        folds.toggle("p")
        folds.removeAll()
        #expect(folds.raising == nil)
        folds.toggle("p")
        folds.toggle("p")
        #expect(folds.raising == nil)
        #expect(!folds.isOpen("p"))
    }

    @Test func aMessageThatCouldntBeBroughtUpCanBeFoldedAgain() {
        let folds = MessageFolds()
        folds.toggle("p")
        folds.setTop(-900, for: "p", in: .room)
        folds.toggle("p")
        let raise = MessageFolds.Raise(messageID: "p", place: .room)
        #expect(folds.raising == raise)
        // The timeline no longer has the message, so it can't bring it up.
        folds.dropped(raise)
        #expect(folds.raising == nil)
        #expect(folds.isOpen("p"))
        folds.setTop(120, for: "p", in: .room)
        folds.toggle("p")
        #expect(!folds.isOpen("p"))
        // A stale one leaves a newer raise alone.
        folds.toggle("q")
        folds.setTop(-900, for: "q", in: .room)
        folds.toggle("q")
        folds.dropped(raise)
        #expect(folds.raising == .init(messageID: "q", place: .room))
    }

    @Test func aFoldInAThreadIsntTheRooms() {
        let inRoom = MessageFolds.Toggle(messageID: "p", isOpen: true, serial: 1)
        let atParent = MessageFolds.Toggle(messageID: "p", isOpen: true, serial: 2, place: .threadParent)
        let atReply = MessageFolds.Toggle(messageID: "r", isOpen: true, serial: 3, place: .threadReply)
        #expect(TimelineScroll.isFold(inRoom, inThread: false))
        #expect(!TimelineScroll.isFold(inRoom, inThread: true))
        #expect(!TimelineScroll.isFold(atParent, inThread: false))
        #expect(TimelineScroll.isFold(atParent, inThread: true))
        #expect(!TimelineScroll.isFold(atReply, inThread: false))
        #expect(TimelineScroll.isFold(atReply, inThread: true))
    }

    @Test func aFoldTappedInAThreadIsSentFromThere() {
        let folds = MessageFolds()
        folds.toggle("p", in: .threadParent)
        #expect(folds.lastToggle?.place == .threadParent)
        folds.toggle("p")
        #expect(folds.lastToggle?.place == .room)
    }

    @Test func aFoldIsHeldUntilTheTimelineLetsGoOfIt() {
        let toggle = MessageFolds.Toggle(messageID: "m5", isOpen: true, serial: 4)
        #expect(TimelineScroll.holdsFold(toggle, isHere: true, settled: 3))
        #expect(TimelineScroll.holdsFold(toggle, isHere: true, settled: nil))
        #expect(!TimelineScroll.holdsFold(toggle, isHere: true, settled: 4))
        #expect(!TimelineScroll.holdsFold(toggle, isHere: false, settled: 3))
        #expect(!TimelineScroll.holdsFold(nil, isHere: true, settled: nil))
    }

    @Test func aFoldWaitsForItsMessageToBeBroughtUpOnlyWithItsTopAboveWhatsInView() {
        #expect(MessageFold.raisesFirst(top: -40))
        #expect(MessageFold.raisesFirst(top: -0.6))
        #expect(!MessageFold.raisesFirst(top: -0.4))
        #expect(!MessageFold.raisesFirst(top: 0))
        #expect(!MessageFold.raisesFirst(top: 300))
        #expect(!MessageFold.raisesFirst(top: nil))
    }

    // MARK: Plain text

    @Test func plainTextGoesEscapedAndComesBackAsTyped() async throws {
        let session = session()
        let socket = try await opened(session)
        let typed = "a < b & c\nnext line"
        try RoomComposer.send(Draft(text: typed), room: session, thread: nil, delivery: .threadOnly)
        #expect(await eventually { created(socket).count == 1 })
        let body = try #require(created(socket).first)
        #expect(body == RichText.body(fromPlainText: typed))
        #expect(!body.contains("< b"))
        #expect(session.timeline.pending.first?.plainText == typed)
        #expect(shown(body) == typed)
        #expect(EditableBody(body: body).text == typed)
    }

    @Test func aReplyInPlainTextGoesEscapedAndComesBackAsTyped() async throws {
        let session = session()
        let socket = try await opened(session)
        let thread = session.thread("m001")
        let typed = "a < b & c\r\nnext line\n\n"
        try RoomComposer.send(Draft(text: typed), room: session, thread: thread, delivery: .threadOnly)
        #expect(await eventually { created(socket).count == 1 })
        let body = try #require(created(socket).first)
        #expect(shown(body) == "a < b & c\nnext line")
        #expect(EditableBody(body: body).text == "a < b & c\nnext line")
    }

    @Test func aBlankDraftSendsNothing() async throws {
        let session = session()
        _ = try await opened(session)
        #expect(try RoomComposer.send(Draft(text: "  \n\t \r\n "), room: session, thread: nil, delivery: .threadOnly).isEmpty)
        #expect(session.timeline.pending.isEmpty)
        #expect(RoomComposer.outgoing(Draft(text: "")) == nil)
    }

    @Test func aDraftsPlainTextIsTheRoomsWithLineEndingsMadeOne() {
        #expect(RoomComposer.plainText("\n  hello \n\nthere  \n\n") == "\n  hello \n\nthere  ")
        #expect(RoomComposer.plainText("a\r\nb\rc\r\n") == "a\nb\nc")
        #expect(RoomComposer.plainText("  \n\t \r\n ") == nil)
        #expect(RoomComposer.outgoing(Draft(text: "a < b")) == .text("a < b"))
    }

    // MARK: Mentions

    @Test func peopleInTheRoomAreSuggestedBeforeEveryoneElse() {
        let people = [
            DirectoryUser(id: "u-ann", name: "Ann", status: .active, avatarUrl: ""),
            DirectoryUser(id: "u-anna", name: "anna", status: .active, avatarUrl: ""),
            DirectoryUser(id: "u-joanne", name: "Joanne Anders", status: .active, avatarUrl: ""),
        ]
        #expect(MentionQuery.candidates(people, matching: "an", first: ["u-joanne"]).map(\.name) == ["Joanne Anders", "Ann", "anna"])
        #expect(MentionQuery.candidates(people, matching: "an").map(\.name) == ["Ann", "anna", "Joanne Anders"])
    }

    @Test func theRoomsPeopleAreThoseWhoWroteWhatsLoadedAndWhoHaveItOpen() async throws {
        let session = session()
        _ = try await opened(session)
        let people = RoomComposer.roomPeople(room: session, thread: nil, in: Workspace.mock())
        #expect(people.isSuperset(of: Set(session.timeline.messages.map(\.creator.id))))
        #expect(!people.isEmpty)
    }
}

private struct Failure: Error {}

/// A change held on its way until the test lets it succeed or fail.
@MainActor private final class Gate {
    private var continuation: CheckedContinuation<Bool, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async throws {
        let succeeds = await withCheckedContinuation { continuation = $0 }
        if !succeeds { throw Failure() }
    }

    func open(succeeding: Bool) {
        continuation?.resume(returning: succeeding)
        continuation = nil
    }
}
