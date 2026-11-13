import Foundation
import AVFoundation
import CoreTransferable
import ImageIO
import UIKit
import UniformTypeIdentifiers
import EmberSDK

/// A file picked for the composer and waiting for Send: a copy on disk the SDK reads from and
/// deletes once it's posted or discarded, with the picture made for it.
struct StagedFile: Identifiable {
    let id = UUID()
    let source: UploadSource
    /// The preview's picture, for the strip and the pending row; nil for a file without one.
    let thumbnail: UIImage?

    var name: String { source.name }
}

/// What a composer has staged, and the picks still being copied for it, kept in the order they
/// were picked however long each takes. A few are copied at a time and the rest wait their turn,
/// so a big pick doesn't read every file at once. It's kept for its room or thread while the app
/// runs (`Drafts`), and when it goes its copies go with it: picks still being copied are
/// cancelled, and files never sent are deleted.
@MainActor @Observable final class StagedFiles {
    private(set) var files: [StagedFile] = []
    /// How many picks are still waiting, being copied or measured.
    private(set) var copying = 0

    /// How many picks are copied at once.
    @ObservationIgnored let concurrentCopies: Int
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var waiting: [Pick] = []
    /// Each file's place in the order picked, by its id.
    @ObservationIgnored private var places: [UUID: Int] = [:]
    @ObservationIgnored private var nextPlace = 0

    private struct Pick {
        let key = UUID()
        let place: Int
        let copy: @Sendable () async throws -> URL?
        let refuse: @MainActor (any Error) -> Void
    }

    init(concurrentCopies: Int = 3) {
        self.concurrentCopies = max(1, concurrentCopies)
    }

    isolated deinit {
        for task in tasks.values { task.cancel() }
        for file in files { Staging.discard(file.source.fileURL) }
    }

    func append(_ file: StagedFile) {
        insert(file, at: takePlace())
    }

    func remove(_ file: StagedFile) {
        files.removeAll { $0.id == file.id }
        places[file.id] = nil
        Staging.discard(file.source.fileURL)
    }

    /// Everything staged, handed to Send: the SDK deletes each file from here on.
    func takeAll() -> [StagedFile] {
        defer {
            files = []
            places = [:]
        }
        return files
    }

    /// Stages the copy `copy` makes (nil for none), off the main actor, in its place after every
    /// pick before it. `refuse` hears why one couldn't be, unless these files have gone meanwhile,
    /// when there's no screen to say it on and the copy is deleted instead.
    func stage(_ copy: @escaping @Sendable () async throws -> URL?, refuse: @escaping @MainActor (any Error) -> Void) {
        copying += 1
        waiting.append(Pick(place: takePlace(), copy: copy, refuse: refuse))
        startWaiting()
    }

    private func takePlace() -> Int {
        defer { nextPlace += 1 }
        return nextPlace
    }

    private func insert(_ file: StagedFile, at place: Int) {
        places[file.id] = place
        let index = files.firstIndex { (places[$0.id] ?? .max) > place } ?? files.endIndex
        files.insert(file, at: index)
    }

    private func startWaiting() {
        while tasks.count < concurrentCopies, !waiting.isEmpty {
            start(waiting.removeFirst())
        }
    }

    private func start(_ pick: Pick) {
        let key = pick.key, place = pick.place, copy = pick.copy, refuse = pick.refuse
        tasks[key] = Task { [weak self] in
            defer { self?.finish(key) }
            do {
                guard let url = try await Self.background(copy) else { return }
                // `self` is looked at again after each wait, never held across one, so the files can
                // go while this is out.
                guard self != nil, !Task.isCancelled else { return Staging.discard(url) }
                let (source, preview) = try await Self.background { try await Staging.stage(url) }
                guard let self, !Task.isCancelled else { return Staging.discard(source.fileURL) }
                insert(StagedFile(source: source, thumbnail: preview.flatMap(UIImage.init(data:))), at: place)
            } catch is CancellationError {
                // Gone with the composer; `copied` has left nothing behind.
            } catch {
                if self != nil, !Task.isCancelled { refuse(error) }
            }
        }
    }

    private func finish(_ key: UUID) {
        tasks[key] = nil
        copying -= 1
        startWaiting()
    }

    /// Runs `work` off the main actor, cancelled along with the task waiting on it.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let job = Task.detached(operation: work)
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

/// What the composer's pickers need done to a file before it can be staged, all of it off the main
/// actor: copied somewhere of the app's own, measured, and given a preview.
enum Staging {
    enum Refusal: Error, Equatable {
        /// The file's name, which the notice names.
        case tooLarge(String)
        case unreadable
    }

    /// A copy made by `copied`, ready to send, with its preview's bytes for the thumbnail.
    static func stage(_ copy: URL) async throws -> (source: UploadSource, preview: Data?) {
        let type = contentType(of: copy)
        let preview = await preview(of: copy, contentType: type)
        do {
            let source = try UploadSource.temporary(fileURL: copy, contentType: type, preview: preview)
            return (source, preview?.data)
        } catch {
            discard(copy)
            throw Refusal.unreadable
        }
    }

    /// Where staged copies go, each in a folder of its own.
    static var uploadsFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
    }

