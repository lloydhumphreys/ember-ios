import SwiftUI
import UIKit
import EmberSDK
import EmberRichText

/// Where a message row stands, which decides what it offers about threads.
enum MessagePlace {
    /// In a room: its thread's summary, Reply in Thread, and for a reply also sent there, what it
    /// answers.
    case room
    /// At the head of its own thread, where the replies are already under it.
    case threadParent
    /// Among a thread's replies.
    case threadReply
}

/// One message as Slack and Ember's web lay it out: the author's face and name over the first of
/// a run, and the body, attachment, boosts and thread summary beneath. At the accessibility text
/// sizes the face moves beside the name, over the body, so the name and the body have the width.
///
/// VoiceOver reads the author, time, text, boosts and replies as one element, with what the
/// context menu offers, each link in the text, and Show more as its actions. An attachment or a
/// bot's cards follow it as elements of their own.
struct MessageRow: View {
    let message: Message
    /// Follows on from the same person's message, so it goes without the face and name.
    let grouped: Bool
    let me: User?
    /// The message a link arrived at, lit for a moment.
    let isHighlighted: Bool
    /// The room's session, which edits, deletes and boosts go through wherever the row is shown.
    let session: RoomSession
    let actions: MessageActions
    var place: MessagePlace = .room

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.personPresenter) private var personPresenter
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledAvatar: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22
    /// Held by the row, so the confirmation's popover comes from the message it's about.
    @State private var isConfirmingDelete = false

    private var myID: UserID { me?.id ?? workspace.me.id }

    private var mentionsMe: Bool {
        message.mentions.contains { $0.id == myID }
    }

    /// The face over the body rather than beside it, at the accessibility text sizes.
    private var isStacked: Bool { typeSize.isAccessibilitySize }

    private var avatarSize: CGFloat { MessageRowLayout.avatarSize(scaledAvatar, isStacked: isStacked) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !isStacked { gutter }
            VStack(alignment: .leading, spacing: 4) {
                lead
                if !message.isDeleted {
                    extras
                    ChangeFailures(message: message, me: myID)
                }
                threadSummary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, grouped ? 2 : 10)
        .padding(.bottom, 2)
        .background(background)
        .opaqueContextMenuPreview()
        .overlay(alignment: .topLeading) {
            if mentionsMe, !message.isDeleted { mentionMark }
        }
        .overlay(alignment: .bottomTrailing) {
            if !message.isDeleted, SentChanges.shared.isSendingChange(to: message.id) {
                ChangeWaiting().padding(.trailing, 16).padding(.bottom, 4)
            }
        }
        // The whole width, blank space beside a short message included, both takes the long
        // press and lifts as the preview. Links, files and boost chips inside are controls of
        // their own and still take their taps first.
        .contentShape([.interaction, .contextMenuPreview], .rect)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .deleteConfirmation("Delete this message?", isPresented: $isConfirmingDelete) {
            let session = session, actions = actions, id = message.id
            SentChanges.shared.start(.delete(id), isDone: { actions.showsDeleted(id) }) {
                try await session.delete(message: id)
            }
        }
    }

    @ViewBuilder private var gutter: some View {
        if message.isDeleted {
            tombstone
        } else if grouped {
            Color.clear.frame(width: avatarSize, height: 1)
        } else {
            avatar
        }
    }

    /// The author's face, which shows them when tapped, where something can.
    @ViewBuilder private var avatar: some View {
        let name = workspace.name(of: message.creator)
        let face = AvatarView(userID: message.creator.id, name: name, size: avatarSize)
        if let personPresenter {
            Button { personPresenter.show(message.creator.id) } label: { face }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
        } else {
            face
        }
    }

    /// The author's name over the message, which shows them when tapped, as the face does.
    @ViewBuilder private func authorName(_ title: MessageHeaderTitle) -> some View {
        if let personPresenter {
            Button { personPresenter.show(message.creator.id) } label: { title }
                .buttonStyle(.plain)
        } else {
            title
        }
    }

    /// A blank square where the face was, as the web leaves a deleted message.
    private var tombstone: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .frame(width: avatarSize, height: avatarSize)
            .accessibilityHidden(true)
    }

    /// A mention of you: a bar down the leading edge and an @ beside it, so it isn't told by
    /// colour alone. Held to a small size so it stays in the margin.
    private var mentionMark: some View {
        HStack(alignment: .top, spacing: 1) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3)
            Image(systemName: "at")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tint)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .padding(.top, grouped ? 4 : 12)
        }
        .accessibilityHidden(true)
    }

    /// Who, when, and what: the one element VoiceOver reads for the message, with the row's
    /// actions on it.
    private var lead: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.isDeleted {
                if isStacked { tombstone }
                Text("This message was deleted.")
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            } else {
                if !grouped { header }
                if place == .room, message.parentId != nil {
                    Button { actions.openThread(.to(message)) } label: {
                        ThreadQuote(text: message.parentText ?? "")
                    }
                    .buttonStyle(.plain)
                }
                messageText
                if grouped, message.editedAt != nil {
                    Text("(edited)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityActions { accessibilityActions }
    }

    @ViewBuilder private var header: some View {
        let name = workspace.name(of: message.creator)
        let title = MessageHeaderTitle(name: name, isAssistant: workspace.isAssistant(message.creator.id))
        if isStacked {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    avatar
                    authorName(title)
                }
                timeLine
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                authorName(title).layoutPriority(1)
                timeLine
            }
        }
    }

    private var timeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message.createdAt, format: MessageSpeech.timeFormat)
            if message.editedAt != nil {
                Text("(edited)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    @ViewBuilder private var messageText: some View {
        let document = DocumentCache.shared.document(for: message, host: host)
        switch MessageText.of(message, document: document, shownCards: shownCards) {
        case .body:
            if MessageFolds.shared.isLong(message) {
                FoldedText(messageID: message.id, document: document, fallbackLine: lineHeight, place: place)
            } else {
                MessageBody(document: document)
            }
        case .plainText: Text(message.plainText)
        case .none: EmptyView()
        }
    }

    /// What follows the text: the attachment, the cards, and the boosts.
    @ViewBuilder private var extras: some View {
        if let file = message.attachment {
            AttachmentView(file: file)
        }
        let cards = shownCards
        if !cards.isEmpty {
            CardsView(cards: cards)
        }
        if !message.boosts.isEmpty {
            let actions = actions, id = message.id
            BoostsView(message: message, me: me, session: session, customBoost: actions.customBoost) {
                actions.showsRemoved(boost: $0, from: id)
            }
            .padding(.top, 2)
            // Read with the message, and taken back through its actions.
            .accessibilityHidden(true)
        }
    }

    private var shownCards: [Card] { DocumentCache.shared.cards(for: message, host: host) }

    private var host: String { workspace.client.origin.host() ?? "" }

    @ViewBuilder private var threadSummary: some View {
        if place == .room, let thread = message.thread, thread.count > 0 {
            Button { actions.openThread(.thread(of: message)) } label: {
                ThreadSummaryView(thread: thread)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            // Read with the message, and opened through its actions.
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var background: some View {
        if isHighlighted {
            Color.yellow.opacity(0.18)
        } else if mentionsMe, !message.isDeleted {
            Color.accentColor.opacity(0.08)
        }
    }

    // MARK: VoiceOver

    private var spokenLabel: String {
        MessageSpeech.label(
            author: workspace.name(of: message.creator),
            isAssistant: workspace.isAssistant(message.creator.id),
            time: message.createdAt.formatted(MessageSpeech.timeFormat),
            text: message.plainText,
            isEdited: message.editedAt != nil,
            isDeleted: message.isDeleted,
            mentionsMe: mentionsMe,
            boosts: BoostGroup.of(message.boosts, myID: myID),
            replies: place == .room ? message.thread?.count ?? 0 : 0)
    }

    @ViewBuilder private var accessibilityActions: some View {
        // At the accessibility sizes the face is inside the message's element, so the message
        // offers what tapping it does.
        if isStacked, !grouped, !message.isDeleted, let personPresenter {
            Button(workspace.name(of: message.creator)) { personPresenter.show(message.creator.id) }
        }
        if !message.isDeleted {
            let document = DocumentCache.shared.document(for: message, host: host)
            ForEach(Array(MessageSpeech.links(in: document).enumerated()), id: \.offset) { _, link in
                if let url = workspace.client.url(link.url) {
                    Button("Open \(link.text)") { openURL(url) }
                }
            }
            if MessageFolds.shared.isLong(message) {
                Button(MessageFold.buttonTitle(isOpen: MessageFolds.shared.isOpen(message.id, in: place))) {
                    MessageFolds.shared.toggle(message.id, in: place)
                }
            }
        }
        if place == .room, let thread = message.thread, thread.count > 0 {
            Button("Open Thread") { actions.openThread(.thread(of: message)) }
        } else if place == .room, message.parentId != nil, !message.isDeleted {
            Button("Open Thread") { actions.openThread(.to(message)) }
        }
        if message.isDeleted {
            if place == .room { replyInThread }
        } else {
            if place == .room { replyInThread }
            Button("React") { actions.customBoost(message) }
            ForEach(BoostGroup.of(message.boosts, myID: myID).compactMap(\.mine)) { mine in
                Button("Remove Reaction \(mine.content)") {
                    let session = session, actions = actions, id = message.id
                    SentChanges.shared.start(.removeBoost(id, mine.id), isDone: { actions.showsRemoved(boost: mine.id, from: id) }) {
                        try await session.removeBoost(id: mine.id)
                    }
                }
            }
            editingActions
        }
    }

    // MARK: Menu

    @ViewBuilder private var menu: some View {
        if message.isDeleted {
            // A tombstone keeps its thread, and can still be replied to.
            if place == .room { replyInThread }
        } else {
            liveMenu
        }
    }

    private var replyInThread: some View {
        Button("Reply in Thread", systemImage: "bubble.left.and.bubble.right") {
            actions.openThread(.thread(of: message))
        }
    }

    @ViewBuilder private var liveMenu: some View {
        ReactionRow(reactions: BoostChoices.quick, message: message, session: session)
        if place == .room { replyInThread }
        Menu("React", systemImage: "face.smiling") {
            BoostChoices(message: message, session: session, customBoost: actions.customBoost)
        }
        editingActions
    }

    @ViewBuilder private var editingActions: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.plainText
        }
        .disabled(message.plainText.isEmpty)
        Button("Select Text", systemImage: "selection.pin.in.out") {
            actions.selectText(message.plainText)
        }
        .disabled(message.plainText.isEmpty)
        let changes = MessageChanges.of(message, myID: myID, isAdministrator: workspace.me.administrator)
        if changes.canEdit {
            Button("Edit", systemImage: "pencil") { actions.edit(message) }
        }
        if changes.canDelete {
            Button("Delete", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                .disabled(SentChanges.shared.isSending(.delete(message.id)))
        }
    }
}

/// Sizes a message row takes from the text size.
enum MessageRowLayout {
    /// The largest a face grows, at the accessibility text sizes, where it sits beside the name.
    static let largestStackedAvatar: CGFloat = 48

    static func avatarSize(_ scaled: CGFloat, isStacked: Bool) -> CGFloat {
        isStacked ? min(scaled, largestStackedAvatar) : scaled
    }
}

/// The author's name, and the assistant's sparkle after it, as one text that wraps rather than
/// being cut.
private struct MessageHeaderTitle: View {
    let name: String
    let isAssistant: Bool

    var body: some View {
        Group {
            if isAssistant {
                Text("\(Text(name)) \(Text(Image(systemName: "sparkle")).font(.caption).foregroundStyle(.tint))")
            } else {
                Text(name)
            }
        }
        .font(.subheadline.weight(.bold))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A message's text. Only emoji shows large, as the web has it, but held below the largest
/// accessibility sizes, where the large title would fill the screen with a few faces.
struct MessageBody: View {
    let document: RichDocument

    /// The largest text size an emoji-only message follows.
    static let largestEmojiSize = DynamicTypeSize.accessibility1

    var body: some View {
        RichTextView(document: document)
            .dynamicTypeSize(...(document.isEmojiOnly ? Self.largestEmojiSize : .accessibility5))
    }
}

extension EnvironmentValues {
    /// Whether long messages keep the fold they had, whatever's asked for meanwhile: while the
    /// timeline is off screen, behind a thread pushed over it. A row whose height changes there
    /// leaves the timeline's height where the old one put it, with nothing past the last row; the
    /// fold made meanwhile is taken up once the timeline is back on screen.
    @Entry var holdsFolds = false
}

/// A long message's text: its first lines whole behind Show more, all of it behind Show less.
/// Open or folded is kept in `MessageFolds`, so it survives the row being made again. The fold is
/// measured from the text's lines as it's laid out, and the measurement is state here, so the row
/// is laid out again at it before it's drawn rather than drawn at a guess.
private struct FoldedText: View {
    let messageID: MessageID
    let document: RichDocument
    /// One line's height, for the fold before the text is measured.
    let fallbackLine: CGFloat
    var place: MessagePlace = .room

    /// Where the fold falls in this row's text, once measured.
    @State private var measured: CGFloat?
    /// Open or folded as it was when the timeline went off screen (see `holdsFolds`).
    @State private var heldOpen: Bool?
    @Environment(\.holdsFolds) private var holdsFolds

    var body: some View {
        let folds = MessageFolds.shared
        let isOpen = heldOpen ?? folds.isOpen(messageID, in: place)
        VStack(alignment: .leading, spacing: 2) {
            // Laid out whole at its own height whatever it's offered, so its lines are where
            // they'll be drawn, then cut under the last line shown.
            MessageBody(document: document)
                .fixedSize(horizontal: false, vertical: true)
                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        Color.clear.onChange(of: Self.foldHeight(layouts, in: proxy), initial: true) { _, height in
                            guard let height else { return }
                            folds.setFoldHeight(height, for: messageID)
                            if measured.map({ abs($0 - height) >= 0.5 }) ?? true { measured = height }
                        }
                    }
                }
                .frame(height: isOpen ? nil : foldHeight(folds), alignment: .top)
                .clipped()
            Button(MessageFold.buttonTitle(isOpen: isOpen)) { folds.toggle(messageID, in: place) }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { y in
            folds.setTop(y, for: messageID, in: place)
        }
        .onDisappear { folds.setTop(nil, for: messageID, in: place) }
        .onChange(of: holdsFolds, initial: true) { _, holds in
            heldOpen = holds ? folds.isOpen(messageID, in: place) : nil
        }
    }

    /// As measured in this row, else as last measured in another, else ten lines' guess.
    private func foldHeight(_ folds: MessageFolds) -> CGFloat {
        measured ?? folds.foldHeight(messageID) ?? fallbackLine * CGFloat(MessageFold.shownLines)
    }

    /// Where the fold cuts, from every line of every text view in the message's text.
    private static func foldHeight(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> CGFloat? {
        var spans: [ClosedRange<CGFloat>] = []
        for text in layouts {
            let top = proxy[text.origin].y
            for line in text.layout {
                let bounds = line.typographicBounds.rect
                spans.append((top + bounds.minY)...(top + bounds.maxY))
            }
        }
        return CardFold.height(lineSpans: spans, lines: MessageFold.shownLines)
    }
}

/// What VoiceOver says for a message row, and the links it offers as actions.
enum MessageSpeech {
    static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    /// Who and when, whether it mentions you, the text, then its boosts and replies.
    static func label(
        author: String, isAssistant: Bool, time: String, text: String, isEdited: Bool, isDeleted: Bool,
        mentionsMe: Bool, boosts: [BoostGroup], replies: Int
    ) -> String {
        var parts: [String] = []
        if isDeleted {
            parts.append("This message was deleted.")
        } else {
            parts.append("\(author)\(isAssistant ? ", assistant" : ""), \(time).")
            if mentionsMe { parts.append("Mentions you.") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(sentence(trimmed)) }
            if isEdited { parts.append("Edited.") }
            if !boosts.isEmpty {
                parts.append("Reactions: " + boosts.map(\.spoken).joined(separator: "; ") + ".")
            }
        }
        if replies > 0 { parts.append(replies == 1 ? "1 reply." : "\(replies) replies.") }
        return parts.joined(separator: " ")
    }

    /// Text ending as a sentence, so VoiceOver pauses before what follows.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…:".contains(last) else { return text }
        return text + "."
    }

    /// Each link in a message's text, with what it says, in reading order.
    static func links(in document: RichDocument) -> [(url: String, text: String)] {
        var found: [(url: String, text: String)] = []
        func inlines(_ items: [RichInline]) {
            for item in items {
                if case .link(let url, let children) = item {
                    let text = plain(children).trimmingCharacters(in: .whitespacesAndNewlines)
                    found.append((url, text.isEmpty ? url : text))
                }
            }
        }
        func blocks(_ items: [RichBlock]) {
            for block in items {
                switch block {
                case .paragraph(let items), .heading(_, let items): inlines(items)
                case .quote(let children): blocks(children)
                case .list(_, _, let items): items.forEach(blocks)
                case .table(let header, let rows):
                    header?.forEach(inlines)
                    rows.forEach { $0.forEach(inlines) }
                case .preview(let preview):
                    if let href = preview.href { found.append((href, preview.title.isEmpty ? href : preview.title)) }
                case .codeBlock, .rule: break
                }
            }
        }
        blocks(document.blocks)
        return found
    }

    private static func plain(_ items: [RichInline]) -> String {
        items.map { item in
            switch item {
            case .text(let text, _): text
            case .link(_, let children): plain(children)
            case .mention: ""
            case .lineBreak: " "
            }
        }
        .joined()
    }
}

/// What a reply also sent to the room answers: the start of its parent's text, as the room has it.
private struct ThreadQuote: View {
    /// Empty when the parent was deleted.
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(text.isEmpty ? "This message was deleted." : text)
                .italic(text.isEmpty)
                .lineLimit(1)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// How many replies a message's thread has and when the last came; tapping it opens the thread.
private struct ThreadSummaryView: View {
    let thread: ThreadSummary

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .footnote) private var faceSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -4) {
                ForEach(thread.people.prefix(3)) { person in
                    AvatarView(userID: person.id, name: workspace.name(of: person), size: faceSize)
                        .overlay(AvatarView.shape(faceSize).strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                }
            }
            Text("^[\(thread.count) reply](inflect: true)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            RelativeTimeText(thread.latestAt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A message on its way: dimmed until the room has it, however long the connection is down, and
/// with its failure, Retry and Discard when the room refused it or never answered on an open
/// connection. A file shows its picture or row with how far it's got.
struct PendingRow: View {
    let pending: PendingMessage
    let grouped: Bool
    let me: User?
    /// The room's or the thread's, whichever sent it.
    let retry: (ClientMessageID) -> Void
    let discard: (ClientMessageID) -> Void

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36
    @State private var isConfirmingDiscard = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if grouped {
                Color.clear.frame(width: avatarSize, height: 1)
            } else {
                AvatarView(userID: myID, name: myName, size: avatarSize)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !grouped {
                    Text(myName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                }
                if let upload = pending.upload {
                    PendingUploadView(
                        upload: upload, isFailed: pending.failure != nil,
                        thumbnail: StagedThumbnails.shared.image(for: pending.clientMessageId))
                } else {
                    let document = DocumentCache.shared.document(for: pending, host: workspace.client.origin.host() ?? "")
                    RichTextView(document: document)
                        .opacity(pending.failure == nil ? 0.5 : 1)
                }
                if let failure = pending.failure {
                    HStack(spacing: 12) {
                        Label(Self.failureText(failure), systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Retry") { retry(pending.clientMessageId) }
                            .font(.footnote.weight(.semibold))
                        Button("Discard", role: .destructive) { isConfirmingDiscard = true }
                            .font(.footnote.weight(.semibold))
                            // On the button, so the popover points at what it's confirming.
                            .confirmationDialog("Discard this message?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                                Button("Discard", role: .destructive) { discard(pending.clientMessageId) }
                            }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, grouped ? 2 : 10)
        .padding(.bottom, 2)
        .announcesWhenShown(pending.failure.map(Self.failureText))
        .opaqueContextMenuPreview()
        .contentShape([.interaction, .contextMenuPreview], .rect)
        .contextMenu {
            // A file's plain text is only its name.
            if pending.upload == nil {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = pending.plainText
                }
            }
        }
    }

    private var myID: UserID { me?.id ?? workspace.me.id }
    private var myName: String { workspace.name(ofUserID: myID) ?? me?.name ?? workspace.me.name }

    /// What a failed message says before Retry and Discard: the room's refusal as it worded it, or,
    /// for one the room never answered, as short as a failed file's "Upload failed".
    static func failureText(_ failure: String) -> String {
        failure == RoomSession.notSent ? "Not sent" : failure
    }
}

/// A message's text in a sheet where any part of it can be selected, which a `Text` in a list
/// can't offer.
struct SelectTextSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.text = text
    }
}
