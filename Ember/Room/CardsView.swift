import SwiftUI
import EmberSDK
import EmberRichText

// A bot's cards, as the web's `bot-card.tsx` draws them, in SF type and system colours. Every card
// here has been through `DocumentCache.cards(for:host:)`, so each image, icon, link and button
// address in it has passed the card address rule; `CardImages` checks an image's again, and each of
// its redirects. A card's rich text is a message's, with links of their own, and every link here,
// as everywhere, reaches the system only through the app's `OpenURLAction` (`RootView`), which opens
// just what `LinkPolicy` allows.

extension EnvironmentValues {
    /// Whether the card being drawn is 400 points wide or less.
    @Entry var cardIsNarrow = true
}

/// A message's cards, one under another.
struct CardsView: View {
    let cards: [Card]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                CardView(card: card)
            }
        }
        .padding(.top, 4)
    }
}

/// A card: an attachment's pretext over a frame, with a bar down an attachment's leading side in its
/// colour, holding its parts and an attachment's thumbnail at the trailing side, or over the parts at
/// accessibility text sizes, where a column beside it would be too narrow to read.
private struct CardView: View {
    let card: Card

    @Environment(\.pixelLength) private var pixelLength
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isNarrow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pretext = card.pretext {
                CardRichText(html: pretext)
            }
            if !card.parts.isEmpty || card.thumb != nil {
                frame
            }
        }
        .frame(maxWidth: 608, alignment: .leading)
    }

    private var frame: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let bar = CardBar.of(card)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    if let thumb = card.thumb { CardThumb(image: thumb) }
                    parts
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    parts
                    if let thumb = card.thumb { CardThumb(image: thumb) }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, bar == nil ? 12 : 16)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if let bar {
                Self.color(bar).frame(width: 4).accessibilityHidden(true)
            }
        }
        .background(Color(.systemBackground))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(.separator), lineWidth: max(pixelLength, 0.5)))
        .onGeometryChange(for: Bool.self) { CardWidth.isNarrow($0.size.width) } action: { isNarrow = $0 }
        .environment(\.cardIsNarrow, isNarrow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.label.map { Text($0) } ?? Text(verbatim: ""))
    }

    /// The parts one under another, each at its own height for the width it's given. A stack with
    /// a thumbnail beside this column proposes it the stack's height on placing it, and a VStack
    /// given a height shares it out rather than giving each part what it measured, so a title or
    /// a caption would lose lines to an ellipsis.
    private var parts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.parts.enumerated()), id: \.offset) { _, part in
                CardPartView(part: part)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func color(_ bar: CardBar) -> Color {
        switch bar {
        case .separator: Color(.separator)
        case .green: .green
        case .orange: .orange
        case .red: .red
        case let .rgb(red, green, blue): Color(red: red, green: green, blue: blue)
        }
    }
}

private struct CardPartView: View {
    let part: CardPart

