import Foundation
import Testing
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// Links pasted into the composer, the previews asked for them, and what goes with Send.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LinkPreviewTests {
    // MARK: Pasting

    @Test func aPastedLinkIsSeen() throws {
        let link = try #require(PastedLink.pasted(from: "Look ", to: "Look https://example.com/engine"))
        #expect(link.text == "https://example.com/engine")
        #expect(link.url == URL(string: "https://example.com/engine"))
        // Into the middle, over nothing, and with http.
        #expect(PastedLink.pasted(from: "ab", to: "ahttp://x.org/pb")?.text == "http://x.org/p")
        #expect(PastedLink.pasted(from: "", to: "HTTPS://Example.com")?.url.host() == "Example.com")
    }

    @Test func typingALinkOutIsNotAPaste() {
        let typed = "https://example.com"
        var text = ""
        for character in typed {
            let next = text + String(character)
            #expect(PastedLink.pasted(from: text, to: next) == nil)
            text = next
        }
        // Nor is taking text out, or a change that leaves it as it was.
        #expect(PastedLink.pasted(from: typed, to: "https://") == nil)
        #expect(PastedLink.pasted(from: typed, to: typed) == nil)
    }

    @Test func pastedTextThatIsNotJustALinkIsNotOne() {
        #expect(PastedLink.pasted(from: "", to: "hello there") == nil)
        #expect(PastedLink.pasted(from: "", to: "see https://example.com") == nil)
        #expect(PastedLink.pasted(from: "", to: "https://a.com https://b.com") == nil)
        #expect(PastedLink.pasted(from: "", to: "ftp://example.com/file") == nil)
        #expect(PastedLink.pasted(from: "", to: "mailto:ada@example.com") == nil)
        #expect(PastedLink.pasted(from: "", to: "example.com") == nil)
        #expect(PastedLink.pasted(from: "", to: "https://") == nil)
    }

    @Test func whitespaceAroundAPastedLinkIsLeftOut() throws {
        let link = try #require(PastedLink.pasted(from: "Hi", to: "Hi \n https://example.com/a \n"))
        #expect(link.text == "https://example.com/a")
        #expect(PastedLink.pasted(from: "", to: "\thttps://example.com\n")?.url == URL(string: "https://example.com"))
    }

    @Test func aSecondPasteIsSeenAfterTheFirst() throws {
        let first = "https://example.com/first"
        let both = first + " https://example.com/second"
        #expect(PastedLink.pasted(from: "", to: first)?.text == first)
        #expect(PastedLink.pasted(from: first, to: both)?.text == "https://example.com/second")
        // The same link again, pasted straight after itself.
        #expect(PastedLink.pasted(from: first, to: first + first)?.text == first)
    }

    // MARK: Asking for a preview

    private let link = PastedLink.link("https://example.com/engine")!

    @Test func aPastedLinksPreviewIsAskedForAndHeld() async throws {
        let transport = MockHTTPTransport()
        transport.stub("POST", "/api/unfurl", json: Fixtures.linkPreviewJSON())
        let previews = LinkPreviews()
        previews.paste(link, client: .mock(transport: transport))
        #expect(previews.loading == link)
        #expect(await eventually { previews.previews == [Fixtures.linkPreview] })
        #expect(previews.loading == nil)
        #expect(transport.lastBody("POST", "/api/unfurl")?["url"] as? String == "https://example.com/engine")
    }

    @Test func aPreviewCanBeRemoved() async throws {
        let previews = LinkPreviews()
        previews.paste(link) { _ in Fixtures.linkPreview }
        #expect(await eventually { previews.previews.count == 1 })
        previews.remove(Fixtures.linkPreview)
        #expect(previews.previews.isEmpty)
    }

    @Test func anAnswerAfterTheLinkIsTakenOutIsLetGo() async throws {
        let gate = Gate()
        let previews = LinkPreviews()
        previews.paste(link) { _ in
            await gate.wait()
            return Fixtures.linkPreview
        }
        previews.textChanged("Look https://example.com/engine")
        #expect(previews.loading == link)
        previews.textChanged("Look ")
        #expect(previews.loading == nil)
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(previews.previews.isEmpty)
    }

    @Test func anAnswerAfterSendingOrAnotherPasteIsLetGo() async throws {
        let gate = Gate()
        let previews = LinkPreviews()
        let slow: LinkPreviews.Fetch = { _ in
            await gate.wait()
            return Fixtures.linkPreview
        }
        previews.paste(link, fetch: slow)
        previews.clear()
        #expect(previews.loading == nil)

        // A second paste lets the first go, as the web's does.
        previews.paste(link, fetch: slow)
        let other = LinkPreview(title: "Other", url: "https://example.com/other")
        previews.paste(try #require(PastedLink.link(other.url))) { _ in other }
        #expect(await eventually { previews.previews == [other] })
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(previews.previews == [other])
    }

    @Test func aFailedOrEmptyAnswerShowsNothing() async throws {
        let transport = MockHTTPTransport()
        transport.stub("POST", "/api/unfurl", status: 204, json: "")
        let previews = LinkPreviews()
        previews.paste(link, client: .mock(transport: transport))
        #expect(await eventually { previews.loading == nil })
        #expect(previews.previews.isEmpty)

        transport.stub("POST", "/api/unfurl", status: 429, json: Fixtures.errorJSON("Too many link previews. Try again in a minute."))
        previews.paste(link, client: .mock(transport: transport))
        #expect(await eventually { previews.loading == nil })
        #expect(previews.previews.isEmpty)

        struct Failed: Error {}
        previews.paste(link) { _ in throw Failed() }
        #expect(await eventually { previews.loading == nil })
        #expect(previews.previews.isEmpty)
    }

    @Test func severalLinksEachKeepTheirPreviewOnce() async throws {
        let previews = LinkPreviews()
        let other = LinkPreview(title: "Other", url: "https://example.com/other")
        previews.paste(link) { _ in Fixtures.linkPreview }
        #expect(await eventually { previews.previews.count == 1 })
        previews.paste(try #require(PastedLink.link(other.url))) { _ in other }
        #expect(await eventually { previews.previews.count == 2 })
        // The same link again isn't asked about.
        previews.paste(link) { _ in Issue.record("asked again"); return nil }
        #expect(previews.loading == nil)
        #expect(previews.previews == [Fixtures.linkPreview, other])
        previews.clear()
        #expect(previews.previews.isEmpty)
    }

    // MARK: Sending

    let connector = MockSocketConnector()

    func opened() async throws -> (RoomSession, MockSocketConnection) {
        connector.welcomeEverySocket()
        let timing = EmberTiming(clock: ManualClock(), random: { 0.5 })
        let session = RoomSession(client: .mock(connector: connector, timing: timing), roomID: Fixtures.general.id, unsentStore: MemoryUnsentMessageStore())
        session.start()
        try #require(await eventually { session.timeline.isLoaded && session.status == .open && session.phase == .admitted })
        return (session, try #require(connector.latest))
    }

    func created(_ socket: MockSocketConnection) -> [String] {
        socket.sentFrames.compactMap { $0.type == "message.create" ? $0.string("body") : nil }
    }

    var attachment: String { RichText.previewAttachment(Fixtures.linkPreview) }

    @Test func previewsGoAfterTheText() async throws {
        let (session, socket) = try await opened()
        try RoomComposer.send(Draft(text: "https://example.com/engine"), staged: StagedFiles(), previews: [Fixtures.linkPreview], room: session, thread: nil, delivery: .threadOnly)
        #expect(await eventually { created(socket).count == 1 })
        let body = try #require(created(socket).first)
        #expect(body.hasPrefix("<p>https://example.com/engine"))
        #expect(body.hasSuffix(attachment))
    }

    @Test func previewsGoWithMentionsAndInAThread() async throws {
        let (session, socket) = try await opened()
        let mentioned = Draft(text: "@Grace https://example.com/engine", mentions: [Fixtures.grace.id: "Grace"])
        try RoomComposer.send(mentioned, previews: [Fixtures.linkPreview], room: session, thread: nil, delivery: .threadOnly)
        let thread = session.thread("m001")
        let lease = thread.open()
        try RoomComposer.send(Draft(text: "Yes"), previews: [Fixtures.linkPreview], room: session, thread: thread, delivery: .threadOnly)
        #expect(await eventually { created(socket).count == 2 })
        #expect(created(socket).allSatisfy { $0.hasSuffix(attachment) })
        #expect(socket.sentFrames.filter { $0.type == "message.create" }.last?.string("parentId") == "m001")
        lease.close()
    }

    @Test func noPreviewsGoWithFiles() async throws {
        let (session, socket) = try await opened()
        let folder = FileManager.default.temporaryDirectory.appending(path: "LinkPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "notes.txt")
        try Data("notes".utf8).write(to: url)
        let staged = StagedFiles()
        staged.append(StagedFile(source: try UploadSource(fileURL: url, contentType: "text/plain", disposition: .preserve), thumbnail: nil))
        try RoomComposer.send(Draft(text: "https://example.com/engine"), staged: staged, previews: [Fixtures.linkPreview], room: session, thread: nil, delivery: .threadOnly)
        #expect(staged.files.isEmpty)
        #expect(await eventually { !session.timeline.pending.isEmpty })
        #expect(!session.timeline.pending.contains { $0.body.contains(attachment) })
        #expect(!created(socket).contains { $0.contains(attachment) })
    }
}

/// Holds whatever waits on it until it's opened.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
