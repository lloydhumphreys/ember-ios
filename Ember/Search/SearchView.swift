import EmberSDK
import SwiftUI

/// The Search tab's content. HomeView supplies the navigation stack and the `RoomLink` destination.
struct SearchView: View {
    @Environment(Workspace.self) private var workspace
    @State private var model = SearchModel()
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var model = model
        List {
            switch model.phase {
            case .idle:
                recentSearches
            case .searching:
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                    Button("Retry") { model.retry() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            case .loaded:
                if model.matches.isEmpty {
                    ContentUnavailableView.search(text: model.text)
                        .listRowSeparator(.hidden)
                } else {
                    results
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: typedText, prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { model.run(record: true) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.hasFilters || model.sort == .oldest { chips }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
        .deleteConfirmation("Clear recent searches?", isPresented: $confirmingClear) {
            Task { await model.clearRecent() }
        }
        .task {
            model.attach(workspace.client)
            await model.loadRecent()
        }
    }

    /// Emptying the field with no filters left puts the results away. This is done as the field
    /// writes rather than by watching the text, which a burst of input changes several times a
    /// frame. Running a recent search sets the text from code, but that always has words or
    /// filters, so it never needed to reset.
    private var typedText: Binding<String> {
        Binding(
            get: { model.text },
            set: { text in
                model.text = text
                if text.isEmpty && !model.hasFilters { model.reset() }
            })
    }

    // MARK: Before a search

    @ViewBuilder private var recentSearches: some View {
        if !model.recent.isEmpty {
            Section {
                ForEach(Array(model.recent.enumerated()), id: \.offset) { _, query in
                    Button { model.run(query) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if !query.q.isEmpty {
                                    Text(query.q).foregroundStyle(.primary)
                                }
                                if let filters = filterSummary(query) {
                                    Text(filters)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { confirmingClear = true }
                        .font(.subheadline)
                        .textCase(nil)
                }
            }
        }
    }

    private func filterSummary(_ query: SearchQuery) -> String? {
        var parts: [String] = []
        if let id = query.roomID {
            parts.append(workspace.room(id).map { workspace.name(of: $0.room) } ?? "Room")
        }
        if let id = query.from { parts.append(workspace.name(ofUserID: id) ?? "Person") }
        if query.withMe { parts.append("Mentions me") }
        if query.hasLink { parts.append("Link") }
        if query.hasFile { parts.append("File") }
        if query.inThread { parts.append("Thread") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Filters

    private var filterMenu: some View {
        Menu {
            Menu("Room") {
                Picker("Room", selection: roomBinding) {
                    Text("Any").tag(RoomID?.none)
                    ForEach(workspace.sharedRooms + workspace.directRooms) { entry in
                        Text(workspace.name(of: entry.room)).tag(RoomID?.some(entry.id))
                    }
                }
            }
            Menu("Person") {
                Picker("Person", selection: personBinding) {
                    Text("Anyone").tag(UserID?.none)
                    ForEach(people) { person in
                        Text(person.name).tag(UserID?.some(person.id))
                    }
                }
            }
            Toggle("Mentions me", isOn: flagBinding(\.withMe))
            Toggle("Link", systemImage: "link", isOn: flagBinding(\.hasLink))
            Toggle("File", systemImage: "paperclip", isOn: flagBinding(\.hasFile))
            Toggle("Thread", systemImage: "bubble.left.and.bubble.right", isOn: flagBinding(\.inThread))
            Picker("Sort", selection: sortBinding) {
                Text("Newest").tag(SearchSort.newest)
                Text("Oldest").tag(SearchSort.oldest)
            }
        } label: {
            Label("Filters", systemImage: model.hasFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var people: [DirectoryUser] {
        workspace.people.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Changing a filter or the sort re-runs the search that's showing, if there is one.
    private func changed() {
        if model.query.isSearchable { model.run(record: false) } else { model.reset() }
    }

    private var roomBinding: Binding<RoomID?> {
        Binding(get: { model.roomID }, set: { model.roomID = $0; changed() })
    }

    private var personBinding: Binding<UserID?> {
        Binding(get: { model.fromID }, set: { model.fromID = $0; changed() })
    }

    private var sortBinding: Binding<SearchSort> {
        Binding(get: { model.sort }, set: { model.sort = $0; if model.phase != .idle { changed() } })
    }

    private func flagBinding(_ keyPath: ReferenceWritableKeyPath<SearchModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0; changed() })
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let id = model.roomID {
                    chip(workspace.room(id).map { workspace.name(of: $0.room) } ?? "Room") { model.roomID = nil }
                }
                if let id = model.fromID {
                    chip(workspace.name(ofUserID: id) ?? "Person") { model.fromID = nil }
                }
                if model.withMe { chip("Mentions me") { model.withMe = false } }
                if model.hasLink { chip("Link") { model.hasLink = false } }
                if model.hasFile { chip("File") { model.hasFile = false } }
                if model.inThread { chip("Thread") { model.inThread = false } }
                if model.sort == .oldest { chip("Oldest") { model.sort = .newest } }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func chip(_ title: String, remove: @escaping () -> Void) -> some View {
        Button {
            remove()
            changed()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(title)
        .accessibilityHint("Remove")
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        ForEach(model.matches) { match in
            NavigationLink(value: RoomLink.to(match.message)) {
                SearchRow(match: match, room: room(match.message.roomId))
            }
            // A plain list draws a line above its first row too; only the ones between rows stay.
            .listRowSeparator(match.id == model.matches.first?.id ? .hidden : .automatic, edges: .top)
            .onAppear {
                if match.id == model.matches.last?.id { model.loadMore() }
            }
        }
        if model.isLoadingMore {
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowSeparator(.hidden)
        } else if let failure = model.moreFailure {
            HStack {
                Text(failure)
                Spacer()
                Button("Retry") { model.loadMore() }
            }
            .listRowSeparator(.hidden)
        }
    }

    private func room(_ id: RoomID) -> Room? {
        model.rooms[id] ?? workspace.room(id)?.room
    }
}

private struct SearchRow: View {
    @Environment(Workspace.self) private var workspace
    let match: SearchMatch
    let room: Room?

    var body: some View {
        let message = match.message
        let author = workspace.name(of: message.creator)
        VStack(alignment: .leading, spacing: 6) {
            if let room {
                Label(workspace.name(of: room), systemImage: roomSymbol(for: room))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 12) {
                AvatarView(userID: message.creator.id, name: author, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(author)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        RelativeTimeText(message.createdAt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(SearchHighlight.attributed(message.plainText, words: match.words))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