    var body: some View {
        switch part {
        case let .author(name, href, icon):
            HStack(spacing: 5) {
                if let icon { CardIcon(url: icon, size: 16) }
                CardLink(href: href) { Text(name).fixedSize(horizontal: false, vertical: true) }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)

        case let .title(text, href):
            CardLink(href: href) {
                Text(text)
                    .foregroundStyle(href == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

        case let .header(text):
            Text(text)
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

        case let .text(html):
            CardRichText(html: html, folds: true)

        case let .section(html, fields, thumb, button):
            CardSection(html: html, fields: fields, thumb: thumb, button: button)

        case let .fields(fields):
            CardFields(fields: fields)

        case let .image(image, title):
            CardImagePart(image: image, title: title)

        case let .context(items):
            CardContext(items: items)

        case .divider:
            Divider().padding(.vertical, 4)

        case let .buttons(buttons):
            CardButtons(buttons: buttons)
                .padding(.top, 4)

        case let .table(rows, columns):
            CardTable(rows: rows, columns: columns)

        case let .tiles(tiles):
            CardTiles(tiles: tiles)

        case let .footer(text, icon, at):
            HStack(spacing: 5) {
                if let icon { CardIcon(url: icon, size: 16) }
                Text(CardFooterText.text(text, at: at))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Text

/// A card's rich text, as a message's text shows, or small and secondary where it's `small`. Where it
/// `folds`, long text shows its first five lines whole behind Show more.
struct CardRichText: View {
    let html: String
    var folds = false
    var small = false

    @Environment(Workspace.self) private var workspace
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 22
    @State private var isOpen = false
    /// Where the fifth line ends, read from the laid-out text.
    @State private var foldHeight: CGFloat?

    var body: some View {
        let text = DocumentCache.shared.cardText(html: html, host: workspace.client.origin.host() ?? "")
        let fold = CardFold(isLong: folds && text.isLong, isOpen: isOpen)
        VStack(alignment: .leading, spacing: 2) {
            if fold.isLong {
                // Laid out whole at its own height whatever it's offered, so its lines are where
                // they'll be drawn, then cut under the fifth of them.
                RichTextView(document: text.document)
                    .font(small ? .caption : .body)
                    .foregroundStyle(small ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                    .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                        GeometryReader { proxy in
                            Color.clear.onChange(of: Self.foldHeight(layouts, in: proxy), initial: true) { _, height in
                                foldHeight = height
                            }
                        }
                    }
                    .frame(height: fold.isClipped ? foldHeight ?? lineHeight * CGFloat(CardFold.shownLines) : nil, alignment: .top)
                    .clipped()
            } else {
                RichTextView(document: text.document)
                    .font(small ? .caption : .body)
                    .foregroundStyle(small ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            if let title = fold.buttonTitle {
                Button(title) { isOpen.toggle() }
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
            }
        }
    }

    /// Where the fold cuts, from every line of every text view in the rich text.
    private static func foldHeight(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> CGFloat? {
        var spans: [ClosedRange<CGFloat>] = []
        for text in layouts {
            let top = proxy[text.origin].y
            for line in text.layout {
                let bounds = line.typographicBounds.rect
                spans.append((top + bounds.minY)...(top + bounds.maxY))
            }
        }
        return CardFold.height(lineSpans: spans)
    }
}

/// Text linked to `href` when the card may link there; plain otherwise.
private struct CardLink<Label: View>: View {
    let href: String?
    @ViewBuilder let label: () -> Label

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let href, let url = URL(string: href) {
            Button { openURL(url) } label: {
                label().multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits(.isLink)
        } else {
            label()
        }
    }
}

// MARK: - Images

/// An author's or a footer's icon, or a context row's image: small, and drawn only once it's loaded.
private struct CardIcon: View {
    let url: String
    let size: CGFloat
    /// What it shows, for VoiceOver; nil for an icon that says nothing its text doesn't.
    var alt: String? = nil

    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        let side = size * scale
        CardImageView(url: url, points: side, placeholder: false)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(alt?.isEmpty ?? true)
            .accessibilityLabel(alt ?? "")
            .accessibilityAddTraits(.isImage)
    }
}

/// A 75-point thumbnail at the trailing side of a card or a section.
private struct CardThumb: View {
    let image: CardImage

    var body: some View {
        CardImageView(url: image.url, points: 75)
            .frame(width: 75, height: 75)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(image.alt.isEmpty)
            .accessibilityLabel(image.alt)
            .accessibilityAddTraits(.isImage)
    }
}

/// An image part: its caption over it, at most 360 by 500 points in its own shape, opening its
/// address when tapped.
private struct CardImagePart: View {
    let image: CardImage
    let title: String?

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: CardImages.Loaded?

    private static let maxSize = CGSize(width: 360, height: 500)
    private var maxPixel: Int { Int((Self.maxSize.height * displayScale).rounded(.up)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let url = URL(string: image.url) { openURL(url) }
            } label: {
                picture
            }
            .buttonStyle(.plain)
            .accessibilityLabel(image.alt.isEmpty ? "Image from \(URL(string: image.url)?.host() ?? "")" : image.alt)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityAddTraits([.isImage, .isLink])
        }
        .padding(.top, 4)
        .task(id: CardImages.key(image.url, maxPixel: maxPixel)) {
            guard current == nil else { return }
            loaded = await CardImages.shared.image(image.url, host: workspace.client.origin.host() ?? "", maxPixel: maxPixel)
        }
    }

    private var current: CardImages.Loaded? {
        loaded ?? CardImages.shared.cached(image.url, maxPixel: maxPixel)
    }

    @ViewBuilder private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if let current {
            // Never larger than the picture itself, as the web's image isn't.
            let limit = CGSize(width: min(Self.maxSize.width, current.pixelSize.width), height: min(Self.maxSize.height, current.pixelSize.height))
            FittedFrame(aspectRatio: current.pixelSize.width / current.pixelSize.height, limit: limit) {
                Image(uiImage: current.image)
                    .resizable()
                    .clipShape(shape)
            }
        } else {
            // Until it's here, and if it never comes: a quiet box the size most pictures are.
            FittedFrame(aspectRatio: 16 / 9, limit: Self.maxSize) {
                shape.fill(Color(.secondarySystemFill))
            }
        }
    }
}

/// Sizes its content to `aspectRatio` within the width offered and `limit`, leading-aligned.
private struct FittedFrame: Layout {
    let aspectRatio: CGFloat
    let limit: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size(for: proposal.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = size(for: bounds.width)
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(size))
        }
    }

    private func size(for offered: CGFloat?) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
        var width = min(offered ?? limit.width, limit.width)
        var height = width / aspectRatio
        if height > limit.height {
            height = limit.height
            width = height * aspectRatio
        }
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }
}

// MARK: - Section and fields

/// A section: its text over its fields, with a thumbnail or a link button at the trailing side, or
/// everything one under another in a narrow card with a button.
private struct CardSection: View {
    let html: String?
    let fields: [CardField]
    let thumb: CardImage?
    let button: CardButton?

    @Environment(\.cardIsNarrow) private var isNarrow

    var body: some View {
        if button != nil, isNarrow {
            VStack(alignment: .leading, spacing: 6) { content }
        } else {
            HStack(alignment: .top, spacing: 12) { content }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let html { CardRichText(html: html, folds: true) }
            if !fields.isEmpty { CardFields(fields: fields) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        if let thumb { CardThumb(image: thumb) }
        // Its own width first, so its label shows whole; the text beside it wraps instead.
        if let button { CardButtons(buttons: [button]).layoutPriority(1) }
    }
}

/// Fields: short ones two to a row, the rest the whole width, each title small and bold over its value;
/// one column in a narrow card.
private struct CardFields: View {
    let fields: [CardField]

    @Environment(\.cardIsNarrow) private var isNarrow

    var body: some View {
        let columns = isNarrow ? 1 : 2
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(CardFieldRows.rows(fields, columns: columns).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, field in
                        CardFieldView(field: field)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if columns > 1, row.count == 1, row[0].short {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct CardFieldView: View {
    let field: CardField

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = field.title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !field.html.isEmpty {
                CardRichText(html: field.html)
            }
        }
    }
}

// MARK: - Context and buttons

/// A context row: small secondary text and 20-point images side by side, wrapping where they must.
private struct CardContext: View {
    let items: [CardContextItem]

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case let .html(html):
                    CardRichText(html: html, small: true)
                case let .image(image):
                    CardIcon(url: image.url, size: 20, alt: image.alt)
                }
            }
        }
    }
}

/// Link buttons in a wrapping row: bordered, filled for primary, red for danger. Each shows its whole
/// label, going onto a further row where it doesn't fit beside the others; only one wider than the
/// whole row wraps inside it.
struct CardButtons: View {
    let buttons: [CardButton]
    var alignment: HorizontalAlignment = .leading
    /// Where they all fit on one row, the buttons from this index on sit at its trailing end.
    var trailingFrom: Int? = nil

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8, alignment: alignment, trailingFrom: trailingFrom) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                CardLinkButton(button: button)
            }
        }
    }
}

