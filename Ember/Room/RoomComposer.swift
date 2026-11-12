import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import EmberSDK
import EmberRichText

/// The foot of a room or a thread, where the tab bar stands at the top level: who's typing, the
/// people a name being typed after "@" could be, and the glass card with what's staged to send, a
/// field that grows as someone writes, and a row with the attach menu at its start and the send
/// button at its end. Editing a message borrows the same field, setting the draft aside until the
/// edit is saved or discarded.
struct RoomComposer: View {
    let room: RoomSession
    /// Set in a thread, where replies go and the also-send toggle shows.
    var thread: ThreadSession? = nil
    @Binding var editing: MessageEdit?
    /// Where the draft and staged files are kept.
    var drafts: Drafts = .shared
    /// After a new message (not an edit) goes, so the timeline can follow it down.
    let onSend: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var suggestionAvatarSize: CGFloat = 28
    @State private var isFocused = false
    /// The edit's text and who was chosen in it, while there's an edit.
    @State private var editDraft = Draft()
    @State private var selection: TextSelection?
    @State private var alsoSend = false
    @State private var isPickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var isImporting = false

    private var key: DraftKey {
        DraftKey(server: workspace.client.origin.absoluteString, user: workspace.me.id, room: room.roomID, thread: thread?.parentID)
    }

    private var draft: Draft { drafts.draft(for: key) }

    /// What's staged here, kept while the app runs so it's still here on coming back.
    private var staged: StagedFiles { drafts.staged(for: key) }

    /// What the field holds and who it mentions: the edit's during an edit, the draft's otherwise.
    private var current: Draft { editing == nil ? draft : editDraft }

    private var text: String { current.text }

    /// Only for whether there's anything to send: what's sent is the draft as typed (`outgoing`).
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var overLimit: Int { Self.overLimit(text) }

    /// The edit's change, while there's an edit.
    private var editKey: SentChanges.Key? { editing.map { .edit($0.id) } }

    /// Whether the edit is on its way to the room, so Save waits for its answer.
    private var isSaving: Bool { editKey.map(SentChanges.shared.isSending) ?? false }

    /// Whether the room didn't make the edit, which stays open with its text to try again.
    private var saveFailed: Bool { editKey.map(SentChanges.shared.hasFailed) ?? false }

    private var canSend: Bool {
        guard overLimit == 0, staged.copying == 0, !isSaving else { return false }
        // An edit that changes nothing has nothing to send.
        if let editing { return editing.canSave(editDraft) }
        return !trimmed.isEmpty || !staged.files.isEmpty
    }

    private var typingPeople: [User] { thread?.timeline.typing ?? room.timeline.typing }

    /// Whether the card is laid out in one row, the field between the attach menu and Send, to
    /// leave the timeline room where there's little height (a phone on its side).
    private var isCompact: Bool { verticalSizeClass == .compact }

    /// The text as the field writes it, saying whether this person is typing as they type. Said
    /// here rather than from an `onChange(of: draft)`, which a burst of input (a paste, dictation,
    /// the simulator typing) changes several times a frame, and which would also hear the draft
    /// set from outside, after a send. An edit isn't writing in the room, so it doesn't say
    /// anyone's typing; nor does a reply, as a thread never says so.
    private var typedText: Binding<String> {
        Binding(
            get: { text },
            set: { text in
                guard editing == nil else {
                    editDraft.text = text
                    return
                }
                drafts.set(Draft(text: text, mentions: draft.mentions), for: key)
                if thread == nil { room.setTyping(!text.isEmpty) }
            })
    }

