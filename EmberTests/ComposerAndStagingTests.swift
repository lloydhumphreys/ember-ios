import Foundation
import Testing
import UIKit
import EmberSDK
@testable import Ember

/// What the composer sends for a draft, and how staged copies are made, kept and cleared away. Each
/// test stages under a folder of its own, never the real `Uploads`, which a launch sweeps.
@MainActor
@Suite final class ComposerAndStagingTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ComposerAndStagingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var uploads: URL { root.appending(path: "Uploads", directoryHint: .isDirectory) }

    private func file(_ name: String, bytes: Int = 4, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? root.appending(path: "Picked-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// A file that reads as `size` bytes without holding them: a sparse file.
    private func sparse(_ name: String, size: UInt64, in folder: URL? = nil) throws -> URL {
        let url = try file(name, bytes: 0, in: folder)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url
    }

    private func staged(_ name: String, bytes: Int = 4, thumbnail: UIImage? = UIImage(systemName: "photo")) throws -> StagedFile {
        let copy = try Staging.copied(try file(name, bytes: bytes), isScoped: false, into: uploads)
        let source = try UploadSource(fileURL: copy, contentType: "image/jpeg", isTemporary: true)
        return StagedFile(source: source, thumbnail: thumbnail)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func contents(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: What's sent

    @Test func aDraftGoesAsTypedWithItsSpacesAndBlankLines() throws {
        let message = try #require(RoomComposer.outgoing("\n  hello \n\nthere  \n\n"))
        #expect(message.body == "<p><br>  hello <br><br>there  <br><br></p>")
        // The server's plain text for that body: the newlines it ends with dropped, nothing else.
        #expect(message.plainText == "\n  hello \n\nthere  ")
    }

    @Test func aDraftsCarriageReturnsBreakLinesAsTheBodyDoes() throws {
        let message = try #require(RoomComposer.outgoing("a\r\nb\rc\r\n"))
        #expect(message.body == "<p>a<br>b<br>c<br></p>")
        #expect(message.plainText == "a\nb\nc")
    }

    @Test func aBlankDraftSendsNoText() {
        #expect(RoomComposer.outgoing("") == nil)
        #expect(RoomComposer.outgoing("  \n\t \r\n ") == nil)
    }

    // MARK: Sweeping

    @Test func theSweepEmptiesUploadsAndNothingElse() async throws {
        let stale = try file("old.jpg", in: uploads.appending(path: UUID().uuidString))
        let loose = try file("loose.txt", in: uploads)
        let neighbour = try file("keep.txt", in: root.appending(path: "Other"))
        await Staging.sweep(uploads).value
        #expect(!exists(stale) && !exists(loose))
        #expect(contents(uploads).isEmpty)
        #expect(exists(neighbour))
    }

    @Test func theSweepTakesAnAbsentFolderInItsStride() async {
        await Staging.sweep(root.appending(path: "Nowhere")).value
        #expect(!exists(root.appending(path: "Nowhere")))
    }

    // MARK: Copies

    @Test func aCopyGoesInAFolderOfItsOwnKeepingItsName() throws {
        let copy = try Staging.copied(try file("cat.jpg"), isScoped: false, into: uploads)
        #expect(copy.lastPathComponent == "cat.jpg")
        #expect(copy.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == uploads.standardizedFileURL)
        Staging.discard(copy)
        #expect(contents(uploads).isEmpty)
    }

    @Test func aFileOverTheLimitIsRefusedBeforeCopying() throws {
        let huge = try sparse("huge.mov", size: UInt64(Limits.fileBytes) + 1)
        #expect(throws: Staging.Refusal.tooLarge("huge.mov")) {
            try Staging.copied(huge, isScoped: false, into: uploads)
        }
        #expect(contents(uploads).isEmpty)
    }

    @Test func aCopyOverTheLimitIsRefusedAndDeleted() throws {
        // As a copy whose original's size couldn't be read would be, in a folder of its own.
        let huge = try sparse("huge.mov", size: UInt64(Limits.fileBytes) + 1, in: uploads.appending(path: UUID().uuidString))
        #expect(throws: Staging.Refusal.tooLarge("huge.mov")) { try Staging.measured(huge) }
        #expect(contents(uploads).isEmpty)
    }

    @Test func aCopyAtTheLimitIsKept() throws {
        let fits = try sparse("fits.mov", size: UInt64(Limits.fileBytes), in: uploads.appending(path: UUID().uuidString))
        try Staging.measured(fits)
        #expect(exists(fits))
    }

    @Test func aCancelledCopyLeavesNothing() async throws {
        let picked = try file("late.jpg")
        let uploads = uploads
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Staging.copied(picked, isScoped: false, into: uploads)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(contents(uploads).isEmpty)
    }

    // MARK: Staged files

    @Test func removingAStagedFileDeletesItsCopy() throws {
        let files = StagedFiles()
        let file = try staged("a.jpg")
        files.append(file)
        files.remove(file)
        #expect(files.files.isEmpty)
        #expect(contents(uploads).isEmpty)
    }

    @Test func stagedFilesLeftBehindAreDeletedWithTheComposer() throws {
        var files: StagedFiles? = StagedFiles()
        let a = try staged("a.jpg"), b = try staged("b.pdf")
        files?.append(a)
        files?.append(b)
        files = nil
        #expect(!exists(a.source.fileURL) && !exists(b.source.fileURL))
        #expect(contents(uploads).isEmpty)
    }

    @Test func filesHandedToSendAreLeftForTheSDK() throws {
        var files: StagedFiles? = StagedFiles()
        let a = try staged("a.jpg")
        files?.append(a)
        let taken = files?.takeAll() ?? []
        #expect(taken.map(\.id) == [a.id])
        #expect(files?.files.isEmpty == true)
        files = nil
        #expect(exists(a.source.fileURL))
    }

    // MARK: Thumbnails

    @Test func thumbnailsPairByPositionSkippingARefusedFile() throws {
        let first = try staged("first.jpg")
        let huge = try sparse("huge.jpg", size: UInt64(Limits.fileBytes) + 1)
        let refused = StagedFile(source: try UploadSource(fileURL: huge, contentType: "image/jpeg"), thumbnail: UIImage(systemName: "photo"))
        let plain = try staged("notes.pdf", thumbnail: nil)
        let last = try staged("last.jpg")
        #expect(refused.source.isTooLarge)
        let files = [first, refused, plain, last]
        // One id per file in order, then the text's.
        let pairs = RoomComposer.thumbnails(ids: ["f1", "f2", "f3", "f4", "text"], files: files)
        #expect(pairs.map(\.id) == ["f1", "f4"])
        #expect(pairs.count == 2 && pairs[0].thumbnail === first.thumbnail && pairs[1].thumbnail === last.thumbnail)
    }

    @Test func noIdsMeanNoThumbnails() throws {
        let files = [try staged("a.jpg"), try staged("b.jpg")]
        #expect(RoomComposer.thumbnails(ids: [], files: files).isEmpty)
        #expect(RoomComposer.thumbnails(ids: ["f1"], files: files).map(\.id) == ["f1"])
    }
}
