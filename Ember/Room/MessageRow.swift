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
/// a run, and the body, attachment, boosts and thread summary beneath.
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
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36
    /// Held by the row, so the confirmation's popover comes from the message it's about.
    @State private var isConfirmingDelete = false

    private var mentionsMe: Bool {
        let myID = me?.id ?? workspace.me.id
        return message.mentions.contains { $0.id == myID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            gutter
            VStack(alignment: .leading, spacing: 4) {
                if !grouped || message.isDeleted { header }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.top, grouped ? 2 : 10)
        .padding(.bottom, 2)
        .background(background)
        .overlay(alignment: .leading) {
            if mentionsMe, !message.isDeleted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        // The whole width, blank space beside a short message included, both takes the long
        // press and lifts as the preview. Links, files and boost chips inside are controls of
        // their own and still take their taps first.
        .contentShape([.interaction, .contextMenuPreview], .rect)
        .contextMenu { menu }
        .deleteConfirmation("Delete this message?", isPresented: $isConfirmingDelete) {
            session.delete(message.id)
        }
    }

    @ViewBuilder private var gutter: some View {
        if message.isDeleted {
            // A blank square where the face was, as the web leaves a deleted message.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemFill))
                .frame(width: avatarSize, height: avatarSize)
        } else if grouped {
            Color.clear.frame(width: avatarSize, height: 1)
        } else {
            AvatarView(userID: message.creator.id, name: workspace.name(of: message.creator), size: avatarSize)
        }
    }

    @ViewBuilder private var header: some View {
        if !message.isDeleted {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 3) {
                    Text(workspace.name(of: message.creator))
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    if workspace.isAssistant(message.creator.id) {
                        Image(systemName: "sparkle")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                }
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if message.editedAt != nil {
                    Text("(edited)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var content: some View {
        if message.isDeleted {
            Text("This message was deleted.")
                .font(.body.italic())
                .foregroundStyle(.secondary)
            threadSummary
        } else {
            if place == .room, message.parentId != nil {
                Button { actions.openThread(.to(message)) } label: {
                    ThreadQuote(text: message.parentText ?? "")
                }
                .buttonStyle(.plain)
            }
            let host = self.host
            let cards = DocumentCache.shared.cards(for: message, host: host)
            let document = DocumentCache.shared.document(for: message, host: host)
            switch MessageText.of(message, document: document, shownCards: cards) {
            case .body: RichTextView(document: document)
            case .plainText: Text(message.plainText)
            case .none: EmptyView()
            }
            if grouped, message.editedAt != nil {
                Text("(edited)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let file = message.attachment {
                AttachmentView(file: file)
            }
            if !cards.isEmpty {
                CardsView(cards: cards)
            }
            if !message.boosts.isEmpty {
                BoostsView(message: message, me: me, session: session, customBoost: actions.customBoost)
                    .padding(.top, 2)
            }
            threadSummary
        }
    }

    private var host: String { workspace.client.origin.host() ?? "" }

    @ViewBuilder private var threadSummary: some View {
        if place == .room, let thread = message.thread, thread.count > 0 {
            Button { actions.openThread(.thread(of: message)) } label: {
                ThreadSummaryView(thread: thread)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var background: some View {
        if isHighlighted {
            Color.yellow.opacity(0.18)
        } else if mentionsMe, !message.isDeleted {
            Color.accentColor.opacity(0.08)
        }
    }

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
        if place == .room { replyInThread }
        Menu("Boost", systemImage: "face.smiling") {
            BoostChoices(message: message, session: session, customBoost: actions.customBoost)
        }
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = message.plainText
        }
        .disabled(message.plainText.isEmpty)
        Button("Select Text", systemImage: "selection.pin.in.out") {
            actions.selectText(message.plainText)
        }
        .disabled(message.plainText.isEmpty)
        let changes = MessageChanges.of(message, myID: me?.id ?? workspace.me.id, isAdministrator: workspace.me.administrator)
        if changes.canEdit {
            Button("Edit", systemImage: "pencil") { actions.edit(message) }
        }
        if changes.canDelete {
            Button("Delete", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
        }
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
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
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

/// A message on its way: dimmed until the room has it, and with its failure, Retry and Discard
/// when the room refused it. A file shows its picture or row with how far it's got.
struct PendingRow: View {
    let pending: PendingMessage
    let grouped: Bool
    let me: User?
    /// The room's or the thread's, whichever sent it.
    let retry: (String) -> Void
    let discard: (String) -> Void

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
                        Label(failure, systemImage: "exclamationmark.circle")
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
