import Foundation
import Testing
import SwiftUI
import UIKit
import EmberSDK
import EmberTesting
@testable import Ember

/// New Room, Edit Room, Delete Room, Reorder and the welcome card: who's offered them, what their
/// forms send, and what the workspace does with it.
@MainActor @Suite struct RoomManagementTests {
    static let member = Me(id: "user_grace", name: "Grace Hopper", administrator: false)
    static let people = [Fixtures.ada.id, Fixtures.alan.id, Fixtures.grace.id]

    // MARK: Who's offered what

    @Test func newRoomIsOfferedUnlessRestrictedToAdministrators() {
        let open = Account(name: "A")
        let restricted = Account(name: "A", restrictRoomCreation: true)
        #expect(RoomCreation.isOffered(account: open, me: Self.member))
        #expect(RoomCreation.isOffered(account: open, me: Fixtures.me))
        #expect(!RoomCreation.isOffered(account: restricted, me: Self.member))
        #expect(RoomCreation.isOffered(account: restricted, me: Fixtures.me))
    }

    @Test func reorderIsOfferedOnceThereAreTwoToOrder() {
        #expect(!RoomReorder.isOffered(me: Self.member, favoriteCount: 1, sharedCount: 5))
        #expect(RoomReorder.isOffered(me: Self.member, favoriteCount: 2, sharedCount: 5))
        #expect(!RoomReorder.offersShared(me: Self.member, sharedCount: 5))
        #expect(RoomReorder.offersShared(me: Fixtures.me, sharedCount: 2))
        #expect(!RoomReorder.offersShared(me: Fixtures.me, sharedCount: 1))
        #expect(RoomReorder.isOffered(me: Fixtures.me, favoriteCount: 0, sharedCount: 2))
        #expect(!RoomReorder.isOffered(me: Fixtures.me, favoriteCount: 1, sharedCount: 1))
    }

    // MARK: The form

    @Test func aNameIsNeededAndNoLongerThanTheServerTakes() {
        #expect(!RoomDraft(name: "   ").hasValidName)
        #expect(RoomDraft(name: "  Looms ").hasValidName)
        #expect(RoomDraft(name: "  Looms ").trimmedName == "Looms")
        #expect(RoomDraft(name: String(repeating: "a", count: 100)).hasValidName)
        #expect(!RoomDraft(name: String(repeating: "a", count: 101)).hasValidName)
    }

    @Test func aNewOpenRoomSendsNoMembers() {
        let draft = RoomDraft(name: " Looms ", isClosed: false, members: [Fixtures.grace.id])
        #expect(draft.newRoom(people: Self.people) == NewRoom(name: "Looms", access: .open))
    }

    @Test func aNewClosedRoomSendsItsMembersInTheListsOrder() {
        let draft = RoomDraft(name: "Looms", isClosed: true, members: [Fixtures.grace.id, Fixtures.alan.id, "user_gone"])
        #expect(draft.newRoom(people: Self.people) == NewRoom(name: "Looms", access: .closed(memberIDs: [Fixtures.alan.id, Fixtures.grace.id])))
    }

    @Test func settingsFillTheDraft() {
        let settings: RoomSettings = Fixtures.decode(Fixtures.roomSettingsJSON())
        let draft = RoomDraft(settings: settings)
        #expect(draft == RoomDraft(name: "Engines", isClosed: true, members: [Fixtures.ada.id, Fixtures.grace.id]))
        #expect(RoomInfoView.members(settings).map(\.id) == [Fixtures.ada.id, Fixtures.grace.id])

        let open: RoomSettings = Fixtures.decode(Fixtures.roomSettingsJSON(Fixtures.general, members: []))
        #expect(RoomDraft(settings: open) == RoomDraft(name: "General", isClosed: false, members: []))
    }

    @Test func nothingChangedSavesNothing() {
        let saved = RoomDraft(name: "Engines", isClosed: true, members: [Fixtures.ada.id])
        var draft = saved
        draft.name = " Engines "
        #expect(draft.changes(from: saved, people: Self.people) == nil)
    }

    @Test func aRenameSendsOnlyTheName() {
        let saved = RoomDraft(name: "Engines", isClosed: true, members: [Fixtures.ada.id])
        var draft = saved
        draft.name = "Looms "
        #expect(draft.changes(from: saved, people: Self.people) == RoomChanges(name: "Looms"))
    }

    @Test func openingAClosedRoomSendsOpen() {
        let saved = RoomDraft(name: "Engines", isClosed: true, members: [Fixtures.ada.id])
        var draft = saved
        draft.isClosed = false
        #expect(draft.changes(from: saved, people: Self.people) == RoomChanges(access: .open))
    }

