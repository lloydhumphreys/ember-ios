import Foundation
import EmberSDK
import EmberRichText

/// Message bodies, read into documents once each. Reading HTML on every redraw of a long room
/// would be the slowest thing it does; a message's `updatedAt` changes with an edit, which reads
/// it again.
@MainActor final class DocumentCache {
    static var shared: DocumentCache { AccountStores.current.documents }

    private let documents = NSCache<NSString, Box>()

    /// Files people sent are kept in `files`.
    init(files: URL) {
        self.files = FileDownloads(directory: files)
        documents.countLimit = 1_000
        cardDocuments.countLimit = 2_000
        shownCards.countLimit = 500
    }

    /// Files people sent, as Quick Look opens them.
    let files: FileDownloads

    /// Empties every document, card and file kept.
    func reset() {
        documents.removeAllObjects()
        cardDocuments.removeAllObjects()
        shownCards.removeAllObjects()
        files.reset()
    }

    func document(for message: Message, host: String) -> RichDocument {
        document(key: "\(host)|\(message.id.rawValue)|\(message.updatedAt.timeIntervalSince1970)", html: message.body, plainText: message.plainText, host: host)
    }

    func document(for pending: PendingMessage, host: String) -> RichDocument {
        document(key: "\(host)|pending|\(pending.clientMessageId.rawValue)", html: pending.body, plainText: pending.plainText, host: host)
    }

    private func document(key: String, html: String, plainText: String, host: String) -> RichDocument {
        if let box = documents.object(forKey: key as NSString) { return box.document }
        let document = RichText.document(html: html, plainText: plainText, host: host)
        documents.setObject(Box(document), forKey: key as NSString)
        return document
    }

    // MARK: Cards

    private let cardDocuments = NSCache<NSString, CardTextBox>()
    private let shownCards = NSCache<NSString, CardsBox>()

    /// A card's rich text (a text part, a field, a cell, a tile's body) read once per host, and
    /// whether it's long enough to fold.
    func cardText(html: String, host: String) -> (document: RichDocument, isLong: Bool) {
        let key = "\(host)|\(html)" as NSString
        if let box = cardDocuments.object(forKey: key) { return (box.document, box.isLong) }
        let box = CardTextBox(document: CardText.document(html: html, host: host), isLong: CardText.isLong(html: html))
        cardDocuments.setObject(box, forKey: key)
        return (box.document, box.isLong)
    }

    /// A message's cards as they may be drawn: every image, icon, link and button address through
    /// the card address rule, once per version of the message. Empty when there are none to draw.
    func cards(for message: Message, host: String) -> [Card] {
        guard let cards = message.cards, !cards.isEmpty else { return [] }
        let key = "\(host)|\(message.id.rawValue)|\(message.updatedAt.timeIntervalSince1970)|\(cards.count)" as NSString
        if let box = shownCards.object(forKey: key) { return box.cards }
        let shown = Self.shownCards(cards, host: host)
        shownCards.setObject(CardsBox(shown), forKey: key)
        return shown
    }

    nonisolated static func shownCards(_ cards: [Card], host: String) -> [Card] {
        cards.withAddresses { CardText.address($0, host: host) }
    }

    private final class Box {
        let document: RichDocument
        init(_ document: RichDocument) { self.document = document }
    }

    private final class CardTextBox {
        let document: RichDocument
        let isLong: Bool
        init(document: RichDocument, isLong: Bool) {
            self.document = document
            self.isLong = isLong
        }
    }

    private final class CardsBox {
        let cards: [Card]
        init(_ cards: [Card]) { self.cards = cards }
    }
}

/// Files people sent, downloaded once each to `directory` under their own names, where Quick Look
/// and the share sheet can open them. Past `limit` bytes in all, the least recently used go.
@MainActor final class FileDownloads {
    let directory: URL
    let limit: Int
    private let session: URLSession
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// `protocolClasses` stand in for the network in tests.
    init(directory: URL, limit: Int = 300 * 1024 * 1024, protocolClasses: [AnyClass]? = nil) {
        self.directory = directory
        self.limit = limit
        let configuration = URLSessionConfiguration.ephemeral
        // The session cookie goes on by hand, and only to the server itself (`request(for:client:)`).
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
    }

    /// Where `file` is saved: a folder of its own, so two files of one name don't meet.
    func location(of file: StoredFile) -> URL {
        directory
            .appending(path: Self.safe(file.id.rawValue, otherwise: "file"), directoryHint: .isDirectory)
            .appending(path: Self.safe(file.name, otherwise: "file"))
    }

    /// The saved copy of `file`, fetched first when there isn't one yet. One fetch per file, whoever
    /// asks.
    func file(_ file: StoredFile, client: EmberClient) async throws -> URL {
        let destination = location(of: file)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.deletingLastPathComponent().path)
            return destination
        }
        if let task = inFlight[file.id.rawValue] { return try await task.value }
        let request = try Self.request(for: file, client: client)
        let session = session
        let origin = client.origin
        let task = Task<URL, any Error> {
            let saved = try await Self.download(request, to: destination, origin: origin, session: session)
            self.trim(keeping: saved)
            return saved
        }
        inFlight[file.id.rawValue] = task
        // Only this download's own entry: after a reset, a newer one for the file may be there.
        defer { if inFlight[file.id.rawValue] == task { inFlight[file.id.rawValue] = nil } }
        return try await task.value
    }

    /// Removes every file saved.
    func reset() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    /// The request for `file`'s download address: with the session's cookies when that's on the
    /// server itself, and with none when it's somewhere else, as a signed address needs none.
    static func request(for file: StoredFile, client: EmberClient) throws -> URLRequest {
        guard let url = client.url(file.downloadUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        if isSameOrigin(url, client.origin) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: client.cookies.cookies(for: url) ?? []) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    /// The redirect to follow: as it is to the server itself, and without the cookies anywhere else.
    nonisolated static func redirect(_ request: URLRequest, origin: URL) -> URLRequest {
        guard let url = request.url, !isSameOrigin(url, origin) else { return request }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        return request
    }

    nonisolated static func isSameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme?.lowercased() == origin.scheme?.lowercased()
            && url.host()?.lowercased() == origin.host()?.lowercased()
            && (url.port ?? defaultPort(url)) == (origin.port ?? defaultPort(origin))
    }

    private nonisolated static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": 443
        case "http": 80
        default: nil
        }
    }

    /// A name that stays inside its folder: no slashes, colons or leading dots.
    nonisolated static func safe(_ name: String, otherwise fallback: String) -> String {
        var cleaned = String(name.map { "/\\:".contains($0) || $0.isNewline ? "_" : $0 })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(200))
    }

    @concurrent nonisolated private static func download(_ request: URLRequest, to destination: URL, origin: URL, session: URLSession) async throws -> URL {
        let (temporary, response) = try await session.download(for: request, delegate: Redirects(origin: origin))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Removes the least recently used folders until the rest fit `limit`, never `kept`'s.
    private func trim(keeping kept: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let keptFolder = kept.deletingLastPathComponent().standardizedFileURL
        var entries = folders.map { folder in
            (folder: folder,
             used: (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
             bytes: Self.bytes(in: folder))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limit && entry.folder.standardizedFileURL != keptFolder {
            try? FileManager.default.removeItem(at: entry.folder)
            total -= entry.bytes
        }
    }

    private static func bytes(in folder: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        let origin: URL

        init(origin: URL) { self.origin = origin }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(FileDownloads.redirect(request, origin: origin))
        }
    }
}
