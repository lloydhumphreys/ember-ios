import Foundation
import Testing
import SwiftUI
import UIKit
import ImageIO
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// The bounds pictures are held to, what's remembered when one fails, where a card's picture may be
/// redirected, and which links reach the system. Nothing here touches the network.
@MainActor
@Suite struct ImagesAndLinksTests {
    private let host = "chat.example.com"

    // MARK: Card image redirects

    @Test func aCardImageRedirectFollowsOnlyWhereTheCardRuleAllows() {
        func follows(_ address: String) -> Bool {
            CardImages.redirect(URLRequest(url: URL(string: address)!), host: host) != nil
        }
        #expect(follows("https://cdn.example.org/a.png"))
        #expect(follows("http://cdn.example.org/a.png"))
        // The chat server itself, whatever the case or a trailing dot.
        #expect(!follows("https://chat.example.com/files/secret"))
        #expect(!follows("https://CHAT.example.com./files/secret"))
        // Not a named host.
        #expect(!follows("http://localhost/a.png"))
        #expect(!follows("http://10.0.0.1/a.png"))
        #expect(!follows("http://[::1]/a.png"))
        // Not http or https.
        #expect(!follows("file:///etc/hosts"))
        #expect(!follows("ftp://cdn.example.org/a.png"))
        #expect(!follows("data:image/png;base64,AAAA"))
    }

    @Test func aCardImageFollowsAnAllowedRedirect() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        ImageStub.answer("https://hop-a.example.org/a.png", .redirect("https://hop-b.example.org/b.png"))
        ImageStub.answer("https://hop-b.example.org/b.png", .body(Self.png(width: 40, height: 20)))
        let loaded = await images.image("https://hop-a.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded?.pixelSize == CGSize(width: 40, height: 20))
    }

    @Test func aCardImageRefusesARedirectToTheChatServer() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let target = "https://chat.example.com/files/f.png"
        ImageStub.answer("https://hop-c.example.org/a.png", .redirect(target))
        ImageStub.answer(target, .body(Self.png(width: 40, height: 20)))
        let loaded = await images.image("https://hop-c.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "chat.example.com").isEmpty)
        // Refused by the rule: it will be refused again, so it's remembered.
        #expect(images.hasFailed("https://hop-c.example.org/a.png"))
    }

    @Test func aCardImageRefusesARedirectToALocalAddress() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        ImageStub.answer("https://hop-d.example.org/a.png", .redirect("http://169.254.169.254/latest/meta-data"))
        let loaded = await images.image("https://hop-d.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "169.254.169.254").isEmpty)
    }

    @Test func aCardImageAddressTheRuleRefusesIsNeverFetched() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let loaded = await images.image("https://chat.example.com/files/direct.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "chat.example.com").isEmpty)
        #expect(images.hasFailed("https://chat.example.com/files/direct.png"))
    }