    @Test func membersOfAnOpenRoomDontCount() {
        let saved = RoomDraft(name: "General", isClosed: false, members: [])
        var draft = saved
        draft.members = [Fixtures.grace.id]
        #expect(draft.changes(from: saved, people: Self.people) == nil)
    }

    @Test func closingOrChangingMembersSendsWhosIn() {
        let open = RoomDraft(name: "General", isClosed: false, members: [])
        var closed = open
        closed.isClosed = true
        closed.members = [Fixtures.grace.id, Fixtures.ada.id]
        #expect(closed.changes(from: open, people: Self.people) == RoomChanges(access: .closed(memberIDs: [Fixtures.ada.id, Fixtures.grace.id])))

        var fewer = closed
        fewer.members = [Fixtures.ada.id]
        #expect(fewer.changes(from: closed, people: Self.people) == RoomChanges(access: .closed(memberIDs: [Fixtures.ada.id])))
    }

    @Test func closingWithoutYouRemovesYou() {
        let me = Fixtures.ada.id
        #expect(RoomDraft.removes(me, with: RoomChanges(access: .closed(memberIDs: [Fixtures.grace.id]))))
        #expect(!RoomDraft.removes(me, with: RoomChanges(access: .closed(memberIDs: [me, Fixtures.grace.id]))))
        #expect(!RoomDraft.removes(me, with: RoomChanges(access: .open)))
        #expect(!RoomDraft.removes(me, with: RoomChanges(name: "Looms")))
    }

    @Test func searchKeepsMatchingNamesInOrder() {
        let people = [Fixtures.ada, Fixtures.alan, Fixtures.grace]
        #expect(RoomPeople.matching(people, typed: "  ") == people)
        #expect(RoomPeople.matching(people, typed: "a").map(\.id) == people.map(\.id))
        #expect(RoomPeople.matching(people, typed: "TUR").map(\.id) == [Fixtures.alan.id])
        #expect(RoomPeople.matching(people, typed: "hopper ").map(\.id) == [Fixtures.grace.id])
        #expect(RoomPeople.matching(people, typed: "zz").isEmpty)
    }

    // MARK: Through the workspace

    func started(_ transport: MockHTTPTransport) async throws -> Workspace {
        let workspace = Workspace.mock(transport: transport)
        workspace.start()
        try #require(await eventually { workspace.isLoaded })
        return workspace
    }

    @Test func aNewClosedRoomHasYouInIt() async throws {
        let transport = MockHTTPTransport()
        let workspace = try await started(transport)
        let looms = Room(id: "room-looms", kind: .closed, name: "Looms")
        transport.stub("POST", "/api/rooms", status: 201, json: Fixtures.roomJSON(looms))
        let draft = RoomDraft(name: "Looms", isClosed: true, members: [Fixtures.grace.id])
        let room = try await workspace.createRoom(draft.newRoom(people: Self.people))
        #expect(room.id == looms.id)
        #expect(transport.lastBody("POST", "/api/rooms")?["name"] as? String == "Looms")
        #expect((transport.lastBody("POST", "/api/rooms")?["memberIds"] as? [String])?.contains("user_ada") == true)
        #expect(workspace.sharedRooms.contains { $0.id == looms.id })
    }

    @Test func savingAnEditSendsTheChanges() async throws {
        let transport = MockHTTPTransport()
        let workspace = try await started(transport)
        let settings: RoomSettings = Fixtures.decode(Fixtures.roomSettingsJSON())
        var draft = RoomDraft(settings: settings)
        draft.name = "Difference Engines"
        let changes = try #require(draft.changes(from: RoomDraft(settings: settings), people: settings.people.map(\.id)))
        let renamed = Room(id: Fixtures.engines.id, kind: .closed, name: "Difference Engines", icon: "cog")
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(renamed))
        try await workspace.changeRoom(Fixtures.engines.id, changes)
        #expect(transport.lastBody("PATCH", "/api/rooms/room-engines")?["name"] as? String == "Difference Engines")
        #expect(workspace.room(Fixtures.engines.id)?.room.name == "Difference Engines")
    }

    @Test func closingARoomWithoutYouTakesItOffHome() async throws {
        let transport = MockHTTPTransport()
        let workspace = try await started(transport)
        let settings: RoomSettings = Fixtures.decode(Fixtures.roomSettingsJSON())
        var draft = RoomDraft(settings: settings)
        draft.members.remove(Fixtures.ada.id)
        let changes = try #require(draft.changes(from: RoomDraft(settings: settings), people: settings.people.map(\.id)))
        #expect(RoomDraft.removes(workspace.me.id, with: changes))
        transport.stub("PATCH", "/api/rooms/room-engines", json: Fixtures.roomJSON(Fixtures.engines))
        try await workspace.changeRoom(Fixtures.engines.id, changes)
        #expect(!workspace.sharedRooms.contains { $0.id == Fixtures.engines.id })
    }
}
