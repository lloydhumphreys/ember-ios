import Foundation
import Testing
import SwiftUI
import UIKit
import EmberSDK
import EmberTesting
@testable import Ember

/// Search's filters and results, the lists of people the app picks from, and the avatars every
/// list draws. Nothing here touches the network.
@MainActor
@Suite struct SearchAndPeopleTests {
    // MARK: The lists the pickers show

    @Test func twoThousandPeopleAreSortedOnceAndQuickly() {
        let lists = PickerLists()
        let directory = Self.directory(2_011)
        let first = lists.people(directory)
        let again = lists.people(directory)
        #expect(first.count == 2_011)
        #expect(again.map(\.id) == first.map(\.id))
        #expect(lists.peopleBuilds == 1)
    }

    @Test func thePeopleListIsWorkedOutAgainOnlyWhenTheDirectoryChanges() {
        let lists = PickerLists()
        var directory = Self.directory(20)
        _ = lists.people(directory)
        _ = lists.people(directory)
        #expect(lists.peopleBuilds == 1)
        directory["user_new"] = DirectoryUser(id: "user_new", name: "Aaron Aardvark", avatarUrl: "/users/new/avatar")
        #expect(lists.people(directory).first?.id == "user_new")
        #expect(lists.peopleBuilds == 2)
    }

