import SwiftUI
import UIKit
import EmberSDK
import QuickLook

/// A message's file: a picture where `AttachmentDisplay` allows one (an image's preview or the
/// image itself, a video's poster), sized from the dimensions the server stored or, failing those,
/// the ones it was last seen at, and a row with the file's kind, name and size for anything else.
/// A video plays in the system's player; anything else opens in Quick Look once it's downloaded.
struct AttachmentView: View {
    let file: StoredFile

    @Environment(Workspace.self) private var workspace
    @State private var phase = RemoteImage.Phase.loading
    @State private var tries = 0
    @State private var opening = FileOpening.idle
    @State private var preview: URL?
    @State private var video: URL?

    var body: some View {
        Group {
            switch AttachmentDisplay.of(file) {
            case let .picture(path):
                Button {
                    if case .failed = phase {
                        tries += 1
                    } else {
                        open()
                    }
                } label: {
                    picture(path)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(file.name)
                .accessibilityValue(phase.isFailed ? "Couldn’t load" : "")
            case .row:
                Button(action: open) {
                    FileRow(name: file.name, contentType: file.contentType, byteSize: file.byteSize, opening: opening == .downloading, failed: opening == .failed)
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($preview)
        .fullScreenCover(isPresented: Binding { video != nil } set: { if !$0 { video = nil } }) {
            if let video { VideoViewer(url: video, cookies: VideoViewer.cookies(for: video, client: workspace.client)) }
        }
    }

    private func picture(_ path: String) -> some View {
        // This account's, should the picture land after a switch to another.
        let sizes = PictureSizes.shared
        return RemoteImage(path: path, points: PictureBounds.height, tries: tries) { phase in
            self.phase = phase
            if case let .loaded(size) = phase, Self.storedAspectRatio(file) == nil {
                sizes.remember(size, for: PictureSizes.key(file: file.id))
            }
        }
        .overlay {
            if opening == .downloading {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: .circle)
            } else if file.isVideo, !phase.isFailed {
                Image(systemName: "play.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .pictureFrame(expected: aspectRatio)
    }

    /// The video in the player, or the file, once it's downloaded, in Quick Look.
    private func open() {
        if file.isVideo, let url = workspace.client.url(file.url) {
            video = url
            return
        }
        guard opening.begin() else { return }
        Task {
            do {
                preview = try await DocumentCache.shared.files.file(file, client: workspace.client)
                opening.finish(failed: false)
            } catch {
                opening.finish(failed: true)
            }
        }
    }

    /// Width over height: as the server stored it, else as it was last seen, else as it turned out
    /// once loaded. Nil while there's no telling, when it takes `PictureBounds.placeholder`.
    private var aspectRatio: CGFloat? {
        if let stored = Self.storedAspectRatio(file) { return stored }
        if let seen = PictureSizes.shared.size(for: PictureSizes.key(file: file.id)) { return seen.width / seen.height }
        if case let .loaded(size) = phase, size.width > 0, size.height > 0 { return size.width / size.height }
        return nil
    }

    static func storedAspectRatio(_ file: StoredFile) -> CGFloat? {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

/// Where opening a file in Quick Look is: not tried (or tried and opened), downloading it, or the
/// last try failed, which shows until the next one starts.
enum FileOpening: Equatable {
    case idle
    case downloading
    case failed

    /// Starts a download, forgetting the last failure. False, and nothing changed, while one is
    /// already on its way.
    mutating func begin() -> Bool {
        guard self != .downloading else { return false }
        self = .downloading
        return true
    }

    /// The download ended: in `failed`, or with the file ready to open.
    mutating func finish(failed: Bool) {
        self = failed ? .failed : .idle
    }
}

/// The box a message's picture is drawn within, and the size a picture of a given shape takes in it.
enum PictureBounds {
    static let width: CGFloat = 280
    static let height: CGFloat = 320
    /// What a picture of no known shape takes until it's loaded, or when it fails.
    static let placeholder = CGSize(width: 200, height: 150)
    /// The narrowest and the widest a picture is drawn; past them, it's cropped about its centre.
    static let shapes: ClosedRange<CGFloat> = (1.0 / 3.0)...3.0

    /// `ratio` held within `shapes`.
    static func clamped(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, shapes.lowerBound), shapes.upperBound)
    }

    /// The largest size of that shape (width over height), held within `shapes`, that fits the box.
    static func size(aspectRatio: CGFloat) -> CGSize {
        let ratio = clamped(aspectRatio)
        let width = min(Self.width, height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

extension View {
    /// Draws a picture within `PictureBounds`, rounded and outlined at the size it ends up, and takes
    /// up that size and no more. A shape past `PictureBounds.shapes` is held to it, the picture
    /// cropped about its centre; with no shape, it takes the picture's own.
    func pictureFrame(aspectRatio ratio: CGFloat?) -> some View {
        PictureBox(limit: nil) {
            Group {
                if let ratio {
                    shaped(ratio)
                } else {
                    self.aspectRatio(contentMode: .fit)
                }
            }
            .pictureOutline()
        }
    }

    /// `pictureFrame` for a picture whose shape may not be known before it's drawn: with none, the
    /// size of `PictureBounds.placeholder`, as a placeholder has no shape of its own and would take
    /// the whole box. The picture stays the same view whichever it is, so it isn't drawn anew once
    /// its shape turns up.
    func pictureFrame(expected ratio: CGFloat?) -> some View {
        let placeholder = PictureBounds.placeholder
        return PictureBox(limit: ratio == nil ? placeholder : nil) {
            shaped(ratio ?? placeholder.width / placeholder.height)
                .pictureOutline()
        }
    }

    /// Shaped by the ratio alone and filled by the picture, so one that turns out to be another
    /// shape is cropped to the box instead of spilling past it.
    private func shaped(_ ratio: CGFloat) -> some View {
        Color.clear
            .aspectRatio(PictureBounds.clamped(ratio), contentMode: .fit)
            .overlay { self }
    }

    private func pictureOutline() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Offers its view the picture box, or `limit` in its place, and is the size that view takes of it.
/// A frame with the box for its limits is as wide as it's offered instead, which left a tall
/// picture's outline running round the empty space beside it.
private struct PictureBox: Layout {
    let limit: CGSize?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let box = limit ?? CGSize(width: PictureBounds.width, height: PictureBounds.height)
        let width = min(proposal.width ?? box.width, box.width)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: box.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

struct FileRow: View {
    let name: String
    let contentType: String
    let byteSize: Int
    /// Being downloaded to open.
    var opening = false
    /// The last try to download it to open failed.
    var failed = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if opening {
                    ProgressView()
                } else {
                    Image(systemName: Self.symbol(contentType: contentType, name: name))
                        .font(.title2)
                }
            }
            .foregroundStyle(.secondary)
            .frame(minWidth: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if failed {
                        Text("Couldn’t open. Retry")
                    } else {
                        Text(Int64(byteSize), format: .byteCount(style: .file))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 320)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    static func symbol(contentType: String, name: String) -> String {
        let type = contentType.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video") { return "film" }
        if type.hasPrefix("audio") { return "waveform" }
        if type.contains("zip") || type.contains("compressed") || ["zip", "gz", "tar", "rar", "7z"].contains(ext) { return "doc.zipper" }
        if type.contains("spreadsheet") || type.contains("excel") || ["csv", "xls", "xlsx", "numbers"].contains(ext) { return "tablecells" }
        if type.hasPrefix("text/") || type.contains("word") || ["txt", "md", "doc", "docx", "pages", "rtf"].contains(ext) { return "doc.text" }
        return "doc"
    }
}

/// A file on its way up: the picture made for it when there is one, else its row, with a bar for
/// the bytes sent that turns to a spinner once they're all up and the room has yet to answer.
struct PendingUploadView: View {
    let upload: PendingUpload
    let isFailed: Bool
    let thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .pictureFrame(aspectRatio: Self.aspectRatio(of: thumbnail))
                        .accessibilityLabel(upload.name)
                } else {
                    FileRow(name: upload.name, contentType: upload.contentType, byteSize: upload.byteSize)
                }
            }
            .opacity(isFailed ? 1 : 0.5)
            if !isFailed {
                Group {
                    if upload.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ProgressView(value: upload.fraction)
                    }
                }
                .frame(maxWidth: barWidth, alignment: .leading)
            }
        }
    }

    /// As wide as what it sits under, though no narrower than a bar reads at.
    private var barWidth: CGFloat {
        guard let thumbnail else { return 320 }
        guard let ratio = Self.aspectRatio(of: thumbnail) else { return PictureBounds.width }
        return max(PictureBounds.size(aspectRatio: ratio).width, 120)
    }

    private static func aspectRatio(of image: UIImage) -> CGFloat? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size.width / image.size.height
    }
}

/// The pictures staged files were sent with, by client message id, so a file on its way up shows
/// what was picked rather than a blank until the room has it. Small, and only for this run.
@MainActor final class StagedThumbnails {
    static var shared: StagedThumbnails { AccountStores.current.stagedThumbnails }

    private let images = NSCache<NSString, UIImage>()

    init() {
        images.countLimit = 50
    }

    func image(for clientMessageId: ClientMessageID) -> UIImage? {
        images.object(forKey: clientMessageId.rawValue as NSString)
    }

    func set(_ image: UIImage?, for clientMessageId: ClientMessageID) {
        if let image { images.setObject(image, forKey: clientMessageId.rawValue as NSString) }
    }

    func reset() { images.removeAllObjects() }
}

/// A picture from the server, fetched with the session's cookies and kept in memory. One that
/// fails says so; it's tried again by itself a few times when the failure could pass, when the
/// connection comes back, and whenever `tries` moves on.
struct RemoteImage: View {
    enum Phase: Equatable {
        case loading
        /// Its size, in points, as decoded.
        case loaded(CGSize)
        case failed(ImageLimits.Failure)

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }
    }

    let path: String
    /// The longer side it's drawn at, in points, which it's downsampled to.
    let points: CGFloat
    /// Moved on to try it again now, even after a failure that's lasting.
    var tries = 0
    /// Whether its failure offers a retry: false where nothing moves `tries` on.
    var retries = true
    /// Told of each change of phase.
    var report: (Phase) -> Void = { _ in }

    @Environment(Workspace.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @State private var load = ImageLoad<UIImage>.loading
    @State private var reconnects = 0

    private var maxPixel: Int { Int((points * displayScale).rounded(.up)) }

    var body: some View {
        let key = RemoteImages.key(workspace.client, path, maxPixel: maxPixel)
        let image = RemoteImages.shared.cached(key) ?? load.picture
        Group {
            if let image {
                PictureImage(image: image)
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        if load.failure != nil { PictureFailure(retry: retries) }
                    }
            }
        }
        .task(id: "\(key)#\(tries)#\(reconnects)") {
            if let image {
                report(.loaded(image.size))
                return
            }
            let client = workspace.client
            if tries > 0 { RemoteImages.shared.forget(client, path) }
            load = .loading
            report(.loading)
            await ImageLoad.keepTrying {
                await RemoteImages.shared.result(client: client, path: path, maxPixel: maxPixel)
            } update: { now in
                load = now
                switch now {
                case .loading: break
                case let .failed(failure): report(.failed(failure))
                case let .loaded(image): report(.loaded(image.size))
                }
            }
        }
        .retryingOnReconnect(after: image == nil ? load.failure : nil, count: $reconnects)
    }
}

/// Pictures from the server: files, their previews, link previews' pictures. Held to the bounds a
/// card's are (`ImageLimits`), as anyone in a room can post one.
@MainActor final class RemoteImages {
    static var shared: RemoteImages { AccountStores.current.remoteImages }

    private let images = NSCache<NSString, LoadedImageBox>()
    private var inFlight: [String: Task<Result<UIImage, ImageLimits.Failure>, Never>] = [:]
    private var failed = LastingFailures(limit: 500)
    /// Moves on at each `reset()`, so a load that started before one doesn't fill the caches after it.
    private var generation = 0

    init() {
        images.totalCostLimit = 64 * 1024 * 1024
    }

    static func address(_ client: EmberClient, _ path: String) -> String {
        client.url(path)?.absoluteString ?? client.origin.absoluteString + path
    }

    static func key(_ client: EmberClient, _ path: String, maxPixel: Int) -> String {
        "\(maxPixel)|\(address(client, path))"
    }

    func cached(_ key: String) -> UIImage? {
        images.object(forKey: key as NSString)?.loaded.image
    }

    func hasFailed(_ client: EmberClient, _ path: String) -> Bool { failed.contains(Self.address(client, path)) }

    /// Forgets that the picture at `path` failed, so the next ask fetches it again.
    func forget(_ client: EmberClient, _ path: String) { failed.remove(Self.address(client, path)) }

    /// Empties the pictures and the failures kept, and lets loads under way finish for whoever asked
    /// without keeping what they bring.
    func reset() {
        images.removeAllObjects()
        inFlight = [:]
        failed.removeAll()
        generation += 1
    }

    func image(client: EmberClient, path: String, maxPixel: Int) async -> UIImage? {
        try? await result(client: client, path: path, maxPixel: maxPixel).get()
    }

    /// The picture, or why it didn't load. One load per address and size, whoever asks; it finishes
    /// for the others when one of them goes away.
    func result(client: EmberClient, path: String, maxPixel: Int) async -> Result<UIImage, ImageLimits.Failure> {
        let key = Self.key(client, path, maxPixel: maxPixel)
        let address = Self.address(client, path)
        if let image = cached(key) { return .success(image) }
        if let failure = failed.failure(for: address) { return .failure(failure) }
        if let task = inFlight[key] { return await task.value }
        let generation = generation
        // Unstructured, so cancelling the view that started it doesn't cancel it for the rest.
        let task = Task<Result<UIImage, ImageLimits.Failure>, Never> {
            let result = await Self.load(client: client, path: path, maxPixel: maxPixel)
            guard generation == self.generation else { return result.map(\.image) }
            self.inFlight[key] = nil
            switch result {
            case let .success(loaded):
                self.images.setObject(LoadedImageBox(loaded), forKey: key as NSString, cost: ImageLimits.cost(loaded))
            case let .failure(failure):
                if failure.isLasting { self.failed.insert(address, failure) }
            }
            return result.map(\.image)
        }
        inFlight[key] = task
        return await task.value
    }

    /// Through the client, which sends the session's cookies only to the server itself. Its transport
    /// hands over the whole body at once, so a body larger than it said is refused once it's here.
    @concurrent nonisolated private static func load(client: EmberClient, path: String, maxPixel: Int) async -> Result<LoadedImage, ImageLimits.Failure> {
        do {
            guard client.url(path) != nil else { return .failure(.refused) }
            let (data, response) = try await client.perform(try client.request("GET", path))
            if let failure = ImageLimits.failure(of: response) { return .failure(failure) }
            return await ImageLimits.decode(data, maxPixel: maxPixel)
        } catch let error as EmberError {
            return .failure(error.isUnreachable ? .unreachable : .status(error.status))
        } catch {
            return .failure(.unreachable)
        }
    }
}
