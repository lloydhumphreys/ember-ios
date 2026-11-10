import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import EmberSDK
import EmberRichText

/// The foot of a room or a thread, where the tab bar stands at the top level: who's typing, and
/// the glass card with what's staged to send, a field that grows as someone writes, and a row
/// with the attach menu at its start and the send button at its end. Editing a message borrows
/// the same field.
struct RoomComposer: View {
    let room: RoomSession
    /// Set in a thread, where replies go and the also-send toggle shows.
    var thread: ThreadSession? = nil
    @Binding var draft: String
    @Binding var editing: MessageEdit?
    /// Takes focus when it first appears, as the web's thread does.
    var focusesOnAppear = false
    /// After a new message (not an edit) goes, so the timeline can follow it down.
    let onSend: () -> Void

    @Environment(Workspace.self) private var workspace
    @FocusState private var isFocused: Bool
    /// Goes with the composer, deleting what was never sent.
    @State private var staged = StagedFiles()
    @State private var alsoSend = false
    @State private var isPickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var isImporting = false

    /// Only for whether there's anything to send: what's sent is the draft as typed (`outgoing`).
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSend: Bool {
        guard draft.utf16.count <= Limits.message, staged.copying == 0 else { return false }
        // An edit that changes nothing has nothing to send.
        if let editing { return MessageEdit.editedText(draft, from: editing.text) != nil }
        return !trimmed.isEmpty || !staged.files.isEmpty
    }

    private var typingPeople: [User] { thread?.timeline.typing ?? room.timeline.typing }

    /// The draft as the field writes it, saying whether this person is typing as they type. Said
    /// here rather than from an `onChange(of: draft)`, which a burst of input (a paste, dictation,
    /// the simulator typing) changes several times a frame, and which would also hear the draft
    /// set from outside, for an edit or cleared after a send. An edit isn't writing in the room,
    /// so it doesn't say anyone's typing; nor does a reply, as a thread never says so.
    private var typedDraft: Binding<String> {
        Binding(
            get: { draft },
            set: { text in
                draft = text
                if editing == nil, thread == nil { room.setTyping(!text.isEmpty) }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            typing
            ComposerCard(margin: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    if editing != nil {
                        editingBar
                        Divider()
                    }
                    VStack(spacing: 12) {
                        if !staged.files.isEmpty || staged.copying > 0 { stagedStrip }
                        TextField(thread == nil ? "Message" : "Reply", text: typedDraft, axis: .vertical)
                            .lineLimit(1...8)
                            .focused($isFocused)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                            .padding(.vertical, 4)
                        actionRow
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .onChange(of: editing?.id) { _, id in
            if id != nil {
                if thread == nil { room.setTyping(false) }
                isFocused = true
            }
        }
        .task {
            guard focusesOnAppear else { return }
            // A beat for the push to land; focus asked for mid-transition is dropped.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            isFocused = true
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
        .animation(.easeInOut(duration: 0.2), value: editing?.id)
        .animation(.easeInOut(duration: 0.2), value: staged.files.map(\.id))
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
            // Room for the remove buttons, which stand out past each file's corner.
            .padding(.top, 9)
            .padding(.trailing, 9)
        }
        .scrollIndicators(.hidden)
        .frame(height: 72)
    }

    /// Under the field, so the text gets the card's full width: what goes with the message at the
    /// start, Send at the end.
    private var actionRow: some View {
        HStack(spacing: 12) {
            attachMenu
            if let thread { alsoSendToggle(thread) }
            Spacer(minLength: 0)
            Button(action: send) {
                SendGlyph(isEnabled: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
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
                .padding(-8)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
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
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Button("Cancel", action: cancelEditing)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func send() {
        guard canSend else { return }
        if let editing {
            // Only what the edit touched changes; the rest of the body keeps its formatting.
            guard let body = editing.body(for: draft) else { return }
            // Refused (not connected), the edit stays in the field to try again; the screen's
            // alert says why.
            guard room.edit(editing.id, body: body) else { return }
            self.editing = nil
            draft = ""
            isFocused = true
            return
        }
        let message = Self.outgoing(draft)
        if !staged.files.isEmpty {
            let files = staged.takeAll()
            let sources = files.map(\.source)
            let ids: [String]
            if let thread {
                ids = thread.send(files: sources, body: message?.body, plainText: message?.plainText, alsoSend: alsoSend)
            } else {
                ids = room.send(files: sources, body: message?.body, plainText: message?.plainText)
            }
            for (id, thumbnail) in Self.thumbnails(ids: ids, files: files) {
                StagedThumbnails.shared.set(thumbnail, for: id)
            }
            sent()
        } else if let message {
            if let thread {
                thread.reply(body: message.body, plainText: message.plainText, alsoSend: alsoSend)
            } else {
                room.send(body: message.body, plainText: message.plainText)
            }
            sent()
        }
        draft = ""
        // Kept up for the next message, as a chat's composer stays open after a send.
        isFocused = true
    }

    private func sent() {
        if thread == nil { room.setTyping(false) }
        // Off again after every send, as the web's is.
        alsoSend = false
        onSend()
    }

    private func cancelEditing() {
        editing = nil
        draft = ""
    }

    /// What Send sends for `draft`, or nil when it's blank. As the web's composer does, blank
    /// (nothing but white space) sends no text, and anything else goes as typed, leading and
    /// trailing spaces and blank lines kept; the plain text is the server's for that body, which
    /// drops the newlines it ends with (body.ts `preparePlainParagraph`).
    static func outgoing(_ draft: String) -> (body: String, plainText: String)? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Lines split as `body(fromPlainText:)` splits them, so `\r\n` and `\r` read as one break.
        var lines = draft.replacing("\r\n", with: "\n").replacing("\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return (RichText.body(fromPlainText: draft), lines.joined(separator: "\n"))
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
        staged.stage({ try await item.loadTransferable(type: PickedFile.self)?.url }, refuse: refuse)
    }

    private func stageFile(_ url: URL) {
        staged.stage({ try Staging.copied(url, isScoped: true) }, refuse: refuse)
    }

    private func refuse(_ error: Error) {
        let notice: String
        if case .tooLarge(let name) = error as? Staging.Refusal {
            notice = Uploads.tooLarge(name)
        } else {
            notice = "That file can’t be read."
        }
        if let thread { thread.notice = notice } else { room.notice = notice }
    }
}

/// A staged file in the composer's strip: its picture, or its symbol and name.
private struct StagedFileView: View {
    let file: StagedFile
    let remove: () -> Void

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
            }
            .buttonStyle(.plain)
            .offset(x: 9, y: -9)
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