    @Test func deactivatedPeopleComeLastBannedPeopleArentListedAndTheSameNameIsOrderedById() {
        let lists = PickerLists()
        let people = [
            DirectoryUser(id: "user_b", name: "Sam Smith", avatarUrl: "/b"),
            DirectoryUser(id: "user_a", name: "Sam Smith", avatarUrl: "/a"),
            DirectoryUser(id: "user_gone", name: "Aaron Able", status: .deactivated, avatarUrl: "/gone"),
            DirectoryUser(id: "user_away", name: "Abby Away", status: .suspended, avatarUrl: "/away"),
            DirectoryUser(id: "user_banned", name: "Abe Banned", status: .banned, avatarUrl: "/banned"),
            DirectoryUser(id: "user_zoe", name: "zoë Zed", avatarUrl: "/zoe"),
            DirectoryUser(id: "user_amy", name: "Amy Adams", avatarUrl: "/amy"),
        ]
        let sorted = lists.people(Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) }))
        #expect(sorted.map(\.id) == ["user_amy", "user_a", "user_b", "user_zoe", "user_gone", "user_away"])
    }

    @Test func someoneBannedLeavesThePersonFilterAndComesBackOnceLetIn() {
        let lists = PickerLists()
        var directory = Self.directory(3)
        let id: UserID = "user_0"
        #expect(lists.people(directory).contains { $0.id == id })
        directory[id]?.status = .banned
        #expect(!lists.people(directory).contains { $0.id == id })
        #expect(lists.people(directory).count == 2)
        directory[id]?.status = .active
        #expect(lists.people(directory).contains { $0.id == id })
    }

    @Test func newMessageListsEveryoneActiveButYouAndSortsOnce() {
        let lists = PickerLists()
        var directory = Self.directory(2_011)
        directory[Fixtures.me.id] = DirectoryUser(id: Fixtures.me.id, name: Fixtures.me.name, avatarUrl: "/me")
        directory["user_gone"] = DirectoryUser(id: "user_gone", name: "Gone", status: .deactivated, avatarUrl: "/gone")
        let first = lists.direct(directory, me: Fixtures.me.id)
        _ = lists.direct(directory, me: Fixtures.me.id)
        #expect(lists.directBuilds == 1)
        // Every fiftieth of the 2,011 is deactivated.
        #expect(first.count == 2_011 - 40)
        #expect(!first.contains { $0.id == Fixtures.me.id || $0.id == "user_gone" })
        #expect(first.map(\.id) == RoomList.peopleMatching(Array(directory.values), me: Fixtures.me.id, name: "").map(\.id))
    }

    @Test func typingNarrowsAListIgnoringCaseAndAccents() {
        let names = ["Élodie Ünal", "Elliot Page", "Grace Hopper"]
        #expect(PickerLists.matching(names, "elo") { $0 } == ["Élodie Ünal"])
        #expect(PickerLists.matching(names, " EL ") { $0 } == ["Élodie Ünal", "Elliot Page"])
        #expect(PickerLists.matching(names, "") { $0 } == names)
    }

    @Test(.timeLimit(.minutes(1)))
    func showingSearchBuildsNoListOfPeopleOrRooms() async throws {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/users", json: Fixtures.directoryJSON(Array(Self.directory(2_011).values)))
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON())
        let client = Self.client(transport)
        let workspace = Workspace(client: client, me: Fixtures.me, account: Fixtures.account)
        await workspace.reloadDirectory()
        #expect(workspace.people.count == 2_011)

        let peopleBuilds = PickerLists.shared.peopleBuilds
        let roomBuilds = PickerLists.shared.roomBuilds
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { SearchView() }.environment(workspace))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Its task asks for the recent searches once it's on screen, menu and all.
        while transport.requests("GET", "/api/searches").isEmpty {
            window.layoutIfNeeded()
            await Task.yield()
        }
        window.layoutIfNeeded()
        #expect(PickerLists.shared.peopleBuilds == peopleBuilds)
        #expect(PickerLists.shared.roomBuilds == roomBuilds)
    }

    // MARK: Searching

    @Test func emojiOrPunctuationAloneFindsNothingWithoutAskingTheServer() {
        let transport = MockHTTPTransport()
        let model = SearchModel()
        model.attach(Self.client(transport))
        for typed in ["🔥", "?!…", "🙂 🙃"] {
            model.text = typed
            model.run(history: .record)
            #expect(model.phase == .loaded)
            #expect(model.matches.isEmpty)
            #expect(model.shownQuery?.q == typed)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func anEmptyFieldWithNoFiltersGoesBackToRecentSearches() {
        let model = SearchModel()
        model.attach(Self.client(MockHTTPTransport()))
        model.text = "🔥"
        model.run(history: .record)
        model.text = "  "
        model.run(history: .record)
        #expect(model.phase == .idle)
        #expect(model.shownQuery == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func resultsArriveWithTheirWordsAlreadyEmphasised() async throws {
        let transport = MockHTTPTransport()
        let message = Fixtures.message("m1", "The theme of the day")
        // The fixture leaves out the words the server says matched; these are the ones it would send.
        var answer = try #require(try JSONSerialization.jsonObject(
            with: Data(Fixtures.searchJSON(search: SearchQuery("the"), matches: [message]).utf8)) as? [String: Any])
        var matches = try #require(answer["matches"] as? [[String: Any]])
        matches[0]["words"] = ["the"]
        answer["matches"] = matches
        let json = try #require(String(data: try JSONSerialization.data(withJSONObject: answer), encoding: .utf8))
        transport.stub("POST", "/api/searches", json: json)
        let model = SearchModel()
        model.attach(Self.client(transport))
        model.text = "the"
        model.run(history: .record)
        while model.phase != .loaded { await Task.yield() }
        let highlighted = try #require(model.highlighted[message.id])
        #expect(Self.emphasised(highlighted) == ["The", "the", "the"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aFurtherPageKeepsTheOrderOfTheResultsShown() async throws {
        let transport = MockHTTPTransport()
        transport.stub("GET", "/api/searches", json: Fixtures.searchJSON(search: SearchQuery("the"), next: 2))
        let model = SearchModel()
        model.attach(Self.client(transport))
        model.text = "the"
        model.sort = .oldest
        model.run(history: .skip)
        while model.phase != .loaded { await Task.yield() }
        // The order is changed but not yet searched again: the page shown is still oldest first.
        model.sort = .newest
        model.loadMore()
        while model.isLoadingMore { await Task.yield() }
        let page = try #require(transport.requests("GET", "/api/searches").last?.url?.absoluteString)
        #expect(page.contains("cursor=2"))
        #expect(page.contains("sort=oldest"))
    }

    @Test func everyOccurrenceIsEmphasisedIgnoringCaseAndAccents() {
        let text = SearchHighlight.attributed("The theme of thé day", words: ["the"])
        #expect(Self.emphasised(text) == ["The", "the", "thé"])
        #expect(String(text.characters) == "The theme of thé day")
    }

    @Test func overlappingWordsAreEmphasisedAsOneRun() {
        let text = SearchHighlight.attributed("themes", words: ["them", "hemes", "x"])
        #expect(Self.emphasised(text) == ["themes"])
        #expect(Self.emphasised(SearchHighlight.attributed("nothing here", words: ["zebra"])).isEmpty)
    }

    @Test func aLongMessageFullOfTheWordCostsNoMoreThanWhatItShows() {
        let long = String(repeating: "the ", count: 50_000)
        let text = SearchHighlight.attributed(long, words: ["the"])
        #expect(text.characters.count == SearchHighlight.shownLength)
        #expect(Self.emphasised(text).count == SearchHighlight.shownLength / 4)
    }

    @Test func aResultSaysItsRoomAsHashNameOrDirectMessage() {
        #expect(SearchView.eyebrow(for: Room(id: "o", kind: .open, name: "general"), name: "general") == "#general")
        #expect(SearchView.eyebrow(for: Room(id: "c", kind: .closed, name: "Launch"), name: "Launch") == "#Launch")
        #expect(SearchView.eyebrow(for: Room(id: "d", kind: .direct), name: "Sam Rivera") == "Direct message")
    }

    // MARK: Avatars

    @Test func initialsAreTwoAtMost() {
        #expect(AvatarStyle.initials(of: "David Heinemeier Hansson", atMost: 2) == "DH")
        #expect(AvatarStyle.initials(of: "Élodie", atMost: 2) == "É")
        #expect(AvatarStyle.initials(of: "Grace Hopper", atMost: 2) == "GH")
    }

    @Test func avatarsAreDecodedAtTheSizeTheyreDrawn() {
        #expect(AvatarImages.pixels(points: 36, scale: 3) == 128)
        #expect(AvatarImages.pixels(points: 32, scale: 2) == 64)
        #expect(AvatarImages.pixels(points: 1, scale: 1) == 32)
        #expect(AvatarImages.pixels(points: 400, scale: 3) == 512)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLargeAvatarIsDecodedNoBiggerThanItsDrawn() async throws {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 512, height: 512))
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        let pixels = AvatarImages.pixels(points: 36, scale: 3)
        let image = try #require(await images.image(for: source, pixels: pixels))
        let bitmap = try #require(image.cgImage)
        #expect(max(bitmap.width, bitmap.height) <= pixels)
        #expect(images.cached(source, pixels: pixels) === image)
    }

    @Test(.timeLimit(.minutes(1)))
    func rowsAskingForTheSameAvatarShareOneLoad() async {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 64, height: 64), holds: true)
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        let rows = (0 ..< 5).map { _ in Task { await images.image(for: source, pixels: 64) } }
        while await transport.heldCount < 1 { await Task.yield() }
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(await transport.paths.count == 1)
        await transport.releaseAll()
        var loaded = 0
        for row in rows where await row.value != nil { loaded += 1 }
        #expect(loaded == 5)
        #expect(await transport.paths.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func noMoreThanFourAvatarsLoadAtOnce() async {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 32, height: 32), holds: true)
        let images = AvatarImages(concurrentLoads: 4)
        let client = Self.client(transport)
        let rows = (0 ..< 20).map { index in
            Task { await images.image(for: AvatarImages.Source(client: client, path: "/users/\(index)/avatar"), pixels: 32) }
        }
        while await transport.heldCount < 4 { await Task.yield() }
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(await transport.paths.count == 4)
        while true {
            let sent = await transport.paths.count
            let held = await transport.heldCount
            guard sent < 20 || held > 0 else { break }
            await transport.releaseAll()
            await Task.yield()
        }
        var loaded = 0
        for row in rows where await row.value != nil { loaded += 1 }
        #expect(loaded == 20)
        #expect(await transport.mostAtOnce == 4)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRowThatGoesAwayCancelsItsLoad() async {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 64, height: 64), holds: true)
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        let row = Task { await images.image(for: source, pixels: 64) }
        while await transport.heldCount < 1 { await Task.yield() }
        row.cancel()
        #expect(await row.value == nil)
        while await transport.cancelled < 1 || images.loadCount > 0 { await Task.yield() }
        #expect(images.cached(source, pixels: 64) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func oneRowGoingAwayLeavesTheLoadForTheOthers() async {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 64, height: 64), holds: true)
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        let leaving = Task { await images.image(for: source, pixels: 64) }
        let staying = Task { await images.image(for: source, pixels: 64) }
        while await transport.heldCount < 1 { await Task.yield() }
        leaving.cancel()
        #expect(await leaving.value == nil)
        await transport.releaseAll()
        #expect(await staying.value != nil)
        #expect(await transport.cancelled == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func bytesThatArentAPictureAreAskedForOnce() async {
        let transport = AvatarTransport(body: Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8))
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        #expect(await images.image(for: source, pixels: 64) == nil)
        #expect(await images.image(for: source, pixels: 128) == nil)
        #expect(await transport.paths.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyingTheAvatarsForgetsEveryPicture() async {
        let transport = AvatarTransport(body: ImagesAndLinksTests.png(width: 64, height: 64))
        let images = AvatarImages()
        let source = AvatarImages.Source(client: Self.client(transport), path: "/users/1/avatar")
        #expect(await images.image(for: source, pixels: 64) != nil)
        #expect(images.cached(source, pixels: 64) != nil)
        images.removeAll()
        #expect(images.cached(source, pixels: 64) == nil)
        #expect(await images.image(for: source, pixels: 64) != nil)
        #expect(await transport.paths.count == 2)
    }

    @Test func theAvatarCacheIsBoundedByDecodedBytes() {
        #expect(AvatarImages().costLimit == 16 * 1024 * 1024)
        #expect(AvatarImages(costLimit: 1_024).costLimit == 1_024)
    }

    // MARK: Helpers

    private static func directory(_ count: Int) -> [UserID: DirectoryUser] {
        let first = ["Ada", "Grace", "Alan", "Élodie", "Katherine", "Linus", "Margaret", "Dennis", "Barbara", "Ken"]
        let last = ["Lovelace", "Hopper", "Turing", "Ünal", "Johnson", "Torvalds", "Hamilton", "Ritchie", "Liskov", "Thompson"]
        var people: [UserID: DirectoryUser] = [:]
        for index in 0 ..< count {
            let id = UserID("user_\(index)")
            let name = "\(first[index % first.count]) \(last[(index / first.count) % last.count]) \(index)"
            people[id] = DirectoryUser(id: id, name: name, status: index % 50 == 49 ? .deactivated : .active, avatarUrl: "/users/\(index)/avatar")
        }
        return people
    }

    private static func client(_ transport: some HTTPTransport) -> EmberClient {
        EmberClient(origin: URL(string: "https://chat.example.com")!, environment: .mock(transport: transport, cookies: EphemeralCookieStorage()))
    }

    /// The emphasised runs of `text`, in order.
    private static func emphasised(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run.inlinePresentationIntent == .stronglyEmphasized ? String(text[run.range].characters) : nil
        }
    }
}

/// Answers every request with `body`, holding each one until `releaseAll()` when `holds`, and
/// counting how many were under way at once and how many were cancelled while held.
private actor AvatarTransport: HTTPTransport {
    private let body: Data
    private let holds: Bool
    private(set) var paths: [String] = []
    private(set) var running = 0
    private(set) var mostAtOnce = 0
    private(set) var cancelled = 0
    private var held: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledBeforeHeld: Set<UUID> = []

    init(body: Data, holds: Bool = false) {
        self.body = body
        self.holds = holds
    }

    var heldCount: Int { held.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url?.path() ?? "")
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        if holds {
            let id = UUID()
            let released = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if cancelledBeforeHeld.remove(id) != nil {
                        continuation.resume(returning: false)
                    } else {
                        held[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            if !released {
                cancelled += 1
                throw CancellationError()
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }

    func releaseAll() {
        let all = held
        held = [:]
        for continuation in all.values { continuation.resume(returning: true) }
    }

    private func cancel(_ id: UUID) {
        if let continuation = held.removeValue(forKey: id) {
            continuation.resume(returning: false)
        } else {
            cancelledBeforeHeld.insert(id)
        }
    }
}
