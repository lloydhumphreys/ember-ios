import Testing
import EmberSDK
@testable import Ember

@Suite("Room details")
@MainActor
struct RoomInfoTests {
    @Test func whoElseIsHereLeavesYouOutListsEachOnceAndGoesByName() {
        let me = User(id: "user_me", name: "Maya Chen")
        let leo = User(id: "user_leo", name: "Leo Park")
        let amara = User(id: "user_amara", name: "Amara Okafor")
        let here = RoomInfoView.othersHere([leo, me, amara, leo], me: me.id) { $0.name }
        #expect(here.map(\.id) == [amara.id, leo.id])
    }

    @Test func noOneElseHereIsAnEmptyList() {
        let me = User(id: "user_me", name: "Maya Chen")
        #expect(RoomInfoView.othersHere([me], me: me.id) { $0.name }.isEmpty)
        #expect(RoomInfoView.othersHere([], me: me.id) { $0.name }.isEmpty)
    }

    @Test func onlySomeoneTheDirectoryHasAsBannedIsMarkedBanned() {
        let statuses: [UserID: UserStatus] = [
            "user_leo": .active, "user_amara": .banned, "user_sam": .deactivated, "user_kim": .suspended,
        ]
        let people = Dictionary(uniqueKeysWithValues: statuses.map { id, status in
            (id, DirectoryUser(id: id, name: id.rawValue, status: status, avatarUrl: "/\(id.rawValue)"))
        })
        #expect(RoomInfoView.isBanned("user_amara", people: people))
        #expect(!RoomInfoView.isBanned("user_leo", people: people))
        #expect(!RoomInfoView.isBanned("user_sam", people: people))
        #expect(!RoomInfoView.isBanned("user_kim", people: people))
        // Someone the directory doesn't have yet isn't.
        #expect(!RoomInfoView.isBanned("user_new", people: people))
    }

    // MARK: A room that goes

    @Test func aRoomYouDeleteOrLeaveHereGoesHome() {
        #expect(RoomGone(wasListed: true, isListed: false, status: .open, hasLeft: true) == .left)
        #expect(RoomGone(wasListed: true, isListed: false, status: .stopped(.notFound), hasLeft: true) == .left)
        // Even before the sidebar or the socket has heard.
        #expect(RoomGone(wasListed: true, isListed: true, status: .open, hasLeft: true) == .left)
    }

    @Test func onlyARoomThatWentOtherwiseSaysItWasDeleted() {
        // One you left here was not deleted, and is on its way home.
        #expect(!RoomGone.left.saysDeleted)
        #expect(RoomGone.deleted.saysDeleted)
        #expect(RoomGone.notFound.saysDeleted)
    }

    @Test func aRoomThatWasThereAndWentOtherwiseSaysItWasDeleted() {
        // The workspace's socket hears first, and takes it out of the sidebar.
        #expect(RoomGone(wasListed: true, isListed: false, status: .open, hasLeft: false) == .deleted)
        // Or the room's own socket is closed as not found.
        #expect(RoomGone(wasListed: true, isListed: true, status: .stopped(.notFound), hasLeft: false) == .deleted)
        #expect(RoomGone(wasListed: true, isListed: false, status: .stopped(.notFound), hasLeft: false) == .deleted)
    }

    @Test func aLinkToARoomNeverListedIsNotFound() {
        #expect(RoomGone(wasListed: false, isListed: false, status: .stopped(.notFound), hasLeft: false) == .notFound)
        // Not yet listed, still loading: nothing's gone.
        #expect(RoomGone(wasListed: false, isListed: false, status: .connecting, hasLeft: false) == nil)
    }

    @Test func aRoomStillThereIsntGone() {
        #expect(RoomGone(wasListed: true, isListed: true, status: .open, hasLeft: false) == nil)
        #expect(RoomGone(wasListed: true, isListed: true, status: .connecting, hasLeft: false) == nil)
        #expect(RoomGone(wasListed: true, isListed: true, status: .stopped(.refused(status: 403)), hasLeft: false) == nil)
    }
}
