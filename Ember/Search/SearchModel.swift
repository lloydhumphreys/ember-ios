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

    /// Where the next page of the shown results is, once they are shown.
    enum More: Equatable {
        case idle
        case loading
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
    /// Each shown match's text with its words emphasised, worked out once as its page arrives.
    private(set) var highlighted: [SearchMatch.ID: AttributedString] = [:]
    private(set) var rooms: [RoomID: Room] = [:]
    private(set) var next: Int?
    private(set) var recent: [SearchQuery] = []
    private(set) var more = More.idle

    var isLoadingMore: Bool { more == .loading }

    var moreFailure: String? {
        if case .failed(let message) = more { message } else { nil }
    }

    private var client: EmberClient?
    private var task: Task<Void, Never>?
    /// Bumped by every new search, so an answer that arrives late can tell it's out of date.
    private var generation = 0
    /// The query the shown results are for, which is what a further page continues.
    private(set) var shownQuery: SearchQuery?
    /// The order the shown results are in, which a further page keeps.
    private var shownSort = SearchSort.newest

    var query: SearchQuery {
        var query = SearchQuery(text.trimmingCharacters(in: .whitespacesAndNewlines))
        query.roomID = roomID
        query.from = fromID
        query.withMe = withMe
        query.hasLink = hasLink
        query.hasFile = hasFile
        query.inThread = inThread
        return query
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
        if let results = try? await client.search(SearchQuery()), phase == .idle {
            recent = results.recent
        }
    }

    /// Runs the search the field and filters describe. `history` is `.record` when someone typed it.
    func run(history: SearchHistory) {
        task?.cancel()
        generation += 1
        let generation = generation
        let query = query
        guard let client, query.isSearchable else {
            if query.q.isEmpty {
                reset()
            } else {
                showNothing(for: query)
            }
            return
        }
        phase = .searching
        more = .idle
        let sort = sort
        task = Task { [weak self] in
            do {
                let results = try await client.search(query, sort: sort, history: history)
                let highlighted = await SearchHighlight.attributed(results.matches)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.matches = results.matches
                self.highlighted = highlighted
                self.rooms = Dictionary(results.rooms.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                self.next = results.next
                self.recent = results.recent
                self.shownQuery = query
                self.shownSort = sort
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
        run(history: .record)
    }

    /// The next page, when the last row has appeared.
    func loadMore() {
        guard let client, let cursor = next, let query = shownQuery, phase == .loaded, !isLoadingMore else { return }
        more = .loading
        let generation = generation
        let sort = shownSort
        task = Task { [weak self] in
            do {
                let results = try await client.search(query, sort: sort, cursor: cursor)
                let highlighted = await SearchHighlight.attributed(results.matches)
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                let known = Set(self.matches.map(\.id))
                self.matches += results.matches.filter { !known.contains($0.id) }
                self.highlighted.merge(highlighted) { old, _ in old }
                for room in results.rooms { self.rooms[room.id] = room }
                self.next = results.next
                self.more = .idle
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.more = .failed(error.localizedDescription)
            }
        }
    }

    /// No results for words the server can't search for, such as emoji or punctuation alone: it
    /// keeps only letters and digits, so asking it would find everything or fail.
    private func showNothing(for query: SearchQuery) {
        phase = .loaded
        matches = []
        highlighted = [:]
        rooms = [:]
        next = nil
        shownQuery = query
        more = .idle
    }

    func retry() {
        run(history: .skip)
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
        highlighted = [:]
        next = nil
        shownQuery = nil
        more = .idle
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
