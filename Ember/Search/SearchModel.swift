import EmberSDK
import Foundation
import Observation

/// What the Search tab holds: the words and filters being edited, the results of the search last
/// run, and the recent searches. Searches run on submit, never per keystroke.
@MainActor @Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    var text = ""
    var roomID: RoomID?
    var fromID: UserID?
    var withMe = false
    var hasLink = false
    var hasFile = false
    var inThread = false
    var sort: SearchSort = .newest

    private(set) var phase: Phase = .idle
    private(set) var matches: [SearchMatch] = []
    private(set) var rooms: [RoomID: Room] = [:]
    private(set) var next: Int?
    private(set) var recent: [SearchQuery] = []
    private(set) var isLoadingMore = false
    private(set) var moreFailure: String?

    private var client: EmberClient?
    private var task: Task<Void, Never>?
    /// Bumped by every new search, so an answer that arrives late can tell it's out of date.
    private var generation = 0
    /// The query the shown results are for, which is what a further page continues.
    private var shownQuery: SearchQuery?

    var query: SearchQuery {
        SearchQuery(
            q: text.trimmingCharacters(in: .whitespacesAndNewlines),
            roomID: roomID, from: fromID, withMe: withMe, hasLink: hasLink, hasFile: hasFile, inThread: inThread
        )
    }

    var hasFilters: Bool {
        roomID != nil || fromID != nil || withMe || hasLink || hasFile || inThread
    }

    func attach(_ client: EmberClient) {
        self.client = client
    }

    /// Fetches the recent searches: a search with no words or filters is all they are.
    func loadRecent() async {
        guard let client, phase == .idle else { return }
        if let results = try? await client.search(SearchQuery(q: "")), phase == .idle {
            recent = results.recent
        }
    }

    /// Runs the search the field and filters describe. `record` is true when someone typed it.
    func run(record: Bool) {
        task?.cancel()
        generation += 1
        let generation = generation
        let query = query
        guard let client, query.isSearchable else {
            reset()
            return
        }
        phase = .searching
        isLoadingMore = false
        moreFailure = nil
        let sort = sort
        task = Task { [weak self] in
            do {
                let results = try await client.search(query, sort: sort, record: record)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.matches = results.matches
                self.rooms = Dictionary(results.rooms.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                self.next = results.next
                self.recent = results.recent
                self.shownQuery = query
                self.phase = .loaded
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a recent search again, as if it had been typed.
    func run(_ recent: SearchQuery) {
        text = recent.q
        roomID = recent.roomID
        fromID = recent.from
        withMe = recent.withMe
        hasLink = recent.hasLink
        hasFile = recent.hasFile
        inThread = recent.inThread
        run(record: true)
    }

    /// The next page, when the last row has appeared.
    func loadMore() {
        guard let client, let cursor = next, let query = shownQuery, phase == .loaded, !isLoadingMore else { return }
        isLoadingMore = true
        moreFailure = nil
        let generation = generation
        let sort = sort
        task = Task { [weak self] in
            do {
                let results = try await client.search(query, sort: sort, cursor: cursor, record: false)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                let known = Set(self.matches.map(\.id))
                self.matches += results.matches.filter { !known.contains($0.id) }
                for room in results.rooms { self.rooms[room.id] = room }
                self.next = results.next
                self.isLoadingMore = false
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.moreFailure = error.localizedDescription
                self.isLoadingMore = false
            }
        }
    }

    func retry() {
        run(record: false)
    }

    func clearFilters() {
        roomID = nil
        fromID = nil
        withMe = false
        hasLink = false
        hasFile = false
        inThread = false
    }

    /// Back to the recent searches.
    func reset() {
        task?.cancel()
        generation += 1
        phase = .idle
        matches = []
        next = nil
        shownQuery = nil
        isLoadingMore = false
        moreFailure = nil
    }

    func clearRecent() async {
        guard let client else { return }
        do {
            try await client.clearRecentSearches()
            recent = []
        } catch {
            // Leave them showing: they weren't cleared.
        }
    }
}