    /// Copies `url` into a folder of its own under `uploads`, keeping its name. It's a URL the
    /// photo picker lends only for now, or one outside the sandbox (the Files picker's, which
    /// `isScoped` says to ask for). One outside the sandbox is read through a file coordinator, so
    /// a file in iCloud Drive or another provider's is downloaded first and isn't read while
    /// it's being written. A file over `Limits.fileBytes` is refused before any of it is copied
    /// when its size can be read, and once copied when it can't. Nothing is left behind when it
    /// fails or the task is cancelled.
    static func copied(_ url: URL, isScoped: Bool, into uploads: URL = uploadsFolder) throws -> URL {
        try Task.checkCancellation()
        let scoped = isScoped && url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard isScoped else { return try copiedNow(url, into: uploads) }
        var coordinationError: NSError?
        var result: Result<URL, any Error> = .failure(Refusal.unreadable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try copiedNow(readable, named: url.lastPathComponent, into: uploads) }
        }
        if coordinationError != nil { throw Refusal.unreadable }
        return try result.get()
    }

    /// `copied`'s work once the file can be read: `name` is what the copy is called.
    private static func copiedNow(_ url: URL, named name: String? = nil, into uploads: URL) throws -> URL {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let name = name ?? url.lastPathComponent
        guard !isTooLarge(byteSize: size) else { throw Refusal.tooLarge(name) }
        let folder = uploads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = folder.appending(path: name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            // A copy that failed partway would otherwise stay until the next launch's sweep.
            discard(copy)
            throw Refusal.unreadable
        }
        try measured(copy)
        if Task.isCancelled {
            discard(copy)
            throw CancellationError()
        }
        return copy
    }

    /// Refuses a copy over `Limits.fileBytes`, deleting it. The size `copied` reads first can be
    /// missing (a provider that doesn't say), so the copy is measured too, rather than staged and
    /// left for Send to refuse.
    static func measured(_ copy: URL) throws {
        let size = (try? copy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard isTooLarge(byteSize: size) else { return }
        discard(copy)
        throw Refusal.tooLarge(copy.lastPathComponent)
    }

    /// Deletes a staged copy that never went to the SDK, with the folder it was put in.
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Deletes everything in `uploads`, once at launch: uploads are held only in memory, so
    /// nothing there can still be in use, and copies left by a run that ended (a crash, the app
    /// killed with files staged) would otherwise stay. What's there is listed now, which is quick,
    /// and deleted in the background, which may not be; a file staged meanwhile isn't listed, so
    /// it's left alone. Answers the deleting, for tests to wait on.
    @discardableResult
    static func sweep(_ uploads: URL = uploadsFolder) -> Task<Void, Never> {
        let entries = (try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: nil)) ?? []
        return Task.detached(priority: .utility) {
            for entry in entries { try? FileManager.default.removeItem(at: entry) }
        }
    }

    static func isTooLarge(byteSize: Int) -> Bool {
        byteSize > Limits.fileBytes
    }

    /// The type the file's extension names, as the server is told it.
    static func contentType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A JPEG of the file for the types the server keeps a preview for, fitting the preview's
    /// bounds and never enlarged: the picture itself, or a video's frame at 0.1 s. nil when it
    /// can't be made or comes out over `Limits.previewBytes`; the file still goes without it.
    static func preview(of url: URL, contentType: String) async -> UploadPreview? {
        guard Uploads.hasPreview(contentType: contentType) else { return nil }
        let image = contentType.lowercased().hasPrefix("video") ? await videoFrame(url) : picture(url)
        guard let image, let data = jpeg(image), data.count <= Limits.previewBytes else { return nil }
        return UploadPreview(data: data, contentType: "image/jpeg")
    }

    /// The longest side, in pixels, a picture of `width` × `height` as stored is drawn at, where
    /// `orientation` is its EXIF orientation (5 to 8 turn it on its side, so the bounds apply the
    /// other way round).
    static func previewPixelSize(width: Int, height: Int, orientation: Int) -> Int {
        let turned = (5...8).contains(orientation)
        let fitted = Uploads.previewSize(width: turned ? height : width, height: turned ? width : height)
        return max(fitted.width, fitted.height)
    }

    private static func picture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewPixelSize(width: width, height: height, orientation: orientation),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        // Scales down to fit, never up.
        generator.maximumSize = CGSize(width: Limits.previewWidth, height: Limits.previewHeight)
        return try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A photo-library item as a file: copied out of the picker's loan into a staged copy of the
/// app's own, so a video is never held in memory. The movie comes first, as a video can offer a
/// picture too; a Live Photo goes as its picture (`PickedStill`).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try Staging.copied($0.file, isScoped: false)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try Staging.copied($0.file, isScoped: false)) }
        FileRepresentation(importedContentType: .item) { PickedFile(url: try Staging.copied($0.file, isScoped: false)) }
    }

    /// Whether an item offering `types` goes as its picture: a Live Photo, whose movie is only
    /// the moments around it, or anything with a picture and no movie.
    static func goesAsPicture(_ types: [UTType]) -> Bool {
        if types.contains(where: { $0.conforms(to: .livePhoto) || $0.identifier.hasPrefix("com.apple.live-photo") }) { return true }
        return types.contains { $0.conforms(to: .image) } && !types.contains { $0.conforms(to: .movie) }
    }
}

/// A photo-library item's picture as a file, for a Live Photo, which would otherwise come over as
/// its movie.
struct PickedStill: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { PickedStill(url: try Staging.copied($0.file, isScoped: false)) }
    }
}