    /// The name being typed after "@" at the caret, if any, in the draft or the edit.
    private var mentionQuery: MentionQuery? {
        var caret: String.Index?
        if let selection {
            guard case .selection(let range) = selection.indices, range.isEmpty else { return nil }
            caret = range.lowerBound
        }
        if let editing { return editing.mentionQuery(in: editDraft, caret: caret) }
        return MentionQuery.active(in: draft.text, caret: caret, chosen: draft.mentions.values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            typing
            mentionSuggestions
            ComposerCard(margin: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    if editing != nil {
                        editingBar
                        Divider()
                    }
                    VStack(spacing: isCompact ? 8 : 12) {
                        if !staged.files.isEmpty || staged.copying > 0 { stagedStrip }
                        if isCompact {
                            HStack(alignment: .bottom, spacing: 12) {
                                attachMenu
                                    .padding(.bottom, 2)
                                field
                                if let thread { alsoSendToggle(thread) }
                                sendButton
                                    .padding(.bottom, 2)
                            }
                        } else {
                            field
                            actionRow
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, isCompact ? 6 : 8)
                    .padding(.bottom, isCompact ? 8 : 12)
                    .focusesOnTap { isFocused = true }
                }
            }
        }
        .onChange(of: editing?.id) { _, id in
            editDraft = Draft(text: editing?.text ?? "")
            selection = nil
            if let id, SentChanges.shared.hasFailed(.edit(id)) { SentChanges.shared.dismiss(.edit(id)) }
            if id != nil {
                if thread == nil { room.setTyping(false) }
                isFocused = true
            }
        }
        .photosPicker(
            isPresented: $isPickingPhotos, selection: $photos,
            matching: .any(of: [.images, .videos]),
            // A HEIC comes over as a JPEG, which anyone the file goes to can open.
            preferredItemEncoding: .compatible)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            for item in items { stagePhoto(item) }
            // Cleared after this update, not in it: writing what fired the handler would fire it
            // again in the same frame. Cleared so the picker opens with nothing ticked next time.
            Task { @MainActor in photos = [] }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { stageFile(url) }
        }
        .animation(.easeInOut(duration: 0.2), value: typingPeople.isEmpty)
        .animation(.easeOut(duration: 0.15), value: suggestions?.people.map(\.id))
        .animation(.easeInOut(duration: 0.2), value: editing?.id)
        .animation(.easeInOut(duration: 0.2), value: staged.files.map(\.id))
    }

    private var field: some View {
        MentionField(
            placeholder: thread == nil ? "Message" : "Reply", text: typedText, selection: $selection, isFocused: $isFocused,
            mentions: fieldMentions,
            lines: Self.lines(compactHeight: isCompact, accessibilitySize: dynamicTypeSize.isAccessibilitySize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.vertical, isCompact ? 10 : 4)
    }

    /// Who the field's text can mention, which it shows tinted: those chosen, and while editing the
    /// people the message already mentions.
    private var fieldMentions: [UserID: String] {
        guard let editing else { return draft.mentions }
        return editDraft.mentions.merging(editing.mentioned) { chosen, _ in chosen }
    }

    /// The most lines the field grows to before its text scrolls inside it: fewer where there's
    /// little height or the text is large, so some of the timeline always shows above it.
    static func lines(compactHeight: Bool, accessibilitySize: Bool) -> Int {
        if compactHeight { return accessibilitySize ? 1 : 2 }
        return accessibilitySize ? 4 : 8
    }

    /// How many characters `text` runs over what the server takes, counted as it counts them: the
    /// plain text that would go, in UTF-16 units. 0 when it fits.
    static func overLimit(_ text: String) -> Int {
        max(0, (plainText(text)?.utf16.count ?? 0) - Limits.message)
    }

    /// The name being typed after "@" and who it could mean, while anyone could.
    private var suggestions: (query: MentionQuery, people: [DirectoryUser])? {
        guard let query = mentionQuery else { return nil }
        let people = MentionQuery.candidates(
            workspace.people.values, matching: query.text,
            first: Self.roomPeople(room: room, thread: thread, in: workspace), excluding: workspace.me.id)
        return people.isEmpty ? nil : (query, people)
    }

    /// The people who could be meant by a name being typed after "@", above the card. Choosing one
    /// writes their name in the field as a mention. It rises a little from the card as it shows,
    /// and grows or shrinks in place as what's typed changes who it could be.
    @ViewBuilder private var mentionSuggestions: some View {
        if let suggestions {
            let query = suggestions.query, people = suggestions.people
            ComposerCard(margin: 12) {
                VStack(spacing: 0) {
                    ForEach(people) { person in
                        if person.id != people.first?.id { Divider().padding(.leading, 24 + suggestionAvatarSize) }
                        Button {
                            choose(person, for: query)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(userID: person.id, name: person.name, size: suggestionAvatarSize)
                                    .accessibilityHidden(true)
                                Text(person.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            // With Reduce Motion it fades in where it stands rather than rising.
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        }
    }

    /// The people a mention here most likely means: a direct message's members, whoever has the
    /// room open, and whoever wrote what's loaded of the room or the thread. Suggested before
    /// everyone else, as the SDK has no list of a shared room's members.
    static func roomPeople(room: RoomSession, thread: ThreadSession?, in workspace: Workspace) -> Set<UserID> {
        var people = Set(workspace.room(room.roomID)?.room.members?.map(\.id) ?? [])
        people.formUnion(room.timeline.present.map(\.id))
        people.formUnion(room.timeline.messages.map(\.creator.id))
        if let thread {
            people.formUnion(thread.timeline.replies.map(\.creator.id))
            if let parent = thread.timeline.parentMessage { people.insert(parent.creator.id) }
        }
        return people
    }

    private func choose(_ person: DirectoryUser, for query: MentionQuery) {
        let chosen = query.choosing(person.id, name: person.name, in: current)
        if editing == nil { drafts.set(chosen.draft, for: key) } else { editDraft = chosen.draft }
        selection = TextSelection(insertionPoint: chosen.caret)
    }

    @ViewBuilder private var typing: some View {
        let people = typingPeople
        if !people.isEmpty {
            HStack(spacing: 8) {
                TypingBubble()
                    .scaleEffect(0.75, anchor: .leading)
                    .frame(height: 24, alignment: .leading)
                Text(people.map { workspace.name(of: $0) }.sorted().joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    /// What goes with Send, in the order picked, each with its own remove button.
    private var stagedStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(staged.files) { file in
                    StagedFileView(file: file) { staged.remove(file) }
                }
                if staged.copying > 0 {
                    ProgressView()
                        .frame(width: 60, height: 60)
                }
            }
            // Room for the remove buttons' targets, which stand out past each file's corner.
            .padding(.top, StagedFileView.removeTarget / 2 - 2)
            .padding(.trailing, StagedFileView.removeTarget / 2 - 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 60 + StagedFileView.removeTarget / 2 - 2)
    }

    /// Under the field, so the text gets the card's full width: what goes with the message at the
    /// start, Send at the end.
    private var actionRow: some View {
        HStack(spacing: 12) {
            attachMenu
            if let thread { alsoSendToggle(thread) }
            Spacer(minLength: 0)
            sendButton
        }
    }

    /// Send, and beside it how many characters the text runs over the limit, while it does.
    private var sendButton: some View {
        HStack(spacing: 8) {
            if overLimit > 0 {
                Text(overLimit, format: .number)
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("\(overLimit) characters over the limit")
            }
            Button(action: send) {
                SendGlyph(isEnabled: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(editing == nil ? "Send" : "Save")
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
            Button("Files", systemImage: "folder") { isImporting = true }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title2)
                .foregroundStyle(editing == nil ? Color.secondary : Color(.tertiaryLabel))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        // Pulled back outside the menu rather than in its label: on iOS 18 the menu's button is
        // only as big as its label's frame, and would cut the 44pt target down to the glyph.
        .padding(-8)
        // An edit changes a message's text alone.
        .disabled(editing != nil)
        .accessibilityLabel("Attach")
    }

    private func alsoSendToggle(_ thread: ThreadSession) -> some View {
        Toggle(Self.alsoSendLabel(for: workspace.room(thread.room.roomID)?.room), isOn: $alsoSend)
            .toggleStyle(CheckToggleStyle())
            .font(.footnote)
            .lineLimit(1)
            // The web's checkbox goes grey while the socket's down, as a reply can't go then; and
            // an edit has nowhere else to go.
            .disabled(editing != nil || room.status != .open)
    }

    /// What the thread's also-send toggle says: the room by name, or a DM as a DM.
    static func alsoSendLabel(for room: Room?) -> String {
        if room?.isDirect == true { return "Also send as direct message" }
        return "Also send to #\(room?.name ?? "")"
    }

    private var editingBar: some View {
        HStack(spacing: 8) {
            if saveFailed {
                Text(SentChanges.failureText(.edit))
                    .foregroundStyle(.red)
                Button("Retry", action: send)
                    .fontWeight(.semibold)
                    .buttonStyle(.borderless)
            } else {
                Text("Editing")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button("Discard", action: cancelEditing)
                .fontWeight(.semibold)
        }
        .announcesWhenShown(saveFailed ? SentChanges.failureText(.edit) : nil)
        .font(.subheadline)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private func send() {
        guard canSend else { return }
        if let editing {
            // Only what the edit touched changes; the rest of the body keeps its formatting.
            guard let body = editing.body(for: editDraft) else { return }
            Task {
                // Refused, unanswered or not connected, the edit stays open with its text, and
                // its bar says so with Retry.
                guard await Self.save(editing, body: body, in: room) else { return }
                guard Self.closesEdit(saved: editing, editing: self.editing) else { return }
                self.editing = nil
                isFocused = true
            }
            return
        }
        do {
            try Self.send(draft, staged: staged, room: room, thread: thread, alsoSend: alsoSend)
            sent()
        } catch {
            refuse(error)
            return
        }
        drafts.clear(key)
        selection = nil
        // Kept up for the next message, as a chat's composer stays open after a send.
        isFocused = true
    }

    private func sent() {
        if thread == nil { room.setTyping(false) }
        // Off again after every send, as the web's is.
        alsoSend = false
        onSend()
    }

    /// The draft set aside for the edit comes back. A failed save is let go of with it.
    private func cancelEditing() {
        if let editKey, SentChanges.shared.hasFailed(editKey) { SentChanges.shared.dismiss(editKey) }
        editing = nil
    }

    /// Whether an edit saved closes, bringing back the draft set aside for it: yes while the same
    /// message is still being edited, whatever was typed into it while the save was on its way.
    static func closesEdit(saved: MessageEdit, editing: MessageEdit?) -> Bool {
        editing?.id == saved.id
    }

    /// Saves an edit through the room's `async` call. True once the room has shown it; false when
    /// it was refused, went unanswered, couldn't reach the room, or is already on its way.
    static func save(_ edit: MessageEdit, body: String, in room: RoomSession, changes: SentChanges = .shared) async -> Bool {
        let id = edit.id
        return await changes.send(.edit(id)) { try await room.edit(message: id, body: body) }
    }

    /// Sends `draft` with what's staged, which is handed over only once the message is on its way:
    /// a draft refused keeps its files staged. Each file's picture shows on its pending row.
    static func send(_ draft: Draft, staged: StagedFiles, room: RoomSession, thread: ThreadSession?, alsoSend: Bool) throws(EmberError) {
        let files = staged.files
        let ids = try send(draft, files: files.map(\.source), room: room, thread: thread, alsoSend: alsoSend)
        if !files.isEmpty { _ = staged.takeAll() }
        for (id, thumbnail) in thumbnails(ids: ids, files: files) {
            StagedThumbnails.shared.set(thumbnail, for: id)
        }
    }

    /// Sends `draft` with `files`, into `thread` when there is one: text in plain through the SDK,
    /// which escapes it, and text with mentions as `outgoing(_:)` builds it. Answers the client
    /// message ids, as `send(files:)` does. Throws, sending nothing, for text the SDK refuses.
    @discardableResult
    static func send(_ draft: Draft, files: [UploadSource] = [], room: RoomSession, thread: ThreadSession?, alsoSend: Bool) throws(EmberError) -> [String] {
        switch outgoing(draft) {
        case let .mentions(body, plainText):
            if !files.isEmpty {
                if let thread { return thread.send(files: files, body: body, plainText: plainText, alsoSend: alsoSend) }
                return room.send(files: files, body: body, plainText: plainText)
            }
            if let thread { return [thread.reply(body: body, plainText: plainText, alsoSend: alsoSend)] }
            return [room.send(body: body, plainText: plainText)]
        case let .text(text):
            if !files.isEmpty {
                if let thread { return try thread.send(files: files, text: text, alsoSend: alsoSend) }
                return try room.send(files: files, text: text)
            }
            if let thread { return [try thread.reply(text: text, alsoSend: alsoSend)] }
            return [try room.send(text: text)]
        case nil:
            guard !files.isEmpty else { return [] }
            if let thread { return thread.send(files: files, body: nil, plainText: nil, alsoSend: alsoSend) }
            return room.send(files: files)
        }
    }

    /// What Send sends for a draft.
    enum Outgoing: Equatable {
        /// Text in plain, which the SDK escapes.
        case text(String)
        /// Text with mentions, as the composer builds its body.
        case mentions(body: String, plainText: String)
    }

    /// What Send sends for `draft`, or nil when it's blank: in plain, or with a mention for each of
    /// its people whose "@" and name are still in its text.
    static func outgoing(_ draft: Draft) -> Outgoing? {
        guard let plainText = plainText(draft.text) else { return nil }
        let mentions = draft.pruned.mentions
        guard !mentions.isEmpty else { return .text(draft.text) }
        return .mentions(body: RichText.body(from: RichText.segments(plainText, mentions: mentions)), plainText: plainText)
    }

    /// The plain text the room is sent for `text`, as the SDK's `send(text:)` makes it, or nil
    /// when it's blank: line endings made `\n`, and blank lines at the end dropped. For a message
    /// with mentions, whose body the composer builds, and for counting against the limit.
    static func plainText(_ text: String) -> String? {
        var lines = text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        let plainText = lines.joined(separator: "\n")
        return plainText.allSatisfy(\.isWhitespace) ? nil : plainText
    }

    /// Which thumbnail goes with which id `send(files:)` answered: one id per file in order, a
    /// refused one's too, then the text's; or fewer, or none, once the session's shut down. A
    /// refused file has no pending row to show one in.
    static func thumbnails(ids: [String], files: [StagedFile]) -> [(id: String, thumbnail: UIImage)] {
        zip(ids, files).compactMap { id, file in
            guard !file.source.isTooLarge, let thumbnail = file.thumbnail else { return nil }
            return (id, thumbnail)
        }
    }

    private func stagePhoto(_ item: PhotosPickerItem) {
        if PickedFile.goesAsPicture(item.supportedContentTypes) {
            staged.stage({ try await item.loadTransferable(type: PickedStill.self)?.url }, refuse: refuse)
        } else {
            staged.stage({ try await item.loadTransferable(type: PickedFile.self)?.url }, refuse: refuse)
        }
    }

    private func stageFile(_ url: URL) {
        staged.stage({ try Staging.copied(url, isScoped: true) }, refuse: refuse)
    }

    private func refuse(_ error: Error) {
        let notice: String
        if case .tooLarge(let name) = error as? Staging.Refusal {
            notice = Uploads.tooLarge(name)
        } else if let error = error as? EmberError {
            notice = error.message
        } else {
            notice = "That file can’t be read."
        }
        if let thread { thread.notice = notice } else { room.notice = notice }
    }
}

/// A staged file in the composer's strip: its picture, or its symbol and name.
struct StagedFileView: View {
    let file: StagedFile
    let remove: () -> Void

    /// The side of the remove button's target.
    static let removeTarget: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let thumbnail = file.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(shape)
                    .accessibilityLabel(file.name)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: FileRow.symbol(contentType: file.source.contentType, name: file.name))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(file.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: 180, minHeight: 60, maxHeight: 60)
                .background(Color(.secondarySystemBackground), in: shape)
            }
        }
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    // A 44pt target, centred where the glyph stands out past the corner.
                    .frame(width: StagedFileView.removeTarget, height: StagedFileView.removeTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(x: StagedFileView.removeTarget / 2 - 2, y: -(StagedFileView.removeTarget / 2 - 2))
            .accessibilityLabel("Remove \(file.name)")
        }
    }
}

/// A toggle drawn as a checkbox and its label, as the web's also-send is.
private struct CheckToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                configuration.label
                    .foregroundStyle(.secondary)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
