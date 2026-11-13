import EmberSDK
import SwiftUI

/// The Search tab's content. HomeView supplies the navigation stack and the `RoomLink` destination.
struct SearchView: View {
    @Environment(Workspace.self) private var workspace
    @State private var model = SearchModel()
    @State private var confirmingClear = false
    @State private var picking: FilterPicker?

    /// The filter whose list is open.
    private enum FilterPicker: Identifiable {
        case room, person
        var id: Self { self }
    }

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
                    ContentUnavailableView.search(text: model.shownQuery?.q ?? model.text)
                        .listRowSeparator(.hidden)
                } else {
                    results
                }
            }
        }
        .listStyle(.plain)
        .clearsFloatingNewMessage()
        // Inside the search so the bar can tell whether the navigation bar above it is showing.
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.hasFilters || model.sort == .oldest { ChipBar { chips } }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: typedText, prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { model.run(history: .record) }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { filterMenu } }
        .sheet(item: $picking) { picker in
            switch picker {
            case .room: RoomFilterPicker(selection: roomBinding)
            case .person: PersonFilterPicker(selection: personBinding)
            }
        }
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
            // Each list opens on its own, so the menu doesn't hold a row for every room and person.
            Button("Room", systemImage: "number") { picking = .room }
            Button("Person", systemImage: "person") { picking = .person }
            Toggle("Mentions me", systemImage: "at", isOn: flagBinding(\.withMe))
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

    /// Changing a filter or the sort re-runs the search that's showing, if there is one.
    private func changed() {
        if model.query.isSearchable { model.run(history: .skip) } else { model.reset() }
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

    /// Before iOS 26 the navigation bar follows a scroll view in the bar above the list in place of
    /// the list, so the large title stays put over the results. There the chips wrap onto more
    /// lines and nothing scrolls sideways.
    @ViewBuilder private var chips: some View {
        if #available(iOS 26.0, *) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.chipSpacing) { chipItems }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        } else {
            ChipFlow(spacing: Self.chipSpacing) { chipItems }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let chipSpacing: CGFloat = 8

    @ViewBuilder private var chipItems: some View {
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
                SearchRow(match: match, room: room(match.message.roomId), highlighted: model.highlighted[match.id])
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

    /// The line over a result's author: the room as "#name", or "Direct message" for a DM.
    static func eyebrow(for room: Room, name: String) -> String {
        room.isDirect ? "Direct message" : "#\(name)"
    }
}

/// The filter chips' bar. With the navigation bar showing, its background stays behind the chips,
/// since reaching up would cover the large title. While searching, the navigation bar is put
/// away and the background reaches up behind the status bar instead.
private struct ChipBar<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @ViewBuilder var content: Content

    var body: some View {
        content.background(.bar, ignoresSafeAreaEdges: isSearching ? .top : [])
    }
}

/// Lays chips out left to right and starts a new line when the next one doesn't fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(in: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each chip's frame within the layout. A chip wider than a whole line is held to the line.
    private func frames(in width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

private struct SearchRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36
    /// Between the avatar and the text, and so the eyebrow's indent.
    private static let avatarSpacing: CGFloat = 12
    let match: SearchMatch
    let room: Room?
    let highlighted: AttributedString?

    var body: some View {
        let message = match.message
        let author = workspace.name(of: message.creator)
        Group {
            if typeSize.isAccessibilitySize {
                // At the largest text sizes the avatar leaves no room for text beside it, so the
                // lines go under it, as they do in Home's rows.
                VStack(alignment: .leading, spacing: 4) {
                    if let room { eyebrow(room) }
                    HStack(spacing: Self.avatarSpacing) {
                        AvatarView(userID: message.creator.id, name: author, size: avatarSize)
                        Spacer(minLength: 0)
                        time
                    }
                    name(author)
                    text
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    // Over the text, so the avatar lines up with the author's name.
                    if let room {
                        eyebrow(room)
                            .lineLimit(1)
                            .padding(.leading, avatarSize + Self.avatarSpacing)
                    }
                    HStack(alignment: .top, spacing: Self.avatarSpacing) {
                        AvatarView(userID: message.creator.id, name: author, size: avatarSize)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                name(author).lineLimit(1)
                                Spacer(minLength: 8)
                                time
                            }
                            text
                        }
                        // The line between rows starts under the text, not the avatar's initials.
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eyebrow(_ room: Room) -> some View {
        let name = workspace.name(of: room)
        return Text(SearchView.eyebrow(for: room, name: name))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(room.isDirect ? "Direct message" : name)
    }

    private func name(_ author: String) -> some View {
        Text(author).font(.subheadline.weight(.semibold))
    }

    private var time: some View {
        RelativeTimeText(match.message.createdAt)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var text: some View {
        Text(highlighted ?? SearchHighlight.attributed(match.message.plainText, words: match.words))
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(4)
    }
}
