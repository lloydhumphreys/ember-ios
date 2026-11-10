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
            RichBlocks(blocks: document.blocks, depth: 0)
                .font(.largeTitle)
        } else {
            RichBlocks(blocks: document.blocks, depth: 0)
        }
    }
}

private struct RichBlocks: View {
    let blocks: [RichBlock]
    /// How deep in lists this is, which picks the bullet.
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block, depth: depth)
            }
        }
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let depth: Int

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
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(.tertiary)
                    .frame(width: quoteBar)
                RichBlocks(blocks: blocks, depth: depth)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\((start ?? 1) + index)." : Self.bullet(depth))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        RichBlocks(blocks: item, depth: depth + 1)
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
                var run = AttributedString(string)
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
                    RemoteImage(path: image, points: imageSize)
                        .frame(width: preview.isAvatar ? imageSize * 0.7 : imageSize,
                               height: preview.isAvatar ? imageSize * 0.7 : imageSize)
                        .clipShape(preview.isAvatar ? AnyShape(Circle()) : AnyShape(.rect(cornerRadius: 6)))
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
