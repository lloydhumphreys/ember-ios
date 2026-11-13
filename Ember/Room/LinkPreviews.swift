import SwiftUI
import EmberSDK

/// A link pasted into the composer, worked out from the field's text before and after a change, as
/// the field says nothing of how its text changed: a paste is one change that puts in a run of
/// several characters at once, where typing puts in one at a time. The web asks for a preview only
/// for a link pasted, so this is too.
struct PastedLink: Equatable {
    /// What was pasted, as it stands in the text, without the whitespace around it.
    let text: String
    let url: URL

    /// The link a change from `old` to `new` pasted: what it put in, between what it left before
    /// and after, when that's a single http or https address (whitespace around it aside). nil for
    /// a character typed, text taken out, or anything pasted that isn't just one link.
    static func pasted(from old: String, to new: String) -> PastedLink? {
        let old = Array(old), new = Array(new)
        guard new.count > old.count else { return nil }
        var prefix = 0
        while prefix < old.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let inserted = new[prefix..<(new.count - suffix)]
        guard inserted.count > 1 else { return nil }
        return link(String(inserted))
    }

    /// `text` as one http or https link with a host, whitespace around it aside.
    static func link(_ text: String) -> PastedLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return PastedLink(text: trimmed, url: url)
    }
}

/// The previews of links pasted into a composer, to go with the next message, as the web's
/// composer puts each in the message being written. Each paste asks for its link's preview; a
/// paste while one is being asked for lets that one go, as the web's does. A preview that can't
/// be had is left out without a word, and one answered once its link has gone from the text, or
/// once the message has gone, is let go of.
@MainActor @Observable final class LinkPreviews {
    typealias Fetch = @Sendable (URL) async throws -> LinkPreview?

    /// What goes with the next message, in the order pasted.
    private(set) var previews: [LinkPreview] = []
    /// The link being asked about, while one is.
    private(set) var loading: PastedLink?

    @ObservationIgnored private var task: Task<Void, Never>?

    isolated deinit {
        task?.cancel()
    }

    /// Asks the server for `link`'s preview.
    func paste(_ link: PastedLink, client: EmberClient) {
        paste(link) { try await client.linkPreview(for: $0) }
    }

    /// Asks `fetch` for `link`'s preview, letting go of any still being asked for. A link already
    /// previewed isn't asked about again.
    func paste(_ link: PastedLink, fetch: @escaping Fetch) {
        cancelLoading()
        guard !previews.contains(where: { Self.sameLink($0.url, link.url) }) else { return }
        loading = link
        let url = link.url
        task = Task { [weak self] in
            let preview = try? await fetch(url)
            guard let self, !Task.isCancelled, self.loading == link else { return }
            self.loading = nil
            self.task = nil
            guard let preview, !self.previews.contains(where: { Self.sameLink($0.url, preview.url) }) else { return }
            self.previews.append(preview)
        }
    }

    /// The field's text now: a link being asked about that's no longer in it is let go of.
    func textChanged(_ text: String) {
        guard let loading, !text.contains(loading.text) else { return }
        cancelLoading()
    }

    func remove(_ preview: LinkPreview) {
        previews.removeAll { $0 == preview }
    }

    /// Lets go of everything, and of any link being asked about: once the message has gone, or the
    /// composer is another room's or thread's.
    func clear() {
        cancelLoading()
        previews = []
    }

    private func cancelLoading() {
        task?.cancel()
        task = nil
        loading = nil
    }

    /// Whether two addresses are the same page, as a preview's can come back with a slash added.
    private static func sameLink(_ a: String, _ b: URL) -> Bool {
        sameLink(a, b.absoluteString)
    }

    private static func sameLink(_ a: String, _ b: String) -> Bool {
        func normal(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return normal(a) == normal(b)
    }
}

/// A pending link preview in the composer, as the timeline draws one in a message (`RichTextView`'s
/// card): its picture, title and a line or two of description, here with the page's host, and a
/// remove button at its corner as a staged file has.
struct PendingLinkPreview: View {
    let preview: LinkPreview
    let remove: () -> Void

    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 56

    private var host: String? {
        guard let host = URL(string: preview.url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let image = preview.image {
                    RemoteImage(path: image, points: imageSize, retries: false)
                        .frame(width: imageSize, height: imageSize)
                        .clipShape(.rect(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let host {
                        Text(host)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
            .accessibilityElement(children: .combine)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    // A 44pt target over the card's corner, the glyph inside it.
                    .frame(width: StagedFileView.removeTarget, height: StagedFileView.removeTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(-12)
            .accessibilityLabel("Remove preview of \(preview.title)")
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}
