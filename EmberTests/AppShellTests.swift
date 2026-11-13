import Foundation
import SwiftUI
import Synchronization
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// The signed-in shell around the rooms: what Home shows when the sidebar fails, where a relaunch
/// opens, which links stay in the app, the way to a forgotten password, and the room list's rows at
/// the largest text sizes.
@MainActor
@Suite struct AppShellTests {

    // MARK: A sidebar that doesn't load

    @Test func aFirstSidebarThatFailsShowsAFailureRatherThanASpinner() async {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport)
        let failing = Switch(true)
        transport.stub("GET", "/api/sidebar") { _ in
            if failing.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Fixtures.sidebarJSON())
        }
        #expect(SidebarPhase(workspace) == .loading)

        await workspace.reload()
        #expect(SidebarPhase(workspace) == .failed)

        failing.set(false)
        await workspace.reload()
        #expect(SidebarPhase(workspace) == .loaded)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedSidebarIsAskedForAgainAfterAWaitUntilItLoads() async {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport)
        let failing = Switch(true)
        transport.stub("GET", "/api/sidebar") { _ in
            if failing.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Fixtures.sidebarJSON())
        }
        await workspace.reload()
        #expect(SidebarPhase(workspace) == .failed)

        let clock = ManualClock()
        let network = NetworkStatus(source: MockNetworkPath())
        let trying = Task { await SidebarPhase.keepTrying(workspace, clock: clock, network: network) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await eventually { transport.requests("GET", "/api/sidebar").count == 2 })
        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(SidebarPhase(workspace) == .failed)

        // The second wait is twice the first.
        failing.set(false)
        clock.advance(by: .seconds(2))
        #expect(transport.requests("GET", "/api/sidebar").count == 2)
        clock.advance(by: .seconds(2))
        #expect(await eventually { SidebarPhase(workspace) == .loaded })
        #expect(await eventually { clock.sleeperCount == 0 })
        trying.cancel()
        await trying.value
        #expect(transport.requests("GET", "/api/sidebar").count == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedSidebarIsAskedForAgainAsSoonAsTheNetworkComesBack() async {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport)
        let failing = Switch(true)
        transport.stub("GET", "/api/sidebar") { _ in
            if failing.isOn { throw URLError(.notConnectedToInternet) }
            return (200, Fixtures.sidebarJSON())
        }
        let path = MockNetworkPath()
        let network = NetworkStatus(source: path)
        path.set(available: false)
        #expect(await eventually { !network.isOnline })
        await workspace.reload()

        let clock = ManualClock()
        let trying = Task { await SidebarPhase.keepTrying(workspace, clock: clock, network: network) }
        #expect(await eventually { clock.sleeperCount == 1 })
        failing.set(false)
        path.set(available: true)
        #expect(await eventually { SidebarPhase(workspace) == .loaded })
        #expect(network.isOnline)
        trying.cancel()
        await trying.value
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedConnectionKeepsTheLoadedListAndShowsTheIndicator() async {
        let transport = MockHTTPTransport()
        let connector = MockSocketConnector(autoOpen: false)
        let workspace = Workspace.mock(transport: transport, connector: connector)
        let network = NetworkStatus(source: MockNetworkPath())
        workspace.start()
        #expect(await eventually { workspace.isLoaded && connector.connections.count == 1 })
        #expect(ConnectionIndicator.isShown(workspace: workspace, network: network))

        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { workspace.connection == .stopped(.refused(status: 403)) })
        #expect(SidebarPhase(workspace) == .loaded)
        #expect(ConnectionIndicator.isShown(workspace: workspace, network: network))

        connector.autoOpen = true
        await SidebarPhase.retry(workspace)
        #expect(await eventually { workspace.connection == .open })
        #expect(connector.connections.count == 2)
        #expect(SidebarPhase(workspace) == .loaded)
        #expect(!ConnectionIndicator.isShown(workspace: workspace, network: network))
        workspace.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedConnectionIsStartedAgainAfterWaitsThatDoubleUntilItOpens() async {
        let transport = MockHTTPTransport()
        let connector = MockSocketConnector(autoOpen: false)
        let workspace = Workspace.mock(transport: transport, connector: connector)
        let clock = ManualClock()
        let network = NetworkStatus(source: MockNetworkPath())
        workspace.start()
        #expect(await eventually { workspace.isLoaded && connector.connections.count == 1 })
        let trying = Task { await SidebarPhase.keepTrying(workspace, clock: clock, network: network) }

        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await eventually { connector.connections.count == 2 })

        // Refused again: the second wait is twice the first.
        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(connector.connections.count == 2)
        clock.advance(by: .seconds(2))
        #expect(await eventually { connector.connections.count == 3 })
        connector.latest?.open()
        #expect(await eventually { workspace.connection == .open })
        #expect(SidebarPhase(workspace) == .loaded)

        // Open again, so the next refusal waits the shortest time.
        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(2))
        #expect(await eventually { connector.connections.count == 4 })

        trying.cancel()
        await trying.value
        workspace.shutdown()
    }

    @Test func aRefusedConnectionBeforeAnythingHasLoadedShowsAsFailed() async {
        let transport = MockHTTPTransport()
        let connector = MockSocketConnector(autoOpen: false)
        let workspace = Workspace.mock(transport: transport, connector: connector)
        let network = NetworkStatus(source: MockNetworkPath())
        transport.stub("GET", "/api/sidebar") { _ in throw URLError(.notConnectedToInternet) }
        workspace.start()
        #expect(await eventually { workspace.loadError != nil && connector.connections.count == 1 })
        connector.latest?.serverCloses(httpStatus: 403)
        #expect(await eventually { SidebarPhase.isRefused(workspace) })
        #expect(SidebarPhase(workspace) == .failed)
        #expect(!ConnectionIndicator.isShown(workspace: workspace, network: network))
        workspace.shutdown()
    }

    @Test func theWaitBetweenTriesDoublesUpToAMinute() {
        #expect(Retrying.delay(attempt: 0) == .seconds(2))
        #expect(Retrying.delay(attempt: 1) == .seconds(4))
        #expect(Retrying.delay(attempt: 4) == .seconds(32))
        #expect(Retrying.delay(attempt: 5) == .seconds(60))
        #expect(Retrying.delay(attempt: 50) == .seconds(60))
    }

    // MARK: Where a relaunch opens

    @Test func aPlaceIsRememberedForEachAccount() {
        let suite = "EmberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = HomePlaces(defaults: defaults)
        let origin = URL(string: "https://ember.test")!
        let ada = HomePlaces.account(origin: origin, userID: "user_ada")
        let grace = HomePlaces.account(origin: origin, userID: "user_grace")
        let elsewhere = HomePlaces.account(origin: URL(string: "https://other.test")!, userID: "user_ada")

        let place = HomePlace(tab: .activity, link: RoomLink(roomID: "room-general", messageID: "m1", threadID: "m0"))
        places.remember(place, for: ada)

        #expect(places.place(for: ada) == place)
        #expect(places.place(for: grace) == nil)
        #expect(places.place(for: elsewhere) == nil)
    }

    @Test func forgettingAServerForgetsEveryPlaceOnItAndNoOtherServers() {
        let suite = "EmberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = HomePlaces(defaults: defaults)
        let origin = URL(string: "https://ember.test")!
        let ada = HomePlaces.account(origin: origin, userID: "user_ada")
        let grace = HomePlaces.account(origin: origin, userID: "user_grace")
        let elsewhere = HomePlaces.account(origin: URL(string: "https://ember.testing")!, userID: "user_ada")
        let place = HomePlace(tab: .activity)
        for account in [ada, grace, elsewhere] { places.remember(place, for: account) }

        places.forget(origin: origin)
        #expect(places.place(for: ada) == nil)
        #expect(places.place(for: grace) == nil)
        #expect(places.place(for: elsewhere) == place)
    }

    @Test func signingOneAccountOutForgetsOnlyItsPlace() {
        let suite = "EmberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = HomePlaces(defaults: defaults)
        let origin = URL(string: "https://ember.test")!
        let ada = HomePlaces.account(origin: origin, userID: "user_ada")
        let grace = HomePlaces.account(origin: origin, userID: "user_grace")
        let elsewhere = HomePlaces.account(origin: URL(string: "https://ember.testing")!, userID: "user_ada")
        let place = HomePlace(tab: .search)
        for account in [ada, grace, elsewhere] { places.remember(place, for: account) }

        places.forget(origin: origin, userID: "user_ada")
        #expect(places.place(for: ada) == nil)
        #expect(places.place(for: grace) == place)
        #expect(places.place(for: elsewhere) == place)
    }

    @Test func aPlaceOnATabThatsGoneReadsAsNoPlace() {
        let suite = "EmberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = HomePlaces(defaults: defaults)
        let ada = HomePlaces.account(origin: URL(string: "https://ember.test")!, userID: "user_ada")
        // As kept while New Message was a tab.
        defaults.set(Data(#"{"tab":"compose"}"#.utf8), forKey: "homePlace.\(ada)")

        #expect(places.place(for: ada) == nil)
    }

    @Test func aPlaceIsKeptUnderItsAccountsKeyAsTheTabRoomAndThread() throws {
        let suite = "EmberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let places = HomePlaces(defaults: defaults)
        let ada = HomePlaces.account(origin: URL(string: "https://ember.test")!, userID: "user_ada")
        #expect(ada == "https://ember.test#user_ada")

        places.remember(HomePlace(tab: .home, link: RoomLink(roomID: "room-general", threadID: "m0")), for: ada)
        let data = try #require(defaults.data(forKey: "homePlace.https://ember.test#user_ada"))
        #expect(try JSONSerialization.jsonObject(with: data) as? NSDictionary == ["tab": "home", "roomID": "room-general", "threadID": "m0"] as NSDictionary)

        defaults.set(Data(#"{"tab":"search","roomID":"room-dev","threadID":"m9"}"#.utf8), forKey: "homePlace.https://ember.test#user_ada")
        #expect(places.place(for: ada) == HomePlace(tab: .search, link: RoomLink(roomID: "room-dev", threadID: "m9")))

        places.forget(origin: URL(string: "https://ember.test")!)
        #expect(defaults.data(forKey: "homePlace.https://ember.test#user_ada") == nil)
    }

    @Test func aRememberedThreadReopensOverItsRoomWithoutTheMessage() {
        let thread = HomePlace(tab: .home, link: RoomLink(roomID: "room-general", messageID: "m1", threadID: "m0"))
        #expect(thread.path == [RoomLink(roomID: "room-general"), RoomLink(roomID: "room-general", threadID: "m0")])
        #expect(thread.link == RoomLink(roomID: "room-general", threadID: "m0"))

        let room = HomePlace(tab: .home, link: RoomLink(roomID: "room-general", messageID: "m1"))
        #expect(room.path == [RoomLink(roomID: "room-general")])
        #expect(HomePlace(tab: .search).path.isEmpty)
    }

    @Test func aRoomYouAreNoLongerInFallsBackToItsTab() {
        let place = HomePlace(tab: .activity, link: RoomLink(roomID: "room-gone"))
        #expect(place.checked { $0 == "room-general" } == HomePlace(tab: .activity))
        let kept = HomePlace(tab: .activity, link: RoomLink(roomID: "room-general"))
        #expect(kept.checked { $0 == "room-general" } == kept)
    }

    // MARK: Links to the same server

    private let origin = URL(string: "https://chat.example.com")!

    private func link(_ text: String) -> RoomLink? {
        RoomLink(url: URL(string: text)!, on: origin)
    }

    @Test func linksToRoomsMessagesAndThreadsOnTheServerOpenInTheApp() {
        #expect(link("https://chat.example.com/rooms/room-1") == RoomLink(roomID: "room-1"))
        #expect(link("https://CHAT.example.com:443/rooms/room-1") == RoomLink(roomID: "room-1"))
        #expect(link("/rooms/room-1") == RoomLink(roomID: "room-1"))
        #expect(link("https://chat.example.com/rooms/opens/room-1") == RoomLink(roomID: "room-1"))
        #expect(link("https://chat.example.com/rooms/directs/room-dm") == RoomLink(roomID: "room-dm"))
        #expect(link("https://chat.example.com/rooms/room-1/@msg-9") == RoomLink(roomID: "room-1", messageID: "msg-9"))
        #expect(link("https://chat.example.com/rooms/room-1/messages/msg-9") == RoomLink(roomID: "room-1", messageID: "msg-9"))
        #expect(link("https://chat.example.com/rooms/room-1/threads/msg-2") == RoomLink(roomID: "room-1", threadID: "msg-2"))
        #expect(link("https://chat.example.com/rooms/room-1/threads/msg-2/@msg-7")
            == RoomLink(roomID: "room-1", messageID: "msg-7", threadID: "msg-2"))
        #expect(link("https://chat.example.com/rooms/room%201?x=1#top") == RoomLink(roomID: "room 1"))
    }

    @Test func otherPagesAndOtherServersAreLeftToTheSystem() {
        #expect(link("https://elsewhere.example.com/rooms/room-1") == nil)
        #expect(link("http://chat.example.com/rooms/room-1") == nil)
        #expect(link("https://chat.example.com:8443/rooms/room-1") == nil)
        #expect(link("https://chat.example.com/") == nil)
        #expect(link("https://chat.example.com/rooms") == nil)
        #expect(link("https://chat.example.com/rooms/new") == nil)
        #expect(link("https://chat.example.com/rooms/directs/new") == nil)
        #expect(link("https://chat.example.com/rooms/opens/room-1/edit") == nil)
        #expect(link("https://chat.example.com/users/me/profile") == nil)
        #expect(link("https://chat.example.com/rooms/room-1/files/a.png") == nil)
        #expect(link("mailto:ada@example.com") == nil)
    }

    @Test func aMalformedMessageInALinkOpensTheRoom() {
        let long = String(repeating: "x", count: 65)
        #expect(link("https://chat.example.com/rooms/room-1/@\(long)") == RoomLink(roomID: "room-1"))
        #expect(link("https://chat.example.com/rooms/room-1/threads/\(long)/@msg-7") == RoomLink(roomID: "room-1"))
    }

    @Test func aLinkToWhatIsAlreadyOnTopStaysPut() {
        let room = RoomLink(roomID: "room-1")
        let thread = RoomLink(roomID: "room-1", threadID: "msg-2")
        #expect(!HomeView.pushes(room, over: room))
        #expect(!HomeView.pushes(RoomLink(roomID: "room-1", messageID: "msg-9"), over: room))
        #expect(!HomeView.pushes(RoomLink(roomID: "room-1", messageID: "msg-7", threadID: "msg-2"), over: thread))
        #expect(HomeView.pushes(thread, over: room))
        #expect(HomeView.pushes(RoomLink(roomID: "room-2", messageID: "msg-9"), over: room))
        #expect(HomeView.pushes(room, over: nil))
    }

    // MARK: A forgotten password

    @Test func aServerThatSendsEmailLinksToResettingAPassword() throws {
        let client = EmberClient.mock(origin: URL(string: "https://ember.test")!)
        var bootstrap = try EmberJSON.decoder().decode(Bootstrap.self, from: Data(Fixtures.bootstrapJSON(user: nil).utf8))
        bootstrap.passwordResetCodes = true

        #expect(SignInView.passwordResetURL(client: client, bootstrap: bootstrap, email: "")?.absoluteString
            == "https://ember.test/passwords/new")
        #expect(SignInView.passwordResetURL(client: client, bootstrap: bootstrap, email: " ada+ember@example.com ")?.absoluteString
            == "https://ember.test/passwords/new?email_address=ada%2Bember%40example.com")

        bootstrap.passwordResetCodes = false
        #expect(SignInView.passwordResetURL(client: client, bootstrap: bootstrap, email: "ada@example.com") == nil)
    }

    // MARK: The room list at the largest text size

    /// A row as the list lays it out on a 390-point phone, at `size`.
    private static func drawn(_ row: some View, workspace: Workspace, size: DynamicTypeSize, width: CGFloat = 390) throws -> UIImage {
        let renderer = ImageRenderer(content: row
            .environment(workspace)
            .environment(\.dynamicTypeSize, size))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private static func sharedRoom(_ name: String) -> SidebarRoom {
        SidebarRoom(room: Room(id: "room-\(name)", kind: .open, name: name), unread: true)
    }

    private static func directRoom(with name: String) -> SidebarRoom {
        SidebarRoom(room: Room(
            id: "room-dm-\(name)", kind: .direct, members: [Fixtures.ada, User(id: "user-\(name)", name: name)],
            activeAt: Date(timeIntervalSince1970: 1_790_000_000)), unread: true)
    }

    @Test func roomsWhoseNamesDifferAtTheEndStillLookDifferentAtTheLargestSize() throws {
        let workspace = Workspace.mock()
        for width in [390.0, 320.0] {
            let first = try Self.drawn(SharedRoomRow(room: Self.sharedRoom("oncall-triage-alerts-12")), workspace: workspace, size: .accessibility5, width: width)
            let second = try Self.drawn(SharedRoomRow(room: Self.sharedRoom("oncall-triage-alerts-13")), workspace: workspace, size: .accessibility5, width: width)
            #expect(first.size.width <= width)
            #expect(first.pngData() != second.pngData(), "At \(width) points the two rows draw the same")
        }
    }

    @Test func aLongRoomNameWrapsAtTheLargestSizeAndStaysOnOneLineAtTheDefault() throws {
        let workspace = Workspace.mock()
        let long = SharedRoomRow(room: Self.sharedRoom("oncall-triage-alerts-12"))
        let short = SharedRoomRow(room: Self.sharedRoom("ops"))

        let longLarge = try Self.drawn(long, workspace: workspace, size: .accessibility5)
        let shortLarge = try Self.drawn(short, workspace: workspace, size: .accessibility5)
        #expect(longLarge.size.height > shortLarge.size.height * 1.5)

        let longDefault = try Self.drawn(long, workspace: workspace, size: .large)
        let shortDefault = try Self.drawn(short, workspace: workspace, size: .large)
        #expect(longDefault.size.height == shortDefault.size.height)
    }

    @Test func aDirectMessagesNamesGetTheirOwnLineAtTheLargestSize() throws {
        let workspace = Workspace.mock()
        let first = try Self.drawn(DirectRoomRow(room: Self.directRoom(with: "Bartholomew Cavendish-Smythe")), workspace: workspace, size: .accessibility5)
        let second = try Self.drawn(DirectRoomRow(room: Self.directRoom(with: "Bartholomew Cavendish-Smith")), workspace: workspace, size: .accessibility5)
        #expect(first.size.width <= 390)
        #expect(first.pngData() != second.pngData())

        // The faces, time and dot on one line, and the name beneath, wrapping: taller than the
        // largest body text's line and the face together.
        let short = try Self.drawn(DirectRoomRow(room: Self.directRoom(with: "Al")), workspace: workspace, size: .accessibility5)
        #expect(first.size.height > short.size.height)
    }

    // MARK: A level the app doesn't know

    @Test func aLevelTheAppDoesNotKnowShowsTheServersNameMadeReadable() {
        #expect(Involvement.unknown("mentions_and_threads").title == "Mentions and threads")
        #expect(Involvement.unknown("digest").title == "Digest")
        #expect(Involvement.unknown("").title == "")
    }

    // MARK: The pinned section header

    /// A header with no background let rows scrolling under it show through its title.
    @Test func aSectionHeaderIsOpaqueAcrossItsWidth() throws {
        let renderer = ImageRenderer(content: PinnedSectionHeader("Rooms"))
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        renderer.scale = 1
        let image = try #require(renderer.uiImage)
        #expect(image.size.width == 390)
        let source = try #require(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let transparent = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] < 255 }.count
        #expect(transparent == 0)
    }
}

// MARK: - Stand-ins

/// A switch a stub reads from whichever thread the transport answers on.
final class Switch: Sendable {
    private let value: Mutex<Bool>

    init(_ on: Bool) {
        value = Mutex(on)
    }

    var isOn: Bool { value.withLock { $0 } }

    func set(_ on: Bool) {
        value.withLock { $0 = on }
    }
}

/// Waits, a few milliseconds at a time and for at most two seconds, for `condition` to hold.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
