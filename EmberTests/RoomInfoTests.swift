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
}
