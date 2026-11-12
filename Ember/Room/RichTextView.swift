import SwiftUI
import EmberSDK
import EmberRichText

/// A message body drawn natively from its document: paragraphs and headings as text, code in a
/// box that scrolls sideways, quotes with a bar, lists, tables, rules and link previews.
struct RichTextView: View {
    let document: RichDocument

    var body: some View {
        if document.isEmojiOnly {
            // As the web shows a message of only emoji: large, and nothing else to style.
            RichBlocks(blocks: document.blocks, depth: 0, indents: 0)
                .font(.largeTitle)
        } else {
            RichBlocks(blocks: document.blocks, depth: 0, indents: 0)
        }
    }
}

/// How many quotes and lists in, at most, a message's text is indented; deeper ones go no further
/// in, so text nested any deeper still has the width to be read.
enum RichIndent {
    static let maxLevels = 4

    /// An item's blocks with `marker` leading its first paragraph, or on a line of its own above
    /// them when they don't start with one. An item that starts with a list of its own takes no
    /// marker, as that list's first item has one, so lists nested many deep don't stack a line of
    /// markers each.
    static func marked(_ item: [RichBlock], with marker: String) -> [RichBlock] {
        let lead = RichInline.text(marker + " ", [])
        switch item.first {
        case let .paragraph(inlines): return [.paragraph([lead] + inlines)] + item.dropFirst()
        case .list: return item
        default: return [.paragraph([lead])] + item
        }
    }
}

private struct RichBlocks: View {
    let blocks: [RichBlock]
    /// How deep in lists this is, which picks the bullet.
    let depth: Int
    /// How many quotes and lists in this is.
    let indents: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block, depth: depth, indents: indents)
            }
        }
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let depth: Int
    let indents: Int

    /// Whether this is as far in as text goes.
    private var isAtMostIndent: Bool { indents >= RichIndent.maxLevels }

    @ScaledMetric(relativeTo: .body) private var quoteBar: CGFloat = 3

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            InlineText(inlines: inlines)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let inlines):
            InlineText(inlines: inlines)
                .font(Self.headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.callout.monospaced())
                    .fixedSize()
                    .padding(10)
            }
            .scrollIndicators(.hidden)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))

        case .quote(let blocks):
            if isAtMostIndent {
                RichBlocks(blocks: blocks, depth: depth, indents: indents + 1)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: quoteBar)
                    RichBlocks(blocks: blocks, depth: depth, indents: indents + 1)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let marker = ordered ? "\((start ?? 1) &+ index)." : Self.bullet(depth)
                    if isAtMostIndent {
                        // The marker in the item's first line instead of beside it.
                        RichBlocks(blocks: RichIndent.marked(item, with: marker), depth: depth + 1, indents: indents + 1)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            RichBlocks(blocks: item, depth: depth + 1, indents: indents + 1)
                        }
                    }
                }
            }

        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    if let header {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                                InlineText(inlines: cell).bold()
                            }
                        }
                        Divider()
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                InlineText(inlines: cell)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))

        case .rule:
            Divider()
                .padding(.vertical, 4)

        case .preview(let preview):
            LinkPreviewCard(preview: preview)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    private static func bullet(_ depth: Int) -> String {
        ["•", "◦", "▪"][depth % 3]
    }
}

/// A run of inline text: styles through `AttributedString`, links that open, and mentions by the
/// person's current name, with @ember's single sparkle after its name.
struct InlineText: View {
    let inlines: [RichInline]

    @Environment(Workspace.self) private var workspace

    var body: some View {
        InlineBuilder(workspace: workspace).text(inlines)
    }
}

/// Places a long address or other unbroken run may wrap without the text system cutting a word
/// with a hyphen: after the marks an address divides at, and every `run` characters between them.
enum TextBreaks {
    static let run = 10
    /// Words shorter than this are left alone.
    static let minimum = 24
    static let opportunity: Character = "\u{200B}"

    static func breakable(_ string: String) -> String {
        guard string.count >= minimum else { return string }
        var result = ""
        result.reserveCapacity(string.utf8.count + string.utf8.count / 8)
        var word = ""
        for character in string {
            if character.isWhitespace {
                result += broken(word)
                result.append(character)
                word = ""
            } else {
                word.append(character)
            }
        }
        result += broken(word)
        return result
    }