    @Test func aCardImageRequestCarriesNoCookieEvenAfterARedirect() async throws {
        let first = "https://cookie-a.example.org/a.png"
        let second = "https://cookie-b.example.org/b.png"
        let cookies = try [first, second].map { address in
            try #require(HTTPCookie(properties: [
                .domain: URL(string: address)!.host()!, .path: "/", .name: "session_token", .value: "secret", .secure: "TRUE",
            ]))
        }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        defer { for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) } }
        ImageStub.answer(first, .redirect(second))
        ImageStub.answer(second, .body(Self.png(width: 4, height: 4)))

        let images = CardImages(protocolClasses: [ImageStub.self])
        // A stand-in protocol sees requests before the loading system adds cookies, so the session's
        // own settings are what show none will be: no store to read one from, and none set.
        let configuration = images.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        let loaded = await images.image(first, host: host, maxPixel: 10)
        #expect(loaded != nil)
        let sent = ImageStub.requests(to: "cookie-a.example.org") + ImageStub.requests(to: "cookie-b.example.org")
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    // MARK: Card image bounds and failures

    @Test func aCardImageDeclaringTooManyBytesIsRefusedAndRemembered() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://big-declared.example.org/a.png"
        ImageStub.answer(address, .body(Self.png(width: 4, height: 4), headers: ["Content-Length": String(ImageLimits.maxBytes + 1)]))
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(images.hasFailed(address))
    }

    @Test func aCardImageSendingTooManyBytesWithNoLengthIsRefused() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://big-undeclared.example.org/a.png"
        ImageStub.answer(address, .body(Data(count: ImageLimits.maxBytes + 1)))
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(images.hasFailed(address))
    }

    @Test func aCardImageIsDownsampledToTheSizeItsDrawnAt() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://downsample.example.org/a.png"
        ImageStub.answer(address, .body(Self.png(width: 400, height: 200)))
        let loaded = await images.image(address, host: host, maxPixel: 100)
        #expect(loaded?.pixelSize == CGSize(width: 400, height: 200))
        #expect(loaded?.image.cgImage?.width == 100)
        #expect(loaded?.image.cgImage?.height == 50)
    }

    @Test func aCardImageServerErrorIsTriedAgainButANotFoundIsNot() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let flaky = "https://flaky.example.org/a.png"
        let gone = "https://gone.example.org/a.png"
        ImageStub.answer(flaky, .status(503))
        ImageStub.answer(gone, .status(404))
        #expect(await images.image(flaky, host: host, maxPixel: 10) == nil)
        #expect(await images.image(gone, host: host, maxPixel: 10) == nil)
        #expect(!images.hasFailed(flaky))
        #expect(images.hasFailed(gone))

        ImageStub.answer(flaky, .body(Self.png(width: 4, height: 4)))
        #expect(await images.image(flaky, host: host, maxPixel: 10) != nil)
        #expect(await images.image(gone, host: host, maxPixel: 10) == nil)
        #expect(ImageStub.requests(to: "flaky.example.org").count == 2)
        #expect(ImageStub.requests(to: "gone.example.org").count == 1)
    }

    @Test func aCardImageThatCouldNotBeReachedIsTriedAgain() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://offline.example.org/a.png"
        ImageStub.answer(address, .fail)
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(!images.hasFailed(address))
        ImageStub.answer(address, .body(Self.png(width: 4, height: 4)))
        #expect(await images.image(address, host: host, maxPixel: 10) != nil)
    }

    // MARK: Server image bounds and failures

    @Test func aServerImageIsDownsampledOffItsFullSize() async {
        let (images, client, transport) = Self.remote(.init(body: Self.png(width: 1000, height: 500)))
        let image = await images.image(client: client, path: "/files/a.png", maxPixel: 120)
        #expect(image?.cgImage?.width == 120)
        #expect(image?.cgImage?.height == 60)
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 120)) != nil)
        #expect(transport.count == 1)
    }

    @Test func aServerImageDeclaringTooManyBytesIsRefused() async {
        let (images, client, _) = Self.remote(.init(body: Self.png(width: 4, height: 4), headers: ["Content-Length": String(ImageLimits.maxBytes + 1)]))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
    }

    @Test func aServerImageLargerThanItSaidIsRefused() async {
        var body = Self.png(width: 4, height: 4)
        body.append(Data(count: ImageLimits.maxBytes))
        let (images, client, _) = Self.remote(.init(body: body, headers: ["Content-Length": "100"]))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
    }

    @Test func aServerImageWithTooManyPixelsIsRefused() async throws {
        // 56 million pixels in well under the byte bound.
        let header = Self.greyPNG(width: 8_000, height: 7_000)
        #expect(header.count < ImageLimits.maxBytes)

        let decoded = await ImageLimits.decode(header, maxPixel: 100)
        guard case .failure(.tooLarge) = decoded else {
            Issue.record("Expected tooLarge, got \(decoded)")
            return
        }
        let (images, client, _) = Self.remote(.init(body: header))
        #expect(await images.image(client: client, path: "/files/huge.png", maxPixel: 100) == nil)
        #expect(images.hasFailed(client, "/files/huge.png"))
    }

    @Test func aServerAnswerThatIsNotAnImageIsRemembered() async {
        let (images, client, transport) = Self.remote(.init(body: Data("<html>".utf8)))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
        #expect(transport.count == 1)
    }

    @Test func aServerImageThatFailedForNowIsTriedAgain() async {
        let (images, client, transport) = Self.remote(.init(status: 502))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(!images.hasFailed(client, "/files/a.png"))
        transport.answer = .init(fails: true)
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(!images.hasFailed(client, "/files/a.png"))
        transport.answer = .init(body: Self.png(width: 4, height: 4))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) != nil)
        #expect(transport.count == 3)
    }

    @Test func oneLoadIsSharedAndOutlivesAViewThatGoesAway() async {
        let gate = AsyncGate()
        let (images, client, transport) = Self.remote(.init(body: Self.png(width: 8, height: 8)), gate: gate)
        let first = Task { await images.image(client: client, path: "/files/a.png", maxPixel: 10) }
        let second = Task { await images.image(client: client, path: "/files/a.png", maxPixel: 10) }
        await gate.waitForRequest()
        first.cancel()
        gate.release()
        #expect(await second.value != nil)
        _ = await first.value
        #expect(transport.count == 1)
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 10)) != nil)
    }

    // MARK: What's remembered

    @Test func onlyFailuresThatWillNotChangeAreLasting() {
        #expect(ImageLimits.Failure.refused.isLasting)
        #expect(ImageLimits.Failure.tooLarge.isLasting)
        #expect(ImageLimits.Failure.notAnImage.isLasting)
        #expect(ImageLimits.Failure.status(404).isLasting)
        #expect(ImageLimits.Failure.status(410).isLasting)
        #expect(!ImageLimits.Failure.status(401).isLasting)
        #expect(!ImageLimits.Failure.status(403).isLasting)
        #expect(!ImageLimits.Failure.status(408).isLasting)
        #expect(!ImageLimits.Failure.status(429).isLasting)
        #expect(!ImageLimits.Failure.status(500).isLasting)
        #expect(!ImageLimits.Failure.status(503).isLasting)
        #expect(!ImageLimits.Failure.unreachable.isLasting)
    }

    @Test func rememberedFailuresForgetTheOldestPastTheirLimit() {
        var failures = LastingFailures(limit: 3)
        for address in ["a", "b", "c", "b", "d"] { failures.insert(address) }
        #expect(failures.count == 3)
        #expect(!failures.contains("a"))
        #expect(failures.contains("b") && failures.contains("c") && failures.contains("d"))
    }

    // MARK: Links

    @Test(arguments: [
        ("https://example.com/a", "https://example.com/a"),
        ("http://example.com", "http://example.com"),
        ("HTTPS://EXAMPLE.COM/a", "HTTPS://EXAMPLE.COM/a"),
        ("mailto:someone@example.com", "mailto:someone@example.com"),
        ("tel:+15555550100", "tel:+15555550100"),
        ("https://chat.example.com/rooms/3", "https://chat.example.com/rooms/3"),
        // Server-relative, as message links have always been resolved and opened.
        ("/rooms/3", "https://chat.example.com/rooms/3"),
        ("rooms/3?x=1", "https://chat.example.com/rooms/3?x=1"),
        ("//elsewhere.example.org/a", "https://elsewhere.example.org/a"),
    ])
    func aLinkTheAppOpens(_ link: String, _ opened: String) {
        let origin = URL(string: "https://chat.example.com")!
        #expect(LinkOpening.destination(URL(string: link)!, origin: origin)?.absoluteString == opened)
    }

    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "ftp://example.com/a",
        "sms:5555550100", "facetime:someone@example.com", "ember://rooms/3", "prefs:root=General", "https:/no-host", "http://",
    ])
    func aLinkTheAppDrops(_ link: String) {
        let origin = URL(string: "https://chat.example.com")!
        #expect(LinkOpening.destination(URL(string: link)!, origin: origin) == nil)
    }

    @Test func aRelativeLinkWithNoServerIsDropped() {
        #expect(LinkOpening.destination(URL(string: "/rooms/3")!, origin: nil) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRootActionReachesPushedScreensSheetsAndCovers() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let recorder = OpenedLinks()
        let (appearances, reported) = AsyncStream<String>.makeStream()
        let probe = PresentationProbe(report: { reported.yield($0) })
            .modifier(SafeLinks(origin: URL(string: "https://chat.example.com")!, hand: { recorder.urls.append($0) }))
        UIView.setAnimationsEnabled(false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: probe)
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            UIView.setAnimationsEnabled(true)
        }
        var seen: Set<String> = []
        for await name in appearances {
            seen.insert(name)
            if seen.count == 3 { break }
        }
        let opened = Set(recorder.urls.map(\.absoluteString))
        // Each screen tried a refused link and a relative one: only the relative ones came through,
        // resolved, and none of them reached the system's own handler.
        #expect(opened == [
            "https://chat.example.com/rooms/pushed",
            "https://chat.example.com/rooms/sheet",
            "https://chat.example.com/rooms/cover",
        ])
        #expect(recorder.urls.count == 3)
    }

    // MARK: Helpers

    private static func remote(_ answer: ImageTransport.Answer, gate: AsyncGate? = nil) -> (RemoteImages, EmberClient, ImageTransport) {
        let transport = ImageTransport(answer, gate: gate)
        let client = EmberClient(origin: URL(string: "https://chat.example.com")!, transport: transport, connector: MockSocketConnector(), cookies: EphemeralCookieStorage())
        return (RemoteImages(), client, transport)
    }

    static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A blank greyscale PNG: one byte a pixel to draw, and a few kilobytes once compressed.
    static func greyPNG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