private struct CardLinkButton: View {
    let button: CardButton

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = URL(string: button.href) {
            let link = Button { openURL(url) } label: {
                Text(button.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .controlSize(.small)
            .accessibilityAddTraits(.isLink)
            switch button.style {
            case .primary: link.buttonStyle(.borderedProminent)
            case .danger: link.buttonStyle(.bordered).tint(.red)
            case nil: link.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Table

/// A table that scrolls sideways when it's wider than the card, every row alike: hairline-ruled
/// cells, each column as wide as its content up to 240 points, lined up as it says, and cut to one
/// line unless it wraps.
private struct CardTable: View {
    let rows: [[String]]
    let columns: [CardColumn]

    @Environment(\.pixelLength) private var pixelLength

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            CardTableCell(html: cell, column: index < columns.count ? columns[index] : CardColumn(), rule: max(pixelLength, 0.5))
                        }
                    }
                }
            }
            .padding(1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.hidden)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }
}

private struct CardTableCell: View {
    let html: String
    let column: CardColumn
    let rule: CGFloat

    var body: some View {
        CappedWidth(maxWidth: 240) {
            if !html.isEmpty {
                CardRichText(html: html)
                    .lineLimit(column.wrap ? nil : 1)
                    .multilineTextAlignment(textAlignment)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .overlay(Rectangle().stroke(Color(.separator), lineWidth: rule))
    }

    private var alignment: Alignment {
        switch column.align {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        }
    }

    private var textAlignment: TextAlignment {
        switch column.align {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// Its content at its own width, but no wider than `maxWidth`, where it wraps or truncates; even
/// where it's offered unlimited width, as a sideways scroll offers it.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(subview.sizeThatFits(.unspecified).width, maxWidth, proposal.width ?? .infinity)
        return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let width = min(subview.sizeThatFits(.unspecified).width, maxWidth, bounds.width)
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

// MARK: - Tiles

/// Small cards in a row that pages sideways: each 280 points wide, and at most 85% of the row when
/// there are several, so the next shows at the edge.
private struct CardTiles: View {
    let tiles: [CardTile]

    var body: some View {
        let several = tiles.count > 1
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    CardTileView(tile: tile)
                        .containerRelativeFrame(.horizontal) { width, _ in min(280, several ? width * 0.85 : width) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollIndicators(.hidden)
        .padding(.top, 4)
    }
}

private struct CardTileView: View {
    let tile: CardTile

    @Environment(\.pixelLength) private var pixelLength
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 32

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let hero = tile.hero {
                Color.clear
                    .aspectRatio(2, contentMode: .fit)
                    .overlay { CardImageView(url: hero.url, points: 280) }
                    .clipped()
                    .accessibilityElement()
                    .accessibilityHidden(hero.alt.isEmpty)
                    .accessibilityLabel(hero.alt)
                    .accessibilityAddTraits(.isImage)
            }
            VStack(alignment: .leading, spacing: 6) {
                if tile.title != nil || tile.subtitle != nil {
                    HStack(spacing: 8) {
                        if let icon = tile.icon {
                            CardImageView(url: icon.url, points: iconSize, placeholder: false)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                                .accessibilityHidden(icon.alt.isEmpty)
                                .accessibilityLabel(icon.alt)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = tile.title {
                                Text(title)
                                    .font(.body.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let subtitle = tile.subtitle {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if let body = tile.body { CardRichText(html: body) }
                if let subtext = tile.subtext { CardRichText(html: subtext, small: true) }
                if !tile.buttons.isEmpty {
                    Spacer(minLength: 0)
                    let order = tile.buttonsInOrder
                    // Danger at the leading end and the rest at the trailing end, primary last, where
                    // they fit on one row; on more rows, in that order from the leading side.
                    let onlyTrailing = order.leading.isEmpty
                    CardButtons(
                        buttons: order.leading + order.trailing,
                        alignment: onlyTrailing ? .trailing : .leading,
                        trailingFrom: order.leading.count)
                        .frame(maxWidth: .infinity, alignment: onlyTrailing ? .trailing : .leading)
                        .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(.separator), lineWidth: max(pixelLength, 0.5)))
        .accessibilityElement(children: .contain)
    }
}