    private static func broken(_ word: String) -> String {
        guard word.count >= minimum else { return word }
        let characters = Array(word)
        var result = ""
        var unbroken = 0
        for (index, character) in characters.enumerated() {
            result.append(character)
            unbroken += 1
            guard index + 1 < characters.count else { break }
            // After a run of marks, as "://", rather than inside it.
            if (isMark(character) && !isMark(characters[index + 1])) || unbroken >= run {
                result.append(opportunity)
                unbroken = 0
            }
        }
        return result
    }

    private static func isMark(_ character: Character) -> Bool {
        "/?&=#.-_~:+,;@".contains(character)
    }
}

@MainActor private struct InlineBuilder {
    let workspace: Workspace

    func text(_ inlines: [RichInline]) -> Text {
        var pieces = Pieces()
        append(inlines, link: nil, into: &pieces)
        return pieces.text
    }

    /// Text built in runs: styled characters gather into one `AttributedString` until a symbol
    /// has to go in, which only a `Text` can carry.
    private struct Pieces {
        var done: Text?
        var run = AttributedString()

        mutating func flush() {
            guard !run.characters.isEmpty else { return }
            let next = Text(run)
            done = done.map { Text("\($0)\(next)") } ?? next
            run = AttributedString()
        }

        mutating func append(_ text: Text) {
            flush()
            done = done.map { Text("\($0)\(text)") } ?? text
        }

        var text: Text {
            var copy = self
            copy.flush()
            return copy.done ?? Text(verbatim: "")
        }
    }

    private func append(_ inlines: [RichInline], link: URL?, into pieces: inout Pieces) {
        for inline in inlines {
            switch inline {
            case .text(let string, let style):
                var run = AttributedString(TextBreaks.breakable(string))
                apply(style, to: &run)
                if let link { run.link = link }
                pieces.run += run

            case .link(let href, let children):
                append(children, link: workspace.client.url(href) ?? link, into: &pieces)

            case .mention(let userID):
                let name = workspace.name(ofUserID: userID)
                var run = AttributedString("@" + (name ?? "…"))
                if name != nil {
                    run.inlinePresentationIntent = .stronglyEmphasized
                    run.foregroundColor = .accentColor
                }
                pieces.run += run
                if workspace.isAssistant(userID) {
                    pieces.run += AttributedString("\u{00A0}")
                    pieces.append(Text(Image(systemName: "sparkle")).foregroundStyle(.tint))
                }

            case .lineBreak:
                pieces.run += AttributedString("\n")
            }
        }
    }

    private func apply(_ style: RichStyle, to run: inout AttributedString) {
        var intent: InlinePresentationIntent = []
        if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if style.contains(.italic) { intent.insert(.emphasized) }
        if style.contains(.strikethrough) { intent.insert(.strikethrough) }
        if style.contains(.code) { intent.insert(.code) }
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if style.contains(.underline) { run.underlineStyle = .single }
        if style.contains(.code) { run.backgroundColor = Color(.secondarySystemFill) }
        if style.contains(.highlight) { run.backgroundColor = Color.yellow.opacity(0.35) }
        if style.contains(.superscript) {
            run.baselineOffset = 6
            run.font = .caption
        } else if style.contains(.subscript) {
            run.baselineOffset = -3
            run.font = .caption
        }
    }
}

/// A link's preview, small: its picture, title and a line or two of description.
private struct LinkPreviewCard: View {
    let preview: RichPreview

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 56

    var body: some View {
        let url = preview.href.flatMap { workspace.client.url($0) }
        Button {
            if let url { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if let image = preview.image {
                    RemoteImage(path: image, points: imageSize, retries: false)
                        .frame(width: preview.isAvatar ? imageSize * 0.7 : imageSize,
                               height: preview.isAvatar ? imageSize * 0.7 : imageSize)
                        .clipShape(preview.isAvatar ? AnyShape(AvatarView.shape(imageSize * 0.7)) : AnyShape(.rect(cornerRadius: 6)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if !preview.description.isEmpty {
                        Text(preview.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}