// MARK: - Stand-ins

@MainActor private final class OpenedLinks {
    var urls: [URL] = []
}

/// Pushes a screen, which presents a sheet, which presents a cover; each tries two links as it appears.
private struct PresentationProbe: View {
    let report: @MainActor (String) -> Void
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: Int.self) { _ in PushedProbe(report: report) }
                .task { path = [1] }
        }
    }
}

private struct PushedProbe: View {
    let report: @MainActor (String) -> Void
    @State private var isPresenting = false

    var body: some View {
        LinkTrier(name: "pushed", report: report)
            .task { isPresenting = true }
            .sheet(isPresented: $isPresenting) { SheetProbe(report: report) }
    }
}

private struct SheetProbe: View {
    let report: @MainActor (String) -> Void
    @State private var isPresenting = false

    var body: some View {
        LinkTrier(name: "sheet", report: report)
            .task { isPresenting = true }
            .fullScreenCover(isPresented: $isPresenting) { LinkTrier(name: "cover", report: report) }
    }
}

private struct LinkTrier: View {
    let name: String
    let report: @MainActor (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear.onAppear {
            openURL(URL(string: "javascript:void(0)")!)
            openURL(URL(string: "/rooms/\(name)")!)
            report(name)
        }
    }
}

/// Answers every request with one answer, counting them, optionally held at a gate first.
private final class ImageTransport: HTTPTransport, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var fails = false
    }

    private let lock = NSLock()
    private var current: Answer
    private var sent = 0
    private let gate: AsyncGate?

    init(_ answer: Answer, gate: AsyncGate?) {
        current = answer
        self.gate = gate
    }

    var answer: Answer {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var count: Int { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { () -> Answer in
            sent += 1
            return current
        }
        if let gate { await gate.pass() }
        if answer.fails { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (answer.body, response)
    }
}

/// Holds a request until `release()`, telling a waiter once one has reached it.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var isReached = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRequest() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReached {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            defer { self.held = [] }
            return self.held
        }
        for continuation in held { continuation.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isReached = true
            let waiting = waiters
            waiters = []
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                held.append(continuation)
                lock.unlock()
            }
            for waiter in waiting { waiter.resume() }
        }
    }
}

/// Answers card image requests from what each test set for its own address, and records them.
final class ImageStub: URLProtocol {
    enum Answer: Sendable {
        case body(Data, headers: [String: String] = [:])
        case redirect(String)
        case status(Int)
        case fail
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func answer(_ address: String, _ answer: Answer) {
        lock.withLock { answers[address] = answer }
    }

    static func requests(to host: String) -> [URLRequest] {
        lock.withLock { seen.filter { $0.url?.host() == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = Self.lock.withLock { () -> Answer in
            Self.seen.append(request)
            return Self.answers[url.absoluteString] ?? .status(404)
        }
        switch answer {
        case let .body(data, headers):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // Where the redirect isn't followed, the 302 is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .status(status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}
