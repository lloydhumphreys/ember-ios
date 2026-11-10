import SwiftUI
import UIKit
import EmberSDK

/// A message's file: a picture where `AttachmentDisplay` allows one (an image's preview or the
/// image itself, a video's poster), sized from the dimensions the server stored, and a row with the
/// file's kind, name and size for anything else.
struct AttachmentView: View {
    let file: StoredFile

    @Environment(Workspace.self) private var workspace
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch AttachmentDisplay.of(file) {
        case let .picture(path):
            Button {
                if let url = workspace.client.url(file.url) { openURL(url) }
            } label: {
                picture(path)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.name)
        case .row:
            Button {
                if let url = workspace.client.url(file.downloadUrl) { openURL(url) }
            } label: {
                FileRow(name: file.name, contentType: file.contentType, byteSize: file.byteSize)
            }
            .buttonStyle(.plain)
        }
    }

    private func picture(_ path: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        // Drawn within 280 by 320 points.
        return RemoteImage(path: path, points: 320)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: 280, maxHeight: 320, alignment: .leading)
            .frame(minHeight: aspectRatio == nil ? 120 : nil)
            .clipShape(shape)
            .overlay {
                if file.isVideo {
                    Image(systemName: "play.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
    }

    /// Width over height, when the server knows both; nil leaves the picture to find its own.
    private var aspectRatio: CGFloat? {
        guard let width = file.width, let height = file.height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

struct FileRow: View {
    let name: String
    let contentType: String
    let byteSize: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(contentType: contentType, name: name))
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Int64(byteSize), format: .byteCount(style: .file))
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
                    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 320, alignment: .leading)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
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
                .frame(maxWidth: thumbnail == nil ? 320 : 280, alignment: .leading)
            }
        }
    }
}

/// The pictures staged files were sent with, by client message id, so a file on its way up shows
/// what was picked rather than a blank until the room has it. Small, and only for this run.
@MainActor final class StagedThumbnails {
    static let shared = StagedThumbnails()

    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.countLimit = 50
    }

    func image(for clientMessageId: String) -> UIImage? {
        images.object(forKey: clientMessageId as NSString)
    }

    func set(_ image: UIImage?, for clientMessageId: String) {
        if let image { images.setObject(image, forKey: clientMessageId as NSString) }
    }
}

/// A picture from the server, fetched with the session's cookies and kept in memory.
struct RemoteImage: View {
    let path: String
    /// The longer side it's drawn at, in points, which it's downsampled to.
    let points: CGFloat

    @Environment(Workspace.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?

    private var maxPixel: Int { Int((points * displayScale).rounded(.up)) }

    var body: some View {
        let key = RemoteImages.key(workspace.client, path, maxPixel: maxPixel)
        let image = RemoteImages.shared.cached(key) ?? loaded
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
            }
        }
        .task(id: key) {
            loaded = await RemoteImages.shared.image(client: workspace.client, path: path, maxPixel: maxPixel)
        }
    }
}

/// Pictures from the server: files, their previews, link previews' pictures. Held to the bounds a
/// card's are (`ImageLimits`), as anyone in a room can post one.
@MainActor final class RemoteImages {
    static let shared = RemoteImages()

    private let images = NSCache<NSString, LoadedImageBox>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failed = LastingFailures(limit: 500)

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

    /// One load per address and size, whoever asks; it finishes for the others when one of them
    /// goes away.
    func image(client: EmberClient, path: String, maxPixel: Int) async -> UIImage? {
        let key = Self.key(client, path, maxPixel: maxPixel)
        let address = Self.address(client, path)
        if let image = cached(key) { return image }
        if failed.contains(address) { return nil }
        if let task = inFlight[key] { return await task.value }
        // Unstructured, so cancelling the view that started it doesn't cancel it for the rest.
        let task = Task<UIImage?, Never> {
            let result = await Self.load(client: client, path: path, maxPixel: maxPixel)
            self.inFlight[key] = nil
            switch result {
            case let .success(loaded):
                self.images.setObject(LoadedImageBox(loaded), forKey: key as NSString, cost: ImageLimits.cost(loaded))
                return loaded.image
            case let .failure(failure):
                if failure.isLasting { self.failed.insert(address) }
                return nil
            }
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
